// make_music_xm.mjs — generates `music.xm`, the SDK's default background tune.
//
// A richer replacement for the old 2-channel arpeggio: FOUR channels (lead,
// bass, harmony/arp, drums), THREE instruments (square lead, softer square
// bass, noise drum), and FOUR patterns arranged into an 8-step song order so it
// reads as an actual looping chiptune (a i-VI-III-VII-ish loop in A minor) not a
// one-bar loop. Everything is synthesized from primitives (CC0 / public domain);
// no third-party tracker modules.
//
// Output is a standard FastTracker II .xm. Compile to a Maxmod soundbank with
// romdev's pure-JS mmutil port (see build_soundbank.mjs).
//
//   node make_music_xm.mjs      # writes music.xm next to this file
//
// XM format ref: FastTracker 2 v2.04 (.xm) spec.

import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── byte helpers ────────────────────────────────────────────────────
const u8  = (n) => new Uint8Array([n & 0xff]);
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

// ── note names → XM note numbers (1..96; 49 = A-4 = 440Hz, C-4 = 40) ─
// XM note = (octave)*12 + semitone + 1, with C-0 = 1. So C-4 = 4*12+0+1 = 49? No:
// the spec uses 1 = C-0. C-4 = 49 in this generator's original; we keep C-4=49.
const NOTE = {};
{
  const names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"];
  for (let oct = 0; oct <= 7; oct++)
    for (let s = 0; s < 12; s++)
      NOTE[`${names[s]}${oct}`] = oct * 12 + s + 1;
}
const N = (name) => NOTE[name];      // e.g. N("A4")
const OFF = 97;                       // XM note 97 = key-off

// ── song config ─────────────────────────────────────────────────────
const NUM_CHANNELS = 4;
const NUM_ROWS = 16;                  // rows per pattern
const TEMPO_TICKS = 6;                // ticks/row
const BPM = 130;                      // a touch livelier than the old 125

// Instruments: 1 = square lead, 2 = square bass (fuller), 3 = noise drum.
const INST_LEAD = 1, INST_BASS = 2, INST_DRUM = 3;

// A minor-ish loop: four bars, each over a chord. Bass roots + a lead motif +
// an arpeggio of the chord + a simple kick/hat drum groove.
// Chords (root note for bass, and 3 arp notes for the harmony channel):
//   bar 0: Am  (A2 bass; arp A3 C4 E4)
//   bar 1: F   (F2 bass; arp F3 A3 C4)
//   bar 2: C   (C3 bass; arp C4 E4 G4)
//   bar 3: G   (G2 bass; arp G3 B3 D4)
const BARS = [
  { bass: "A2", arp: ["A3","C4","E4"], lead: ["A4",0,"C5",0,"E4",0,"A4",0,"E4",0,"C5",0,"B4",0,"A4",0] },
  { bass: "F2", arp: ["F3","A3","C4"], lead: ["C5",0,"A4",0,"F4",0,"A4",0,"C5",0,"F5",0,"E5",0,"C5",0] },
  { bass: "C3", arp: ["C4","E4","G4"], lead: ["E5",0,"G4",0,"C5",0,"E5",0,"G5",0,"E5",0,"D5",0,"C5",0] },
  { bass: "G2", arp: ["G3","B3","D4"], lead: ["D5",0,"B4",0,"G4",0,"B4",0,"D5",0,"G5",0,"F5",0,"D5",0] },
];

// ── build a pattern's packed body ───────────────────────────────────
// Packed cell: byte with bit7=1 and field bits: bit0=note bit1=inst bit2=vol
// bit3=fxtype bit4=fxparam. We use note+inst (+vol for accents).
function cell(note, inst, vol) {
  if (!note && note !== OFF) return u8(0x80);         // empty cell
  let mask = 0x80 | 0x01 | 0x02;                       // note + instrument
  const parts = [note & 0xff, inst & 0xff];
  if (vol != null) { mask |= 0x04; parts.push(vol & 0xff); }   // volume column
  return new Uint8Array([mask, ...parts]);
}

// drum groove: kick on rows 0,8; hat on the offbeats. Volume-accented.
// XM volume column 0x10..0x50 = set volume 0..64.
const VOL = (v) => 0x10 + Math.max(0, Math.min(64, v));

function buildPattern(barIndex) {
  const bar = BARS[barIndex];
  const rows = [];
  for (let row = 0; row < NUM_ROWS; row++) {
    // ch0 lead
    const ln = bar.lead[row];
    rows.push(ln ? cell(N(ln), INST_LEAD, VOL(50)) : u8(0x80));
    // ch1 bass — root on row 0 and 8 (half notes), sustained
    const bn = (row === 0 || row === 8) ? bar.bass : 0;
    rows.push(bn ? cell(N(bn), INST_BASS, VOL(58)) : u8(0x80));
    // ch2 harmony arpeggio — cycle the 3 chord tones every row (steps of 2)
    const an = (row % 2 === 0) ? bar.arp[(row / 2) % 3] : 0;
    rows.push(an ? cell(N(an), INST_LEAD, VOL(30)) : u8(0x80));
    // ch3 drums — kick (low) on 0/8, hat (mid, quiet) on odd rows
    let dn = 0, dv = 0;
    if (row === 0 || row === 8) { dn = N("C3"); dv = 60; }          // kick
    else if (row % 2 === 1)     { dn = N("C5"); dv = 22; }          // hat
    rows.push(dn ? cell(dn, INST_DRUM, VOL(dv)) : u8(0x80));
  }
  const body = concat(...rows);
  return concat(u32(9), u8(0), u16(NUM_ROWS), u16(body.length), body);
}

// ── instruments ─────────────────────────────────────────────────────
// Each instrument = one looped 8-bit sample + a volume envelope so notes have
// an attack/decay/release (this is the big richness win vs the old flat square).
const SAMPLE_HEADER_SIZE = 40;
const INST_HEADER_SIZE = 263;

// delta-encode an Int8 sample (XM stores deltas).
function deltaEncode(int8) {
  const out = new Int8Array(int8.length);
  let prev = 0;
  for (let i = 0; i < int8.length; i++) { out[i] = (int8[i] - prev) & 0xff; prev = int8[i]; }
  return new Uint8Array(out.buffer, out.byteOffset, out.byteLength);
}

// square wave at a given duty (0..1), `len` samples, `period` samples/cycle.
function squareSample(len, period, duty, amp) {
  const s = new Int8Array(len);
  const hi = Math.floor(period * duty);
  for (let i = 0; i < len; i++) s[i] = (i % period) < hi ? amp : -amp;
  return s;
}
// pseudo-noise sample (for drums) — deterministic LFSR so it's reproducible.
function noiseSample(len, amp) {
  const s = new Int8Array(len);
  let lfsr = 0xACE1;
  for (let i = 0; i < len; i++) {
    const bit = (lfsr ^ (lfsr >> 2) ^ (lfsr >> 3) ^ (lfsr >> 5)) & 1;
    lfsr = (lfsr >> 1) | (bit << 15);
    s[i] = (lfsr & 1) ? amp : -amp;
  }
  return s;
}

// build one instrument (with a volume envelope). `env` = [[x,y],...] points
// (x in ticks, y in 0..64). loopType: 1 = forward loop the whole sample.
function instrument(name, sampleInt8, { volEnv = [], fadeout = 0, loop = true } = {}) {
  const sampleBytes = deltaEncode(sampleInt8);
  const SAMPLE_LEN = sampleInt8.length;

  // outer + extended header
  const instHeaderSize = u32(INST_HEADER_SIZE);
  const instName = padStr(name, 22);
  const instType = u8(0);
  const instNumSamples = u16(1);
  const sampleHeaderSizeField = u32(SAMPLE_HEADER_SIZE);
  const sampleNumForNotes = new Uint8Array(96);   // all notes → sample 0

  // volume envelope: up to 12 points, each u16 x + u16 y (48 bytes).
  const volEnvPoints = new Uint8Array(48);
  const npts = Math.min(volEnv.length, 12);
  for (let i = 0; i < npts; i++) {
    volEnvPoints.set(u16(volEnv[i][0]), i * 4);
    volEnvPoints.set(u16(volEnv[i][1]), i * 4 + 2);
  }
  const panEnvPoints = new Uint8Array(48);
  const volEnvCount = u8(npts);
  const panEnvCount = u8(0);
  const volSustain = u8(0);
  const volLoopStart = u8(0);
  const volLoopEnd = u8(npts ? npts - 1 : 0);
  const panSustain = u8(0), panLoopStart = u8(0), panLoopEnd = u8(0);
  const volType = u8(npts ? 0x01 : 0);   // bit0 = envelope on
  const panType = u8(0);
  const vibType = u8(0), vibSweep = u8(0), vibDepth = u8(0), vibRate = u8(0);
  const volFadeout = u16(fadeout);
  const reserved = new Uint8Array(22);

  const instHeader = concat(
    instHeaderSize, instName, instType, instNumSamples,
    sampleHeaderSizeField, sampleNumForNotes,
    volEnvPoints, panEnvPoints,
    volEnvCount, panEnvCount,
    volSustain, volLoopStart, volLoopEnd,
    panSustain, panLoopStart, panLoopEnd,
    volType, panType, vibType, vibSweep, vibDepth, vibRate,
    volFadeout, reserved,
  );
  if (instHeader.length !== INST_HEADER_SIZE)
    throw new Error(`inst header ${instHeader.length} != ${INST_HEADER_SIZE}`);

  const sampleHeader = concat(
    u32(SAMPLE_LEN), u32(0), u32(loop ? SAMPLE_LEN : 0),
    u8(64), u8(0), u8(loop ? 1 : 0), u8(128),
    u8(0), u8(0), padStr(name, 22),
  );
  if (sampleHeader.length !== SAMPLE_HEADER_SIZE)
    throw new Error(`sample header ${sampleHeader.length} != ${SAMPLE_HEADER_SIZE}`);

  return concat(instHeader, sampleHeader, sampleBytes);
}

// lead: bright 25% pulse with a quick attack + gentle decay envelope.
const leadInst = instrument("lead", squareSample(256, 64, 0.25, 60), {
  volEnv: [[0, 0], [1, 64], [8, 52], [40, 40], [64, 0]], fadeout: 512,
});
// bass: fuller 50% square, sustained, slight decay.
const bassInst = instrument("bass", squareSample(256, 64, 0.5, 64), {
  volEnv: [[0, 48], [2, 64], [32, 50], [64, 40]], fadeout: 128,
});
// drum: short noise burst with a fast decay (kick/hat depending on pitch).
const drumInst = instrument("drum", noiseSample(128, 58), {
  volEnv: [[0, 64], [4, 30], [10, 0]], fadeout: 2048, loop: false,
});

// ── file header ─────────────────────────────────────────────────────
const id = padStr("Extended Module: ", 17);
const title = padStr("gba-lua theme      ", 20);
const marker = u8(0x1a);
const tracker = padStr("gba-lua             ", 20);
const version = u16(0x0104);

// song order: play the 4 patterns twice (0,1,2,3,0,1,2,3) → an 8-bar loop.
const ORDER = [0, 1, 2, 3, 0, 1, 2, 3];
const NUM_PATS = 4;
const order = new Uint8Array(256);
order.set(ORDER, 0);

const moduleHeader = concat(
  u32(20 + 256), u16(ORDER.length), u16(0), u16(NUM_CHANNELS),
  u16(NUM_PATS), u16(3), u16(1), u16(TEMPO_TICKS), u16(BPM), order,
);

const patterns = concat(buildPattern(0), buildPattern(1), buildPattern(2), buildPattern(3));
const instruments = concat(leadInst, bassInst, drumInst);

const xm = concat(id, title, marker, tracker, version, moduleHeader, patterns, instruments);

const outPath = join(__dirname, "music.xm");
writeFileSync(outPath, xm);
console.log(`wrote ${outPath} (${xm.length} bytes) — ${NUM_CHANNELS}ch, ${NUM_PATS} patterns, 3 instruments`);
