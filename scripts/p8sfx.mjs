#!/usr/bin/env node
// p8sfx — convert PICO-8 __sfx__ data into a paste-able gtlua source block
// (note-event arrays + a tiny one-channel player driven from _update).
//
//   node scripts/p8sfx.mjs <cart.p8 | cart.bin> --sfx 9,18,20 [options]
//   node scripts/p8sfx.mjs <cart.p8 | cart.bin> --list
//
// Inputs:
//   cart.p8   plain-text cart — the __sfx__ section (one 168-hex-digit line
//             per sfx: 8 header digits [editor mode, speed, loop start,
//             loop end — 2 each] + 32 notes x 5 digits [pitch 2, waveform 1,
//             volume 1, effect 1]).
//   cart.bin  raw cart image (e.g. scripts/p8extract.mjs output): sfx live
//             at 0x3200-0x42FF, 64 records x 68 bytes = 32 notes x 2 bytes
//             little-endian bit-packed (pitch 0-5, waveform 6-8, volume
//             9-11, effect 12-14, custom-instrument flag 15) + 4 header
//             bytes at the END (editor mode, speed, loop start, loop end).
//
// Pitch: PICO-8 pitch p sounds at 65.406*2^(p/12) Hz (p8 33 = A4 440 Hz =
// MIDI 69). The GameTank pitch table is MIDI-shaped, but the ACP firmware
// renders one table step per ~14 kHz sample, which sounds one octave ABOVE
// the MIDI number (gt.note(69) measures 880 Hz by FFT on the emulator).
// True-pitch conversion is therefore gt = p8 + 24 (the default). If a
// future core/firmware runs the table at 6991.3 Hz (the rate the table's
// MIDI naming implies), use --transpose 36. Full analysis: docs/sfx.md.
//
// Timing: a PICO-8 row lasts speed/128 s. The player ticks once per _update
// (30 fps), i.e. 128/30 = 4.267 ticks per frame, so the converter resamples
// each sfx on the frame grid (sampling at frame midpoints) and run-length
// merges identical frames into (note, vol, duration) events. Rows shorter
// than a frame are resampled — very fast sfx (speed <= 4) lose in-between
// rows but keep their overall contour and length.
//
// Effects: 1 slide, 3 drop, 4 fade-in, 5 fade-out, 6/7 arpeggio are
// approximated at frame granularity (per-frame pitch/volume steps);
// 2 vibrato is dropped (sub-semitone — the pitch table has no detune).
// All waveforms render as the GameTank's sine voice (documented timbre
// difference; noise + custom instruments flagged in the emitted comments).
//
// Options:
//   --sfx <list>      comma-separated sfx numbers 0-63 (order = play ids)
//   --prefix <name>   identifier prefix, default "sfx"
//   --channel <0-3>   GameTank audio channel, default 3
//   --fps <30|60>     tick rate: 30 for _update, 60 for _update60 (default 30)
//   --transpose <n>   semitone offset added to P8 pitch, default 24
//   --out <file>      write the block to a file instead of stdout
//   --list            print a table of every sfx in the cart and exit
//
// Zero-dep, ESM. See docs/sfx.md for the paste-into-game workflow.

import { readFileSync, writeFileSync } from "node:fs";

const TICKS_PER_SEC = 128;      // PICO-8: one tick = 1/128 s
const ROWS = 32;
const SFX_COUNT = 64;
const SFX_BIN_OFFSET = 0x3200;
const SFX_BIN_SIZE = 68;

function usage(code) {
  const text = readFileSync(new URL(import.meta.url)).toString();
  // print the header comment as help
  for (const line of text.split("\n")) {
    if (!line.startsWith("//") && line.trim() !== "" && !line.startsWith("#!")) break;
    if (line.startsWith("//")) console.log(line.slice(3));
  }
  process.exit(code);
}

function fail(msg) {
  console.error(`p8sfx: ${msg}`);
  process.exit(1);
}

// ---------------------------------------------------------------- parsing

/** @typedef {{pitch:number, wave:number, vol:number, fx:number}} Note */
/** @typedef {{mode:number, speed:number, loopStart:number, loopEnd:number, notes:Note[]}} Sfx */

/** @param {string} text @returns {Sfx[]} */
function parseText(text) {
  const lines = text.split(/\r?\n/);
  const at = lines.findIndex((l) => l.trim() === "__sfx__");
  if (at === -1) fail("no __sfx__ section in this .p8 file");
  const out = [];
  for (let i = at + 1; i < lines.length && out.length < SFX_COUNT; i++) {
    const l = lines[i].trim();
    if (l.startsWith("__")) break;
    if (l === "") continue;
    if (!/^[0-9a-fA-F]{168}$/.test(l)) fail(`__sfx__ line ${out.length}: expected 168 hex digits, got ${l.length} chars`);
    const hx = (s, e) => parseInt(l.slice(s, e), 16);
    const notes = [];
    for (let n = 0; n < ROWS; n++) {
      const o = 8 + n * 5;
      notes.push({ pitch: hx(o, o + 2), wave: hx(o + 2, o + 3), vol: hx(o + 3, o + 4), fx: hx(o + 4, o + 5) });
    }
    out.push({ mode: hx(0, 2), speed: hx(2, 4), loopStart: hx(4, 6), loopEnd: hx(6, 8), notes });
  }
  return out;
}

/** @param {Buffer} buf @returns {Sfx[]} */
function parseBin(buf) {
  if (buf.length < SFX_BIN_OFFSET + SFX_COUNT * SFX_BIN_SIZE)
    fail(`binary cart too small (${buf.length} bytes) — need the full 0x8000 image (p8extract.mjs cart.bin)`);
  const out = [];
  for (let i = 0; i < SFX_COUNT; i++) {
    const base = SFX_BIN_OFFSET + i * SFX_BIN_SIZE;
    const notes = [];
    for (let n = 0; n < ROWS; n++) {
      const w = buf.readUInt16LE(base + n * 2);
      notes.push({
        pitch: w & 0x3f,
        wave: ((w >> 6) & 0x7) | (((w >> 15) & 1) << 3), // bit 15 = custom-instrument flag -> waveform 8-15
        vol: (w >> 9) & 0x7,
        fx: (w >> 12) & 0x7,
      });
    }
    out.push({ mode: buf[base + 64], speed: buf[base + 65], loopStart: buf[base + 66], loopEnd: buf[base + 67], notes });
  }
  return out;
}

/** re-encode a parsed sfx into the 68-byte binary record (round-trip check) */
function encodeBin(sfx) {
  const b = Buffer.alloc(SFX_BIN_SIZE);
  sfx.notes.forEach((n, i) => {
    const w = (n.pitch & 0x3f) | ((n.wave & 0x7) << 6) | ((n.vol & 0x7) << 9) |
              ((n.fx & 0x7) << 12) | ((n.wave & 0x8) ? 0x8000 : 0);
    b.writeUInt16LE(w, i * 2);
  });
  b[64] = sfx.mode; b[65] = sfx.speed; b[66] = sfx.loopStart; b[67] = sfx.loopEnd;
  return b;
}

/** @param {string} file @returns {Sfx[]} */
function loadCart(file) {
  const buf = readFileSync(file);
  const head = buf.subarray(0, Math.min(buf.length, 512)).toString("latin1");
  const looksText = /pico-8 cartridge|__lua__|__sfx__/.test(head) ||
    (/\.p8$/i.test(file) && !/\.p8\.png$/i.test(file));
  if (/\.png$/i.test(file)) fail("got a .p8.png — run scripts/p8extract.mjs first and pass its cart.bin");
  return looksText ? parseText(buf.toString("utf8")) : parseBin(buf);
}

// ------------------------------------------------------------- resampling

const WAVE_NAMES = ["tri", "tilted-saw", "saw", "square", "pulse", "organ", "noise", "phaser"];
const FX_NAMES = ["", "slide", "vibrato", "drop", "fade-in", "fade-out", "arp-fast", "arp-slow"];

function volMap(v) { // P8 0-7 (may be fractional after lerp) -> gt 0-127
  return Math.max(0, Math.min(127, Math.round((v * 127) / 7)));
}

function rowIsSilent(n) { return n.vol === 0 && n.fx !== 1; } // a slide row inherits prev volume ramping to 0 — audible

/**
 * Resample one sfx onto the frame grid and RLE into events.
 * @returns {{events:{note:number,vol:number,dur:number}[], loopEvent:number,
 *            rows:number, frames:number, notesUsed:Note[], loops:boolean}}
 */
function convertSfx(sfx, { fps, transpose }) {
  const speed = Math.max(1, sfx.speed);
  const loops = sfx.loopEnd > sfx.loopStart;
  let rows = loops ? sfx.loopEnd : ROWS;
  if (!loops) { // one-shot: trim trailing silence
    while (rows > 0 && rowIsSilent(sfx.notes[rows - 1])) rows--;
  }
  if (rows === 0) return { events: [], loopEvent: 0, rows: 0, frames: 0, notesUsed: [], loops };

  const ticksPerFrame = TICKS_PER_SEC / fps;
  const totalTicks = rows * speed;
  const frames = Math.max(1, Math.round(totalTicks / ticksPerFrame));
  const loopFrame = loops
    ? Math.min(frames - 1, Math.round((sfx.loopStart * speed) / ticksPerFrame))
    : -1;

  // sample (pitch, vol) at one frame's midpoint, applying effects
  function sample(f) {
    let t = (f + 0.5) * ticksPerFrame;
    if (t >= totalTicks) t = totalTicks - 1e-6;
    const r = Math.floor(t / speed);
    const frac = (t - r * speed) / speed;
    const n = sfx.notes[r];
    let pitch = n.pitch;
    let vol = n.vol;
    switch (n.fx) {
      case 1: { // slide from previous row's pitch+volume to this row's
        const p = r > 0 ? sfx.notes[r - 1] : n;
        pitch = p.pitch + (n.pitch - p.pitch) * frac;
        vol = p.vol + (n.vol - p.vol) * frac;
        break;
      }
      case 3: // drop: pitch falls to the floor across the row
        pitch = n.pitch * (1 - frac);
        break;
      case 4: vol = n.vol * frac; break;        // fade in
      case 5: vol = n.vol * (1 - frac); break;  // fade out
      case 6: case 7: { // arpeggio over the current group of 4 rows
        // P8: fast = a 4-tick step, slow = 8 ticks; halved when speed <= 8
        const step = (n.fx === 6 ? 4 : 8) / (speed <= 8 ? 2 : 1);
        const g = r & ~3;
        const k = Math.floor(t / step) % 4;
        const gn = sfx.notes[Math.min(g + k, ROWS - 1)];
        pitch = gn.pitch;
        break;
      }
      // 2 vibrato: sub-semitone wobble — dropped, plain note
    }
    const gtNote = Math.max(0, Math.min(107, Math.round(pitch + transpose)));
    const gtVol = volMap(vol);
    return gtVol === 0 ? { note: 0, vol: 0 } : { note: gtNote, vol: gtVol };
  }

  const events = [];
  let loopEvent = 0; // 1-based index into events, 0 = none
  for (let f = 0; f < frames; f++) {
    const s = sample(f);
    const last = events[events.length - 1];
    if (f !== loopFrame && last && last.note === s.note && last.vol === s.vol) {
      last.dur++;
    } else {
      events.push({ note: s.note, vol: s.vol, dur: 1 });
      if (f === loopFrame) loopEvent = events.length;
    }
  }
  const notesUsed = sfx.notes.slice(0, rows).filter((n) => !rowIsSilent(n));
  return { events, loopEvent, rows, frames, notesUsed, loops };
}

// ------------------------------------------------------------------ emit

function describeSfx(sfx, conv) {
  const waves = [...new Set(conv.notesUsed.map((n) => n.wave))]
    .map((w) => (w >= 8 ? `custom-${w - 8}` : WAVE_NAMES[w])).join(",") || "-";
  const fxs = [...new Set(conv.notesUsed.map((n) => n.fx).filter((f) => f > 0))]
    .map((f) => FX_NAMES[f]).join(",");
  const loop = conv.loops ? ` loop ${sfx.loopStart}-${sfx.loopEnd}` : "";
  return `${conv.rows} rows @ speed ${Math.max(1, sfx.speed)}${loop}, ` +
    `${conv.frames}f, wave ${waves}${fxs ? `, fx ${fxs}` : ""}`;
}

function emit(cartName, records, picks, opts) {
  const { prefix: P, channel, fps, transpose } = opts;
  const convs = picks.map((id) => {
    const c = convertSfx(records[id], opts);
    if (c.events.length === 0) fail(`sfx ${id} is empty (all rows silent) — nothing to convert`);
    return { id, ...c };
  });

  // absolute event indices (1-based, gtlua arrays)
  let at = 1;
  for (const c of convs) {
    c.first = at;
    c.last = at + c.events.length - 1;
    c.loopAbs = c.loopEvent > 0 ? c.first + c.loopEvent - 1 : 0;
    at += c.events.length;
  }
  const total = at - 1;
  if (total > 4096) fail(`${total} events exceed the 4096-element array cap — select fewer sfx`);

  const L = [];
  L.push(`-- p8sfx: ${picks.join(",")} from ${cartName}`);
  L.push(`-- ${total} events (${total * 6} bytes RAM), channel ${channel}, ${fps} fps tick, pitch +${transpose}`);
  L.push(`-- call ${P}_init() from _init, ${P}_tick() every _update${fps === 60 ? "60" : ""},`);
  L.push(`-- ${P}_play(id) to start, ${P}_stop() to cut. ids:`);
  for (const c of convs) {
    const warn = [];
    if (c.notesUsed.some((n) => n.wave === 6)) warn.push("NOISE->sine");
    if (c.notesUsed.some((n) => n.wave >= 8)) warn.push("custom-instrument->sine");
    if (c.notesUsed.some((n) => n.fx === 2)) warn.push("vibrato dropped");
    L.push(`--   ${P}_${c.id} = sfx ${c.id}: ${describeSfx(records[c.id], c)}` +
      (warn.length ? ` [${warn.join("; ")}]` : ""));
  }
  convs.forEach((c, i) => L.push(`local ${P}_${c.id} = ${i + 1}`));
  L.push(`local ${P}_ev_note = array(${total})`);
  L.push(`local ${P}_ev_vol = array(${total})`);
  L.push(`local ${P}_ev_dur = array(${total})`);
  L.push(`local ${P}_first = array(${convs.length})`);
  L.push(`local ${P}_last = array(${convs.length})`);
  L.push(`local ${P}_loopto = array(${convs.length})`);
  L.push(`local ${P}_pos = 0`);
  L.push(`local ${P}_wait = 0`);
  L.push(`local ${P}_endev = 0`);
  L.push(`local ${P}_loopev = 0`);
  L.push(`local ${P}_chan = ${channel}`);
  L.push(``);
  L.push(`function ${P}_init()`);
  let k = 1;
  for (const c of convs) {
    L.push(`  -- sfx ${c.id}`);
    for (const e of c.events) {
      L.push(`  ${P}_ev_note[${k}] = ${e.note} ${P}_ev_vol[${k}] = ${e.vol} ${P}_ev_dur[${k}] = ${e.dur}`);
      k++;
    }
  }
  convs.forEach((c, i) => {
    L.push(`  ${P}_first[${i + 1}] = ${c.first} ${P}_last[${i + 1}] = ${c.last} ${P}_loopto[${i + 1}] = ${c.loopAbs}`);
  });
  L.push(`end`);
  L.push(``);
  L.push(`function ${P}_play(id)`);
  L.push(`  if id >= 1 and id <= ${convs.length} then`);
  L.push(`    ${P}_pos = ${P}_first[id]`);
  L.push(`    ${P}_endev = ${P}_last[id]`);
  L.push(`    ${P}_loopev = ${P}_loopto[id]`);
  L.push(`    ${P}_wait = 0`);
  L.push(`  end`);
  L.push(`end`);
  L.push(``);
  L.push(`function ${P}_stop()`);
  L.push(`  ${P}_pos = 0`);
  L.push(`  ${P}_wait = 0`);
  L.push(`  gt.noteoff(${P}_chan)`);
  L.push(`end`);
  L.push(``);
  L.push(`function ${P}_tick()`);
  L.push(`  if ${P}_pos > 0 then`);
  L.push(`    if ${P}_wait == 0 then`);
  L.push(`      local v = ${P}_ev_vol[${P}_pos]`);
  L.push(`      if v > 0 then`);
  L.push(`        gt.note(${P}_chan, ${P}_ev_note[${P}_pos], v)`);
  L.push(`      else`);
  L.push(`        gt.noteoff(${P}_chan)`);
  L.push(`      end`);
  L.push(`      ${P}_wait = ${P}_ev_dur[${P}_pos]`);
  L.push(`    end`);
  L.push(`    ${P}_wait -= 1`);
  L.push(`    if ${P}_wait == 0 then`);
  L.push(`      if ${P}_pos >= ${P}_endev then`);
  L.push(`        if ${P}_loopev > 0 then`);
  L.push(`          ${P}_pos = ${P}_loopev`);
  L.push(`        else`);
  L.push(`          ${P}_pos = 0`);
  L.push(`          gt.noteoff(${P}_chan)`);
  L.push(`        end`);
  L.push(`      else`);
  L.push(`        ${P}_pos += 1`);
  L.push(`      end`);
  L.push(`    end`);
  L.push(`  end`);
  L.push(`end`);
  return L.join("\n") + "\n";
}

// ------------------------------------------------------------------ main

function main(argv) {
  const opts = { prefix: "sfx", channel: 3, fps: 30, transpose: 24, out: null, list: false, sfx: null, roundtrip: false };
  let input = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => { if (i + 1 >= argv.length) fail(`${a} needs a value`); return argv[++i]; };
    if (a === "--help" || a === "-h") usage(0);
    else if (a === "--sfx") opts.sfx = next();
    else if (a === "--prefix") opts.prefix = next();
    else if (a === "--channel") opts.channel = Number(next());
    else if (a === "--fps") opts.fps = Number(next());
    else if (a === "--transpose") opts.transpose = Number(next());
    else if (a === "--out") opts.out = next();
    else if (a === "--list") opts.list = true;
    else if (a === "--roundtrip") opts.roundtrip = true; // self-check: text -> bin -> text
    else if (a.startsWith("-")) fail(`unknown option ${a} (--help for usage)`);
    else if (!input) input = a;
    else fail(`unexpected argument ${a}`);
  }
  if (!input) usage(1);
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(opts.prefix)) fail(`--prefix must be a valid identifier`);
  if (!(opts.channel >= 0 && opts.channel <= 3)) fail(`--channel must be 0-3`);
  if (opts.fps !== 30 && opts.fps !== 60) fail(`--fps must be 30 or 60`);

  const records = loadCart(input);

  if (opts.roundtrip) { // encode every parsed sfx to binary, re-parse, diff
    const blob = Buffer.alloc(SFX_BIN_OFFSET + SFX_COUNT * SFX_BIN_SIZE);
    records.forEach((s, i) => encodeBin(s).copy(blob, SFX_BIN_OFFSET + i * SFX_BIN_SIZE));
    const again = parseBin(blob); // always 64 records; the cart may hold fewer
    const a = JSON.stringify(records), b = JSON.stringify(again.slice(0, records.length));
    const restEmpty = again.slice(records.length).every(
      (s) => s.mode === 0 && s.speed === 0 && s.loopStart === 0 && s.loopEnd === 0 &&
             s.notes.every((n) => n.pitch === 0 && n.wave === 0 && n.vol === 0 && n.fx === 0));
    const ok = a === b && restEmpty;
    console.log(ok ? `roundtrip OK: ${records.length} sfx text->bin->text identical` : "roundtrip MISMATCH");
    process.exit(ok ? 0 : 1);
  }

  if (opts.list) {
    console.log("sfx  speed loop   rows waves        fx           audible-rows");
    records.forEach((s, i) => {
      const c = convertSfx(s, opts);
      if (c.notesUsed.length === 0) return;
      const waves = [...new Set(c.notesUsed.map((n) => n.wave))]
        .map((w) => (w >= 8 ? `c${w - 8}` : WAVE_NAMES[w])).join(",");
      const fxs = [...new Set(c.notesUsed.map((n) => n.fx).filter((f) => f > 0))].map((f) => FX_NAMES[f]).join(",") || "-";
      const loop = c.loops ? `${s.loopStart}-${s.loopEnd}` : "-";
      console.log(`${String(i).padStart(2)}   ${String(Math.max(1, s.speed)).padStart(3)}  ${loop.padEnd(6)} ${String(c.rows).padStart(3)} ${waves.padEnd(12)} ${fxs.padEnd(12)} ${c.notesUsed.length}`);
    });
    return;
  }

  if (!opts.sfx) fail("--sfx <list> is required (or --list to see what's in the cart)");
  const picks = opts.sfx.split(",").map((s) => {
    const n = Number(s.trim());
    if (!Number.isInteger(n) || n < 0 || n >= SFX_COUNT) fail(`bad sfx number '${s}' (0-63)`);
    return n;
  });

  const block = emit(input.split("/").pop(), records, picks, opts);
  if (opts.out) {
    writeFileSync(opts.out, block);
    console.error(`p8sfx: wrote ${opts.out} (${block.split("\n").length} lines)`);
  } else {
    process.stdout.write(block);
  }
}

main(process.argv.slice(2));
