#!/usr/bin/env node
// p8sfx — convert a PICO-8 cart's __sfx__ data to a gtlua sfx bank blob.
//
// Input: an extracted cart.bin (the 32KB PICO-8 ROM image; sfx live at
// 0x3200, 64 effects x 68 bytes) or a .p8 text cart (__sfx__ section).
// Output: a hexdata() string for the port + a human-readable listing.
//
// Mapping to the SDK's 4-op FM runtime (gt_music.h):
//   pitch  p (0-63)  -> 1-based MIDI note p + 36 (P8 pitch 33 = A4 = MIDI 69)
//   volume 0         -> rest (note 0)
//   speed  s         -> each P8 note lasts s/128 seconds = s*60/128 frames;
//                       fractional frames accumulate (Bresenham) so total
//                       length matches the original
//   waveform         -> the closest built-in FM instrument (dominant wave
//                       of the effect; per-note instrument switches are not
//                       representable in one sfx run)
//   effects (slide/vibrato/...) -> dropped in v1 (pitch/timing first)
//
// Bank blob format (consumed by gt_sfx_bank in gt_music.c):
//   u8 n; n x u16le offset (from blob start);
//   per sfx: u8 instr, u8 count, count x { u8 note, u8 dur }.
//   count 0 = the effect is empty (gt_sfx falls back to the builtins).
import { readFileSync } from "node:fs";

const WAVE_TO_INSTR = {
  0: 0, // triangle  -> PIANO
  1: 4, // tilted saw-> SITAR
  2: 5, // saw       -> HORN
  3: 7, // square    -> BLIP
  4: 7, // pulse     -> BLIP
  5: 0, // organ     -> PIANO
  6: 3, // noise     -> SNARE
  7: 4, // phaser    -> SITAR
};

function parseCartBin(buf) {
  const sfx = [];
  for (let n = 0; n < 64; n++) {
    const off = 0x3200 + n * 68;
    const notes = [];
    for (let k = 0; k < 32; k++) {
      const w = buf[off + k * 2] | (buf[off + k * 2 + 1] << 8);
      notes.push({ pitch: w & 63, wave: (w >> 6) & 7, vol: (w >> 9) & 7, fx: (w >> 12) & 7 });
    }
    sfx.push({ speed: buf[off + 65], loopStart: buf[off + 66], loopEnd: buf[off + 67], notes });
  }
  return sfx;
}

function parseP8Text(text) {
  const m = text.split("__sfx__")[1];
  if (!m) return Array.from({ length: 64 }, () => ({ speed: 1, loopStart: 0, loopEnd: 0, notes: [] }));
  const lines = m.split("\n").map((l) => l.trim()).filter((l) => /^[0-9a-f]{168}$/.test(l));
  const sfx = [];
  for (const line of lines) {
    const hx = (i, n) => parseInt(line.slice(i, i + n), 16);
    const notes = [];
    for (let k = 0; k < 32; k++) {
      const p = 8 + k * 5;
      notes.push({ pitch: hx(p, 2), wave: hx(p + 2, 1) & 7, vol: hx(p + 3, 1), fx: hx(p + 4, 1) });
    }
    sfx.push({ speed: hx(2, 2), loopStart: hx(4, 2), loopEnd: hx(6, 2), notes });
  }
  while (sfx.length < 64) sfx.push({ speed: 1, loopStart: 0, loopEnd: 0, notes: [] });
  return sfx;
}

function convertOne(e) {
  // trailing silence trims; leading/mid rests keep timing
  let last = -1;
  for (let k = 0; k < e.notes.length; k++) if (e.notes[k].vol > 0) last = k;
  if (last < 0) return null;
  const framesPer = (e.speed * 60) / 128;
  // dominant wave among voiced notes
  const waveCount = {};
  for (let k = 0; k <= last; k++) {
    const n = e.notes[k];
    if (n.vol > 0) waveCount[n.wave] = (waveCount[n.wave] ?? 0) + 1;
  }
  const wave = +Object.entries(waveCount).sort((a, b) => b[1] - a[1])[0][0];
  const steps = [];
  let acc = 0;
  for (let k = 0; k <= last; k++) {
    const n = e.notes[k];
    acc += framesPer;
    let dur = Math.floor(acc);
    acc -= dur;
    if (dur < 1) { continue; } // sub-frame note: fold into the accumulator
    if (dur > 255) dur = 255;
    const note = n.vol > 0 ? n.pitch + 36 : 0;
    const prev = steps[steps.length - 1];
    if (prev && prev.note === note) prev.dur = Math.min(255, prev.dur + dur);
    else steps.push({ note, dur });
  }
  if (!steps.length) return null;
  return { instr: WAVE_TO_INSTR[wave] ?? 7, steps };
}

const [, , input] = process.argv;
if (!input) { console.error("usage: p8sfx.mjs <cart.bin|cart.p8>"); process.exit(1); }
const raw = readFileSync(input);
const sfx = input.endsWith(".p8") || input.endsWith(".lua")
  ? parseP8Text(raw.toString("latin1"))
  : parseCartBin(raw);

const converted = sfx.map(convertOne);
const lastUsed = converted.reduce((m, c, i) => (c ? i : m), -1);
const n = lastUsed + 1;

// pack the bank
const bodies = [];
let off = 1 + n * 2;
const offsets = [];
for (let i = 0; i < n; i++) {
  const c = converted[i];
  offsets.push(off);
  if (!c) { bodies.push(Buffer.from([0, 0])); off += 2; continue; }
  const b = Buffer.alloc(2 + c.steps.length * 2);
  b[0] = c.instr;
  b[1] = c.steps.length;
  c.steps.forEach((s, k) => { b[2 + k * 2] = s.note; b[3 + k * 2] = s.dur; });
  bodies.push(b);
  off += b.length;
}
const head = Buffer.alloc(1 + n * 2);
head[0] = n;
offsets.forEach((o, i) => head.writeUInt16LE(o, 1 + i * 2));
const blob = Buffer.concat([head, ...bodies]);

console.error(`-- ${n} sfx slots, ${blob.length} bytes`);
converted.slice(0, n).forEach((c, i) => {
  if (!c) return;
  const inm = ["PIANO", "GUITAR", "BASS", "SNARE", "SITAR", "HORN", "BELL", "BLIP"][c.instr];
  console.error(`--   sfx ${i}: ${c.steps.length} steps, instr ${inm}, first notes ${c.steps.slice(0, 5).map((s) => s.note + "x" + s.dur).join(" ")}`);
});
console.log(blob.toString("hex"));
