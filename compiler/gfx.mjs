// compiler/gfx.mjs — GameTank sprite-sheet (.gtg) conversion core.
//
// gtlua uses the OFFICIAL GameTank SDK sprite format byte-for-byte (see
// ~/code/cliemu/gametank_sdk/scripts/converters/sprite_convert.js). A .gtg is:
//
//   * 8bpp — ONE BYTE PER PIXEL, each byte a hardware CAPTURE-palette color
//     index (the same 256-color space gt.rgb() resolves into).
//   * 128x128 pixels per QUADRANT = 16384 bytes, top-down row-major.
//   * color 0 = transparent (the blitter's color key).
//
// A source image up to 256x256 is split into up to four 128-wide/128-tall
// quadrants, emitted as name.gtg, name_1.gtg, name_2.gtg, name_3.gtg — exactly
// like the official sprite_convert.js. (In the official ROM each .gtg is
// zopfli-deflated; gtlua handles ROM compression at build time, so this module
// deals only in the raw 16384-byte quadrant bytes.)
//
// This module has NO external dependencies: the PNG codec below is a minimal
// zlib-backed reader/writer (Node's built-in node:zlib does the deflate), so
// the SDK stays install-free. See docs/GRAPHICS.md.

import { deflateSync, inflateSync } from "node:zlib";
import { GT_CAPTURE_PALETTE, nearestColorByte } from "./gt_palette.js";
import { P8_PALETTE } from "./builtins.js";

export const QUADRANT = 128;                       // one .gtg quadrant is 128x128
export const QUADRANT_BYTES = QUADRANT * QUADRANT; // 16384

// ---------------------------------------------------------------------------
// minimal PNG decode (8-bit, non-interlaced; grayscale/RGB/palette +/- alpha)
// ---------------------------------------------------------------------------
// Returns { width, height, rgba } where rgba is a Uint8Array of w*h*4.
export function decodePng(buf) {
  const sig = [137, 80, 78, 71, 13, 10, 26, 10];
  for (let i = 0; i < 8; i++) {
    if (buf[i] !== sig[i]) throw new Error("not a PNG (bad signature)");
  }
  let pos = 8;
  let width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0;
  let palette = null;      // [[r,g,b], ...]
  let trns = null;         // palette alpha
  const idat = [];
  const rd32 = (o) => (buf[o] << 24 | buf[o + 1] << 16 | buf[o + 2] << 8 | buf[o + 3]) >>> 0;

  while (pos < buf.length) {
    const len = rd32(pos);
    const type = buf.toString("ascii", pos + 4, pos + 8);
    const dataStart = pos + 8;
    if (type === "IHDR") {
      width = rd32(dataStart);
      height = rd32(dataStart + 4);
      bitDepth = buf[dataStart + 8];
      colorType = buf[dataStart + 9];
      interlace = buf[dataStart + 12];
    } else if (type === "PLTE") {
      palette = [];
      for (let i = 0; i < len; i += 3) {
        palette.push([buf[dataStart + i], buf[dataStart + i + 1], buf[dataStart + i + 2]]);
      }
    } else if (type === "tRNS") {
      trns = buf.subarray(dataStart, dataStart + len);
    } else if (type === "IDAT") {
      idat.push(buf.subarray(dataStart, dataStart + len));
    } else if (type === "IEND") {
      break;
    }
    pos = dataStart + len + 4;   // +4 CRC
  }
  if (interlace !== 0) throw new Error("interlaced PNG not supported (re-export non-interlaced)");
  if (bitDepth !== 8 && !(colorType === 3 && bitDepth <= 8)) {
    throw new Error(`unsupported PNG bit depth ${bitDepth} (re-export as 8-bit)`);
  }

  const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colorType];
  if (channels === undefined) throw new Error(`unsupported PNG color type ${colorType}`);

  const raw = inflateSync(Buffer.concat(idat));
  const bppBits = channels * bitDepth;
  const bytesPerPixel = Math.max(1, bppBits >> 3);
  const rowBytes = Math.ceil((width * bppBits) / 8);
  const out = Buffer.alloc(height * rowBytes);
  let rp = 0;
  for (let y = 0; y < height; y++) {
    const filter = raw[rp++];
    const row = out.subarray(y * rowBytes, (y + 1) * rowBytes);
    const prev = y > 0 ? out.subarray((y - 1) * rowBytes, y * rowBytes) : null;
    for (let x = 0; x < rowBytes; x++) {
      const rawByte = raw[rp++];
      const a = x >= bytesPerPixel ? row[x - bytesPerPixel] : 0;
      const b = prev ? prev[x] : 0;
      const c = prev && x >= bytesPerPixel ? prev[x - bytesPerPixel] : 0;
      let val;
      switch (filter) {
        case 0: val = rawByte; break;
        case 1: val = rawByte + a; break;
        case 2: val = rawByte + b; break;
        case 3: val = rawByte + ((a + b) >> 1); break;
        case 4: {
          const p = a + b - c;
          const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
          val = rawByte + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
          break;
        }
        default: throw new Error(`bad PNG filter ${filter}`);
      }
      row[x] = val & 255;
    }
  }

  const rgba = new Uint8Array(width * height * 4);
  const readSample = (row, i) => {
    if (bitDepth === 8) return row[i];
    const bit = i * bitDepth;
    const byte = row[bit >> 3];
    const shift = 8 - bitDepth - (bit & 7);
    return (byte >> shift) & ((1 << bitDepth) - 1);
  };
  for (let y = 0; y < height; y++) {
    const row = out.subarray(y * rowBytes, (y + 1) * rowBytes);
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      if (colorType === 3) {                 // palette
        const idx = readSample(row, x);
        const p = palette[idx] || [0, 0, 0];
        rgba[o] = p[0]; rgba[o + 1] = p[1]; rgba[o + 2] = p[2];
        rgba[o + 3] = trns && idx < trns.length ? trns[idx] : 255;
      } else if (colorType === 0) {          // grayscale
        const g = row[x];
        rgba[o] = rgba[o + 1] = rgba[o + 2] = g; rgba[o + 3] = 255;
      } else if (colorType === 4) {          // gray + alpha
        rgba[o] = rgba[o + 1] = rgba[o + 2] = row[x * 2];
        rgba[o + 3] = row[x * 2 + 1];
      } else if (colorType === 2) {          // rgb
        rgba[o] = row[x * 3]; rgba[o + 1] = row[x * 3 + 1]; rgba[o + 2] = row[x * 3 + 2];
        rgba[o + 3] = 255;
      } else {                               // rgba
        rgba[o] = row[x * 4]; rgba[o + 1] = row[x * 4 + 1];
        rgba[o + 2] = row[x * 4 + 2]; rgba[o + 3] = row[x * 4 + 3];
      }
    }
  }
  return { width, height, rgba };
}

// ---------------------------------------------------------------------------
// minimal PNG encode (24-bit RGB, non-interlaced)
// ---------------------------------------------------------------------------
export function encodePng(width, height, rgb /* Buffer w*h*3 */) {
  const rowBytes = width * 3;
  const raw = Buffer.alloc(height * (rowBytes + 1));
  for (let y = 0; y < height; y++) {
    raw[y * (rowBytes + 1)] = 0;   // filter 0 (none)
    rgb.copy(raw, y * (rowBytes + 1) + 1, y * rowBytes, (y + 1) * rowBytes);
  }
  const idat = deflateSync(raw, { level: 9 });

  const crcTable = encodePng._crc || (encodePng._crc = (() => {
    const t = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })());
  const crc32 = (buf) => {
    let c = 0xffffffff;
    for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 2;      // 8-bit, RGB
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", idat),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// ---------------------------------------------------------------------------
// RGBA -> GameTank .gtg quadrants
// ---------------------------------------------------------------------------

// Resolve one opaque RGB pixel to its nearest CAPTURE-palette byte, memoized.
function makeQuantizer() {
  const cache = new Map();
  return (r, g, b) => {
    const key = (r << 16) | (g << 8) | b;
    let byte = cache.get(key);
    if (byte === undefined) { byte = nearestColorByte(r, g, b); cache.set(key, byte); }
    return byte;
  };
}

// Convert an RGBA image (up to 256x256) into GameTank .gtg quadrants. Returns
// { quadrants, width, height }, where quadrants is an ordered array of
// 16384-byte Buffers matching the official split order:
//   index 0 = name.gtg   (top-left, always present)
//   index 1 = name_1.gtg  (present when width  > 128: top-right)
//   index 2 = name_2.gtg  (present when height > 128: bottom-left)
//   index 3 = name_3.gtg  (present when both > 128:   bottom-right)
// Transparent pixels (alpha < alphaCutoff) become color 0. Each quadrant is a
// full 16384-byte block even if the source only partly fills it (the rest is 0).
export function rgbaToGtg(width, height, rgba, { alphaCutoff = 128 } = {}) {
  if (width > 256 || height > 256) {
    throw new Error(
      `image ${width}x${height} exceeds one 256x256 sprite sheet; split it into ` +
      `multiple sheets (a full GameTank sheet is 256x256 = 4 quadrants)`);
  }
  const quant = makeQuantizer();
  const wideQ = width > QUADRANT ? 2 : 1;
  const tallQ = height > QUADRANT ? 2 : 1;
  // quadrant slot order NW, NE, SW, SE -> official file order name, _1, _2, _3
  const slots = [[0, 0], [1, 0], [0, 1], [1, 1]];
  const quadrants = [];
  for (let s = 0; s < wideQ * tallQ; s++) {
    // walk slots in NW,NE,SW,SE order but only keep the ones that exist
    const [qx, qy] = pickSlot(s, wideQ, tallQ, slots);
    const q = Buffer.alloc(QUADRANT_BYTES);   // zero = transparent color 0
    const ox = qx * QUADRANT, oy = qy * QUADRANT;
    for (let y = 0; y < QUADRANT && oy + y < height; y++) {
      for (let x = 0; x < QUADRANT && ox + x < width; x++) {
        const o = ((oy + y) * width + (ox + x)) * 4;
        if (rgba[o + 3] < alphaCutoff) continue;   // leave 0
        q[y * QUADRANT + x] = quant(rgba[o], rgba[o + 1], rgba[o + 2]);
      }
    }
    quadrants.push(q);
  }
  return { quadrants, width, height };
}

// Map the s-th present quadrant (in official name,_1,_2,_3 order) to its (qx,qy).
function pickSlot(s, wideQ, tallQ, slots) {
  const present = slots.filter(([qx, qy]) => qx < wideQ && qy < tallQ);
  return present[s];
}

// Render a single 128x128 .gtg quadrant back to a 24-bit RGB PNG (for round-trip
// editing / previewing). Color 0 renders as its palette RGB like any other byte;
// it is only "transparent" at BLIT time, not in the file.
export function gtgToPng(gtg) {
  if (gtg.length < QUADRANT_BYTES) {
    throw new Error(`.gtg quadrant is ${gtg.length} bytes; expected ${QUADRANT_BYTES}`);
  }
  const rgb = Buffer.alloc(QUADRANT_BYTES * 3);
  for (let i = 0; i < QUADRANT_BYTES; i++) {
    const p = GT_CAPTURE_PALETTE[gtg[i]];
    rgb[i * 3] = p[0]; rgb[i * 3 + 1] = p[1]; rgb[i * 3 + 2] = p[2];
  }
  return encodePng(QUADRANT, QUADRANT, rgb);
}

// ---------------------------------------------------------------------------
// PICO-8 cart __gfx__ -> .gtg quadrants (IMPORT ONLY)
// ---------------------------------------------------------------------------
// PICO-8's sprite sheet is 128x128, one hex nibble per pixel, its 16-color
// indices map through P8_PALETTE (the SAME mapping the runtime uses) to CAPTURE
// bytes. It fits in exactly one quadrant. Color 0 stays transparent. This is
// purely a migration on-ramp: import a PICO-8 cart's art into a real .gtg, then
// author natively from there.
export function p8GfxToGtg(p8text) {
  const seg = p8text.split("__gfx__")[1];
  if (!seg) throw new Error("no __gfx__ section in .p8 cart");
  const lines = seg.split("\n").map((l) => l.trim()).filter((l) => /^[0-9a-f]+$/.test(l));
  if (!lines.length) throw new Error("__gfx__ section had no pixel rows");
  const q = Buffer.alloc(QUADRANT_BYTES);
  for (let y = 0; y < Math.min(QUADRANT, lines.length); y++) {
    const row = lines[y];
    for (let x = 0; x < Math.min(QUADRANT, row.length); x++) {
      const idx = parseInt(row[x], 16);
      if (idx === 0) continue;                 // transparent -> color 0
      q[y * QUADRANT + x] = P8_PALETTE[idx & 15];
    }
  }
  return { quadrants: [q], width: QUADRANT, height: QUADRANT };
}

// ---------------------------------------------------------------------------
// legacy 4bpp gfx.bin -> .gtg quadrant (MIGRATION)
// ---------------------------------------------------------------------------
// gtlua's older sheet was an 8192-byte 4bpp PICO-8 gfx.bin: 128x128, two pixels
// per byte, low nibble = even-x pixel, high nibble = odd-x, each a 0-15 index
// through P8_PALETTE. Upconvert it to a native .gtg by expanding exactly the way
// the 4bpp runtime loader did (P8_PALETTE[nibble]) — so a migrated .gtg renders
// byte-identical to the game's current 4bpp sheet. Color 0 stays transparent.
export function gfxBinToGtg(bin) {
  if (bin.length !== 8192) throw new Error(`4bpp gfx.bin must be 8192 bytes (got ${bin.length})`);
  const q = Buffer.alloc(QUADRANT_BYTES);
  for (let i = 0; i < 8192; i++) {
    const b = bin[i];
    q[i * 2] = P8_PALETTE[b & 15];        // even x (low nibble)
    q[i * 2 + 1] = P8_PALETTE[b >> 4];    // odd x  (high nibble)
  }
  return { quadrants: [q], width: QUADRANT, height: QUADRANT };
}

// ---------------------------------------------------------------------------
// dispatch: any supported input file -> .gtg quadrants
// ---------------------------------------------------------------------------
export function toGtg(inputBuf, inputName) {
  const name = (inputName || "").toLowerCase();
  if (name.endsWith(".p8") || inputBuf.includes("__gfx__")) {
    return p8GfxToGtg(inputBuf.toString("utf8"));
  }
  if (name.endsWith(".png") ||
      (inputBuf[0] === 0x89 && inputBuf[1] === 0x50 && inputBuf[2] === 0x4e)) {
    const { width, height, rgba } = decodePng(inputBuf);
    return rgbaToGtg(width, height, rgba);
  }
  if (inputBuf.length === 8192) {                   // legacy 4bpp gfx.bin
    return gfxBinToGtg(inputBuf);
  }
  if (inputBuf.length === QUADRANT_BYTES) {         // already a raw .gtg quadrant
    return { quadrants: [inputBuf], width: QUADRANT, height: QUADRANT };
  }
  throw new Error(`unrecognized sheet input '${inputName}' (want .png, .p8, a 4bpp gfx.bin, or a 16384-byte .gtg)`);
}

// The official file names for a split: name.gtg, name_1.gtg, name_2.gtg, name_3.gtg.
export function gtgNames(baseName, count) {
  const stem = baseName.replace(/\.gtg$/i, "");
  const names = [`${stem}.gtg`];
  for (let i = 1; i < count; i++) names.push(`${stem}_${i}.gtg`);
  return names;
}

// deflate helpers so callers can match the official ROM's zopfli-deflated .gtg
// (Node's zlib deflate is inflate-compatible with the runtime's expectation).
export function deflate(buf) { return deflateSync(buf, { level: 9 }); }
export function inflate(buf) { return inflateSync(buf); }

// ---------------------------------------------------------------------------
// .gsi frame tables (sprite/animation frames)
// ---------------------------------------------------------------------------
// A .gsi is the official GameTank sprite-metadata format (sprite_metadata.js):
// a packed array of 8-byte Frame records
//   { vxo:int8, vyo:int8, w:uint8, h:uint8, gx:uint8, gy:uint8, 0, 0 }
// where gx/gy are the frame's pixel coordinates WITHIN THE SHEET, w/h its pixel
// size, and vxo/vyo the draw offset from the sprite's anchor. gtlua reads the
// first 6 bytes per frame; bytes 6-7 are ignored (kept for byte-for-byte
// compatibility with the official converter's output).
export const FRAME_BYTES = 8;

// Parse a .gsi blob into an array of {vxo,vyo,w,h,gx,gy} frames.
export function parseGsi(buf) {
  if (buf.length % FRAME_BYTES !== 0) {
    throw new Error(`.gsi length ${buf.length} is not a multiple of ${FRAME_BYTES}`);
  }
  const frames = [];
  for (let i = 0; i < buf.length; i += FRAME_BYTES) {
    frames.push({
      vxo: (buf[i] << 24) >> 24,      // int8
      vyo: (buf[i + 1] << 24) >> 24,  // int8
      w: buf[i + 2],
      h: buf[i + 3],
      gx: buf[i + 4],
      gy: buf[i + 5],
    });
  }
  return frames;
}

// Serialize frames back to a .gsi blob (8 bytes/frame, official layout).
export function encodeGsi(frames) {
  const buf = Buffer.alloc(frames.length * FRAME_BYTES);
  frames.forEach((f, i) => {
    const o = i * FRAME_BYTES;
    buf.writeInt8(f.vxo | 0, o);
    buf.writeInt8(f.vyo | 0, o + 1);
    buf[o + 2] = f.w & 255;
    buf[o + 3] = f.h & 255;
    buf[o + 4] = f.gx & 255;
    buf[o + 5] = f.gy & 255;
    // o+6, o+7 stay 0
  });
  return buf;
}

// Build a Frame table for the runtime, with the QUADRANT bit baked into gx/gy so
// the blit asm needs no quadrant logic. `quadOf(frameIndex)` returns which
// 128x128 quadrant (0=NW 1=NE 2=SW 3=SE) that frame's sheet lives in; the frame's
// gx/gy (0..127 within its quadrant) get bit7 OR'd on (GX bit7 = right column,
// GY bit7 = bottom row) so they become final GRAM source coords. Returns a
// flat Uint8Array of frames.length*6 bytes: {vxo,vyo,w,h,gx',gy'} per frame,
// which is what gt_frames_register / gt_gspr_frame consume. */
export function bakeFrameTable(frames, quadOf = () => 0) {
  const out = new Uint8Array(frames.length * 6);
  frames.forEach((f, i) => {
    const q = quadOf(i) & 3;
    const o = i * 6;
    out[o] = f.vxo & 255;
    out[o + 1] = f.vyo & 255;
    out[o + 2] = f.w & 255;
    out[o + 3] = f.h & 255;
    out[o + 4] = (f.gx & 127) | ((q & 1) ? 0x80 : 0);   // GX bit7 = right quad
    out[o + 5] = (f.gy & 127) | ((q & 2) ? 0x80 : 0);   // GY bit7 = bottom quad
  });
  return out;
}
