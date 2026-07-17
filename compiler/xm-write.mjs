// xm-write.mjs — compose a standard FastTracker II .xm module from note data.
// BROWSER-SAFE (pure JS, bytes out). This is the SDK utility behind the web
// IDE's step tracker and assets/make_music_xm.mjs: we write the REAL .xm
// format (playable in OpenMPT/MilkyTracker, compiled by romdev-maxmod into a
// Maxmod soundbank) — never an invented sibling format.
//
// XM format ref: FastTracker 2 v2.04 (.xm) spec.

// ── byte helpers ────────────────────────────────────────────────────
const u8 = (n) => new Uint8Array([n & 0xff]);
const u16 = (n) => new Uint8Array([n & 0xff, (n >> 8) & 0xff]);
const u32 = (n) => new Uint8Array([n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff]);
const padStr = (s, len) => {
  const buf = new Uint8Array(len);
  for (let i = 0; i < s.length && i < len; i++) buf[i] = s.charCodeAt(i);
  return buf;
};
const concat = (...parts) => {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
};

// ── notes ───────────────────────────────────────────────────────────
// XM note numbers: 1 = C-0 … 96 = B-7 (A-4 = 58 = 440 Hz). 97 = key-off.
export const NOTE = {};
{
  const names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
  for (let oct = 0; oct <= 7; oct++)
    for (let s = 0; s < 12; s++)
      NOTE[`${names[s]}${oct}`] = oct * 12 + s + 1;
}
export const KEY_OFF = 97;
export const noteName = (n) => {
  if (!n) return "···";
  if (n === KEY_OFF) return "OFF";
  const names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
  return names[(n - 1) % 12] + Math.floor((n - 1) / 12);
};
/** XM note number -> Hz (A-4 = 58 = 440). For preview synths. */
export const noteFreq = (n) => (n && n < KEY_OFF ? 440 * Math.pow(2, (n - 58) / 12) : 0);

// ── instruments (synthesized primitives, CC0) ───────────────────────
const SAMPLE_HEADER_SIZE = 40;
const INST_HEADER_SIZE = 263;

function deltaEncode(int8) {
  const out = new Int8Array(int8.length);
  let prev = 0;
  for (let i = 0; i < int8.length; i++) { out[i] = (int8[i] - prev) & 0xff; prev = int8[i]; }
  return new Uint8Array(out.buffer, out.byteOffset, out.byteLength);
}
// A DC-BALANCED pulse. A naive ±amp pulse at duty d has a huge DC offset
// (mean = amp*(2d-1)) — at 25% duty that's -0.5*amp of subsonic energy, which
// dominates the low end and sounds like a buzzy thump, not a note. Balance it
// by AREA: the high level and low level are weighted so the average is zero.
function squareSample(len, period, duty, amp) {
  const s = new Int8Array(len);
  const hi = Math.max(1, Math.floor(period * duty));
  const d = hi / period;                 // actual duty after rounding
  const high = Math.round(amp * 2 * (1 - d));   // +area
  const low = -Math.round(amp * 2 * d);         // -area (mean high*d + low*(1-d) ≈ 0)
  const clamp = (v) => (v > 127 ? 127 : v < -128 ? -128 : v);
  for (let i = 0; i < len; i++) s[i] = clamp((i % period) < hi ? high : low);
  return s;
}
function triangleSample(len, period, amp) {
  const s = new Int8Array(len);
  for (let i = 0; i < len; i++) {
    const ph = (i % period) / period;
    s[i] = Math.round((ph < 0.5 ? ph * 4 - 1 : 3 - ph * 4) * amp);
  }
  return s;
}
function noiseSample(len, amp) {
  const s = new Int8Array(len);
  let lfsr = 0xACE1;   // deterministic LFSR — reproducible bytes
  for (let i = 0; i < len; i++) {
    const bit = (lfsr ^ (lfsr >> 2) ^ (lfsr >> 3) ^ (lfsr >> 5)) & 1;
    lfsr = (lfsr >> 1) | (bit << 15);
    s[i] = (lfsr & 1) ? amp : -amp;
  }
  return s;
}

function buildInstrument(name, sampleInt8, { volEnv = [], fadeout = 0, loop = true } = {}) {
  const sampleBytes = deltaEncode(sampleInt8);
  const SAMPLE_LEN = sampleInt8.length;
  const volEnvPoints = new Uint8Array(48);
  const npts = Math.min(volEnv.length, 12);
  for (let i = 0; i < npts; i++) {
    volEnvPoints.set(u16(volEnv[i][0]), i * 4);
    volEnvPoints.set(u16(volEnv[i][1]), i * 4 + 2);
  }
  const instHeader = concat(
    u32(INST_HEADER_SIZE), padStr(name, 22), u8(0), u16(1),
    u32(SAMPLE_HEADER_SIZE), new Uint8Array(96),
    volEnvPoints, new Uint8Array(48),
    u8(npts), u8(0),
    u8(0), u8(0), u8(npts ? npts - 1 : 0),
    u8(0), u8(0), u8(0),
    u8(npts ? 0x01 : 0), u8(0), u8(0), u8(0), u8(0), u8(0),
    u16(fadeout), new Uint8Array(22),
  );
  if (instHeader.length !== INST_HEADER_SIZE) throw new Error(`inst header ${instHeader.length} != ${INST_HEADER_SIZE}`);
  const sampleHeader = concat(
    u32(SAMPLE_LEN), u32(0), u32(loop ? SAMPLE_LEN : 0),
    u8(64), u8(0), u8(loop ? 1 : 0), u8(128),
    u8(0), u8(0), padStr(name, 22),
  );
  if (sampleHeader.length !== SAMPLE_HEADER_SIZE) throw new Error(`sample header ${sampleHeader.length} != ${SAMPLE_HEADER_SIZE}`);
  return concat(instHeader, sampleHeader, sampleBytes);
}

/**
 * The built-in instrument bank (XM instruments are 1-based; grid cells
 * reference these by that number). Synthesized, deterministic, loopable.
 * The `synth` block is the Web-Audio preview hint (type/duty/envelope).
 */
export const XM_INSTRUMENTS = [
  { id: 1, name: "lead", synth: { type: "square", duty: 0.25, a: 0.005, d: 0.4, s: 0.45, r: 0.12 } },
  { id: 2, name: "bass", synth: { type: "square", duty: 0.5, a: 0.005, d: 0.3, s: 0.6, r: 0.1 } },
  { id: 3, name: "drum", synth: { type: "noise", a: 0.001, d: 0.12, s: 0, r: 0.04 } },
  { id: 4, name: "chip", synth: { type: "square", duty: 0.125, a: 0.001, d: 0.2, s: 0.5, r: 0.05 } },
  { id: 5, name: "tri", synth: { type: "triangle", a: 0.01, d: 0.3, s: 0.6, r: 0.15 } },
];

function instrumentBytes() {
  return concat(
    buildInstrument("lead", squareSample(256, 64, 0.25, 60), { volEnv: [[0, 0], [1, 64], [8, 52], [40, 40], [64, 0]], fadeout: 512 }),
    buildInstrument("bass", squareSample(256, 64, 0.5, 64), { volEnv: [[0, 48], [2, 64], [32, 50], [64, 40]], fadeout: 128 }),
    buildInstrument("drum", noiseSample(128, 58), { volEnv: [[0, 64], [4, 30], [10, 0]], fadeout: 2048, loop: false }),
    buildInstrument("chip", squareSample(256, 64, 0.125, 56), { volEnv: [[0, 64], [12, 44], [48, 36], [64, 0]], fadeout: 256 }),
    buildInstrument("tri", triangleSample(256, 64, 64), { volEnv: [[0, 32], [2, 64], [40, 44], [64, 24]], fadeout: 128 }),
  );
}

// ── patterns ────────────────────────────────────────────────────────
// Packed cell: bit7=1 + field bits (bit0 note, bit1 inst, bit2 vol).
// XM volume column 0x10..0x50 = set volume 0..64.
function cellBytes(cell) {
  if (!cell || !cell.note) return u8(0x80);
  let mask = 0x80 | 0x01 | 0x02;
  const parts = [cell.note & 0xff, (cell.inst ?? 1) & 0xff];
  if (cell.vol != null) { mask |= 0x04; parts.push((0x10 + Math.max(0, Math.min(64, cell.vol))) & 0xff); }
  return new Uint8Array([mask, ...parts]);
}

function buildPattern(grid, channels) {
  const rows = [];
  for (const row of grid) {
    for (let ch = 0; ch < channels; ch++) rows.push(cellBytes(row[ch]));
  }
  const body = concat(...rows);
  return concat(u32(9), u8(0), u16(grid.length), u16(body.length), body);
}

/**
 * Write a .xm module.
 * @param {Object} args
 * @param {string} [args.title="song"]
 * @param {number} [args.channels=4]
 * @param {number} [args.speed=6]  ticks per row
 * @param {number} [args.bpm=130]
 * @param {Array<Array<Array<{note:number,inst?:number,vol?:number}|0>>>} args.patterns
 *   patterns[p][row][ch] — note 1..96 (KEY_OFF=97), inst 1-based into
 *   XM_INSTRUMENTS, vol 0..64 (omit for full)
 * @param {number[]} [args.order] pattern play order (default [0..patterns-1])
 * @returns {Uint8Array} the .xm file bytes
 */
export function writeXm({ title = "song", channels = 4, speed = 6, bpm = 130, patterns, order } = {}) {
  if (!patterns?.length) throw new Error("writeXm: no patterns");
  const ord = order ?? patterns.map((_, i) => i);
  const orderTable = new Uint8Array(256);
  orderTable.set(ord, 0);

  const moduleHeader = concat(
    u32(20 + 256), u16(ord.length), u16(0), u16(channels),
    u16(patterns.length), u16(XM_INSTRUMENTS.length), u16(1), u16(speed), u16(bpm), orderTable,
  );
  const patBytes = concat(...patterns.map((g) => buildPattern(g, channels)));
  return concat(
    padStr("Extended Module: ", 17), padStr(title, 20), u8(0x1a),
    padStr("gbalua", 20), u16(0x0104),
    moduleHeader, patBytes, instrumentBytes(),
  );
}
