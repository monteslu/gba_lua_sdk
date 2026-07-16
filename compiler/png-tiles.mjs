// png-tiles.mjs — self-contained PNG -> GBA 4bpp tiles + 16-color palette.
//
// We decode the PNG ourselves (zlib only) and build the palette from the image's
// own unique colors, so we do NOT depend on any external converter's palette
// output. Output matches GBA hardware: 4bpp linear tiles (2 px/byte, low nibble
// = left pixel), 16-color BGR555 palette, index 0 = transparent.

import zlib from "node:zlib";

// ---- minimal PNG decode -> {width, height, rgba: Uint8Array} ----------------
function decodePng(buf) {
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error("not a PNG");
  let pos = 8, width = 0, height = 0, bitDepth = 0, colorType = 0;
  const idat = [];
  let palette = null, trns = null;
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos); const type = buf.toString("ascii", pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === "IHDR") {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      bitDepth = data[8]; colorType = data[9];
    } else if (type === "PLTE") palette = data;
    else if (type === "tRNS") trns = data;
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    pos += 12 + len;
  }
  if (bitDepth !== 8) throw new Error(`PNG bit depth ${bitDepth} unsupported (need 8)`);
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : colorType === 3 ? 1 : colorType === 0 ? 1 : 0;
  if (!channels) throw new Error(`PNG color type ${colorType} unsupported`);
  const stride = width * channels;
  const out = new Uint8Array(width * height * 4);
  const line = new Uint8Array(stride);
  const prev = new Uint8Array(stride);
  let rp = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[rp++];
    for (let x = 0; x < stride; x++) {
      const rawv = raw[rp++];
      const a = x >= channels ? line[x - channels] : 0;
      const b = prev[x];
      const c = x >= channels ? prev[x - channels] : 0;
      let v;
      switch (filter) {
        case 0: v = rawv; break;
        case 1: v = rawv + a; break;
        case 2: v = rawv + b; break;
        case 3: v = rawv + ((a + b) >> 1); break;
        case 4: { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          v = rawv + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c); break; }
        default: v = rawv;
      }
      line[x] = v & 0xff;
    }
    // expand line -> rgba
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      if (colorType === 6) { out[o] = line[x * 4]; out[o + 1] = line[x * 4 + 1]; out[o + 2] = line[x * 4 + 2]; out[o + 3] = line[x * 4 + 3]; }
      else if (colorType === 2) { out[o] = line[x * 3]; out[o + 1] = line[x * 3 + 1]; out[o + 2] = line[x * 3 + 2]; out[o + 3] = 255; }
      else if (colorType === 3) { const idx = line[x]; out[o] = palette[idx * 3]; out[o + 1] = palette[idx * 3 + 1]; out[o + 2] = palette[idx * 3 + 2]; out[o + 3] = trns && idx < trns.length ? trns[idx] : 255; }
      else { out[o] = out[o + 1] = out[o + 2] = line[x]; out[o + 3] = 255; }
    }
    prev.set(line);
  }
  return { width, height, rgba: out };
}

const bgr555 = (r, g, b) => (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10);

/**
 * Convert a PNG buffer to GBA 4bpp sprite-sheet data.
 * Returns { words: number[] (u32 tiles, sprite-block order), pal: number[16] (BGR555),
 *   tilesAcross, tilesDown }.
 * Sprites are 16x16; tiles are reordered so each sprite's 4 tiles are consecutive.
 */
export function pngToSheet(buf) {
  const { width, height, rgba } = decodePng(buf);
  if (width % 8 || height % 8) throw new Error(`sheet ${width}x${height} must be multiples of 8`);

  // build the palette from unique colors. index 0 = transparent (any alpha<128).
  const pal = [0]; // slot 0 reserved for transparent
  const key = new Map(); key.set("t", 0);
  const idxAt = (x, y) => {
    const o = (y * width + x) * 4;
    if (rgba[o + 3] < 128) return 0;
    const k = rgba[o] + "," + rgba[o + 1] + "," + rgba[o + 2];
    let i = key.get(k);
    if (i === undefined) {
      i = pal.length;
      if (i >= 16) throw new Error("sheet has >15 opaque colors (4bpp limit is 16 incl. transparent)");
      pal.push(bgr555(rgba[o], rgba[o + 1], rgba[o + 2]));
      key.set(k, i);
    }
    return i;
  };

  // pack each 8x8 tile: 4bpp linear, 2 px/byte (low nibble left).
  const tilesAcross = width >> 3, tilesDown = height >> 3;
  const tileWords = (tx, ty) => {
    const words = [];
    for (let py = 0; py < 8; py++) {
      let w = 0;
      for (let px = 0; px < 8; px++) {
        const idx = idxAt(tx * 8 + px, ty * 8 + py) & 0xf;
        w |= idx << (px * 4);
      }
      words.push(w >>> 0);
    }
    return words; // 8 words = 32 bytes
  };

  // reorder into 16x16 sprite blocks (NW,NE,SW,SE consecutive).
  const words = [];
  const spCols = Math.max(1, tilesAcross >> 1), spRows = Math.max(1, tilesDown >> 1);
  for (let sr = 0; sr < spRows; sr++)
    for (let sc = 0; sc < spCols; sc++) {
      const tx = sc * 2, ty = sr * 2;
      words.push(...tileWords(tx, ty), ...tileWords(tx + 1, ty), ...tileWords(tx, ty + 1), ...tileWords(tx + 1, ty + 1));
    }
  while (pal.length < 16) pal.push(0);
  return { words, pal, tilesAcross, tilesDown };
}

/**
 * Convert a PNG to a GBA TILEMAP: deduped 8x8 tiles + a screen map of indices.
 * For backgrounds (not sprites). Returns { tileWords: u32[] (deduped tiles),
 *   map: u16[] (cols*rows, low 10 bits = tile id), pal: number[16], cols, rows }.
 * Identical tiles collapse to one (flip-aware dedup omitted for simplicity —
 * exact-match dedup only). index 0 color = transparent/backdrop.
 */
export function pngToTilemap(buf) {
  const { width, height, rgba } = decodePng(buf);
  if (width % 8 || height % 8) throw new Error(`map ${width}x${height} must be multiples of 8`);
  const cols = width >> 3, rows = height >> 3;

  const pal = [0];
  const key = new Map(); key.set("t", 0);
  const idxAt = (x, y) => {
    const o = (y * width + x) * 4;
    if (rgba[o + 3] < 128) return 0;
    const k = rgba[o] + "," + rgba[o + 1] + "," + rgba[o + 2];
    let i = key.get(k);
    if (i === undefined) {
      i = pal.length;
      if (i >= 16) throw new Error("map has >15 opaque colors (4bpp limit)");
      pal.push(bgr555(rgba[o], rgba[o + 1], rgba[o + 2]));
      key.set(k, i);
    }
    return i;
  };
  const tileWords = (tx, ty) => {
    const w = [];
    for (let py = 0; py < 8; py++) {
      let word = 0;
      for (let px = 0; px < 8; px++) word |= (idxAt(tx * 8 + px, ty * 8 + py) & 0xf) << (px * 4);
      w.push(word >>> 0);
    }
    return w;
  };

  const tileWordsAll = [];
  const seen = new Map();          // tile signature -> id
  const map = new Array(cols * rows).fill(0);
  // tile 0 is always the empty tile (all transparent), so an empty map cell = 0.
  const emptySig = "0,0,0,0,0,0,0,0";
  tileWordsAll.push(0, 0, 0, 0, 0, 0, 0, 0);
  seen.set(emptySig, 0);
  for (let ry = 0; ry < rows; ry++)
    for (let rx = 0; rx < cols; rx++) {
      const w = tileWords(rx, ry);
      const sig = w.join(",");
      let id = seen.get(sig);
      if (id === undefined) {
        id = tileWordsAll.length / 8;
        if (id > 1023) throw new Error("map exceeds 1024 unique tiles");
        tileWordsAll.push(...w);
        seen.set(sig, id);
      }
      map[ry * cols + rx] = id;
    }
  while (pal.length < 16) pal.push(0);
  return { tileWords: tileWordsAll, map, pal, cols, rows };
}

/**
 * Convert a PNG to a GBA AFFINE (Mode-7) background: 8bpp deduped tiles + a
 * 256-color palette + a SQUARE, power-of-2 tile map with 1-byte entries.
 *
 * Affine BGs differ from regular ones: 8bpp tiles (1 byte/pixel, 16 u32/tile),
 * a single 256-color palette, and a square map whose side is 16/32/64/128 tiles
 * (128/256/512/1024 px). The source PNG must be square with a power-of-2 tile
 * count per side; index 0 is transparent/backdrop.
 *
 * Returns { tileWords: u32[] (8bpp, linear), map: number[side*side] (u8 tile ids),
 *   pal: number[256] (BGR555), side (tiles/side), sizeFlag ("16"|"32"|"64"|"128") }.
 */
export function pngToAffineMap(buf) {
  const { width, height, rgba } = decodePng(buf);
  if (width !== height) throw new Error(`mode7 map must be square, got ${width}x${height}`);
  if (width % 8) throw new Error(`mode7 map ${width}px must be a multiple of 8`);
  const side = width >> 3;   // tiles per side
  if (![16, 32, 64, 128].includes(side))
    throw new Error(`mode7 map is ${side}x${side} tiles; must be 16/32/64/128 (128/256/512/1024 px)`);

  // 256-color palette built from the image's own colors (index 0 = transparent).
  const pal = [0];
  const key = new Map(); key.set("t", 0);
  const idxAt = (x, y) => {
    const o = (y * width + x) * 4;
    if (rgba[o + 3] < 128) return 0;
    const k = rgba[o] + "," + rgba[o + 1] + "," + rgba[o + 2];
    let i = key.get(k);
    if (i === undefined) {
      i = pal.length;
      if (i >= 256) throw new Error("mode7 map has >255 opaque colors (8bpp limit)");
      pal.push(bgr555(rgba[o], rgba[o + 1], rgba[o + 2]));
      key.set(k, i);
    }
    return i;
  };
  // one 8bpp tile = 64 bytes = 16 u32 words (4 px/word, low byte = leftmost px).
  const tileWords = (tx, ty) => {
    const w = [];
    for (let py = 0; py < 8; py++)
      for (let half = 0; half < 2; half++) {
        let word = 0;
        for (let px = 0; px < 4; px++)
          word |= (idxAt(tx * 8 + half * 4 + px, ty * 8 + py) & 0xff) << (px * 8);
        w.push(word >>> 0);
      }
    return w;
  };

  const tileWordsAll = [];
  const seen = new Map();
  const map = new Array(side * side).fill(0);
  // tile 0 = the empty (transparent) tile, so a blank cell = 0.
  for (let k = 0; k < 16; k++) tileWordsAll.push(0);
  seen.set(new Array(16).fill(0).join(","), 0);
  for (let ry = 0; ry < side; ry++)
    for (let rx = 0; rx < side; rx++) {
      const w = tileWords(rx, ry);
      const sig = w.join(",");
      let id = seen.get(sig);
      if (id === undefined) {
        id = tileWordsAll.length / 16;
        if (id > 255) throw new Error("mode7 map exceeds 256 unique 8bpp tiles (1-byte map limit)");
        tileWordsAll.push(...w);
        seen.set(sig, id);
      }
      map[ry * side + rx] = id;
    }
  while (pal.length < 256) pal.push(0);
  return { tileWords: tileWordsAll, map, pal, side, sizeFlag: String(side) };
}
