// png-tiles.mjs — self-contained PNG -> GBA 4bpp tiles + 16-color palette.
//
// We decode the PNG ourselves (pure JS, own inflate) and build the palette from
// the image's own unique colors, so we do NOT depend on any external converter's
// palette output. Output matches GBA hardware: 4bpp linear tiles (2 px/byte, low
// nibble = left pixel), 16-color BGR555 palette, index 0 = transparent.
//
// BROWSER-SAFE: no node:zlib, no Buffer — runs identically in Node and in a
// Web Worker (the gbalua web IDE builds through this exact module).

// ---- pure-JS inflate (zlib stream) ------------------------------------------
// Classic puff-style canonical-Huffman DEFLATE decoder. Small and deterministic;
// PNG payloads here are tiny (sprite sheets / maps), speed is irrelevant.
const LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
const LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DIST_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
const DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
const CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

// build a canonical-Huffman decoder from a code-length array.
function buildHuff(lengths) {
  const count = new Int32Array(16);
  for (const l of lengths) count[l]++;
  count[0] = 0;
  const offsets = new Int32Array(16);
  for (let l = 1; l < 16; l++) offsets[l] = offsets[l - 1] + count[l - 1];
  const symbols = new Int32Array(lengths.length);
  for (let s = 0; s < lengths.length; s++) if (lengths[s]) symbols[offsets[lengths[s]]++] = s;
  return { count, symbols };
}

export function inflate(src) {
  // zlib wrapper: 2-byte header (CM must be 8 = deflate), 4-byte adler trailer.
  if ((src[0] & 0x0f) !== 8) throw new Error("inflate: not a zlib/deflate stream");
  let pos = 2, bitBuf = 0, bitCnt = 0;
  let out = new Uint8Array(64 * 1024), outLen = 0;
  const push = (b) => {
    if (outLen === out.length) { const g = new Uint8Array(out.length * 2); g.set(out); out = g; }
    out[outLen++] = b;
  };
  const bits = (n) => {
    while (bitCnt < n) { bitBuf |= src[pos++] << bitCnt; bitCnt += 8; }
    const v = bitBuf & ((1 << n) - 1);
    bitBuf >>>= n; bitCnt -= n;
    return v;
  };
  const decode = (huff) => {
    let code = 0, first = 0, index = 0;
    for (let len = 1; len < 16; len++) {
      code |= bits(1);
      const cnt = huff.count[len];
      if (code - first < cnt) return huff.symbols[index + (code - first)];
      index += cnt; first = (first + cnt) << 1; code <<= 1;
    }
    throw new Error("inflate: bad huffman code");
  };

  let fixedLit = null, fixedDist = null;
  for (;;) {
    const final = bits(1), type = bits(2);
    if (type === 0) {                     // stored
      bitBuf = 0; bitCnt = 0;             // align to byte
      const len = src[pos] | (src[pos + 1] << 8);
      pos += 4;                            // len + ~len
      for (let i = 0; i < len; i++) push(src[pos++]);
    } else {
      let lit, dist;
      if (type === 1) {                   // fixed codes
        if (!fixedLit) {
          const ll = new Array(288);
          for (let i = 0; i < 144; i++) ll[i] = 8;
          for (let i = 144; i < 256; i++) ll[i] = 9;
          for (let i = 256; i < 280; i++) ll[i] = 7;
          for (let i = 280; i < 288; i++) ll[i] = 8;
          fixedLit = buildHuff(ll);
          fixedDist = buildHuff(new Array(30).fill(5));
        }
        lit = fixedLit; dist = fixedDist;
      } else if (type === 2) {            // dynamic codes
        const hlit = bits(5) + 257, hdist = bits(5) + 1, hclen = bits(4) + 4;
        const clens = new Array(19).fill(0);
        for (let i = 0; i < hclen; i++) clens[CLEN_ORDER[i]] = bits(3);
        const clHuff = buildHuff(clens);
        const lens = new Array(hlit + hdist).fill(0);
        for (let i = 0; i < hlit + hdist;) {
          const sym = decode(clHuff);
          if (sym < 16) lens[i++] = sym;
          else if (sym === 16) { const rep = 3 + bits(2), prev = lens[i - 1]; for (let r = 0; r < rep; r++) lens[i++] = prev; }
          else if (sym === 17) { const rep = 3 + bits(3); for (let r = 0; r < rep; r++) lens[i++] = 0; }
          else { const rep = 11 + bits(7); for (let r = 0; r < rep; r++) lens[i++] = 0; }
        }
        lit = buildHuff(lens.slice(0, hlit));
        dist = buildHuff(lens.slice(hlit));
      } else throw new Error("inflate: bad block type");
      for (;;) {
        const sym = decode(lit);
        if (sym === 256) break;
        if (sym < 256) push(sym);
        else {
          const len = LEN_BASE[sym - 257] + bits(LEN_EXTRA[sym - 257]);
          const dsym = decode(dist);
          const d = DIST_BASE[dsym] + bits(DIST_EXTRA[dsym]);
          for (let i = 0; i < len; i++) push(out[outLen - d]);
        }
      }
    }
    if (final) break;
  }
  return out.subarray(0, outLen);
}

// ---- minimal PNG decode -> {width, height, rgba: Uint8Array} ----------------
const u32be = (b, o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;

/** Decode an 8-bit PNG (RGBA/RGB/indexed/gray) to {width, height, rgba}. */
export function decodePng(buf) {
  buf = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  if (u32be(buf, 0) !== 0x89504e47) throw new Error("not a PNG");
  let pos = 8, width = 0, height = 0, bitDepth = 0, colorType = 0;
  const idat = [];
  let idatLen = 0;
  let palette = null, trns = null;
  while (pos < buf.length) {
    const len = u32be(buf, pos);
    const type = String.fromCharCode(buf[pos + 4], buf[pos + 5], buf[pos + 6], buf[pos + 7]);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === "IHDR") {
      width = u32be(data, 0); height = u32be(data, 4);
      bitDepth = data[8]; colorType = data[9];
      if (data[12]) throw new Error("interlaced PNG unsupported");
    } else if (type === "PLTE") palette = data;
    else if (type === "tRNS") trns = data;
    else if (type === "IDAT") { idat.push(data); idatLen += data.length; }
    else if (type === "IEND") break;
    pos += 12 + len;
  }
  if (bitDepth !== 8) throw new Error(`PNG bit depth ${bitDepth} unsupported (need 8)`);
  const joined = new Uint8Array(idatLen);
  let jo = 0;
  for (const c of idat) { joined.set(c, jo); jo += c.length; }
  const raw = inflate(joined);
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
