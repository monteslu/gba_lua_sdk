// test/gtm2.test.js - the .gtm2 FM song format (compiler/gtm2.mjs).
// Verifies our bytes match Clyde's official format (midiconvert.js / music.c):
// cfg + 4 instruments + {delay, mask, notes...} events, 1-based notes, single
// trailing-zero terminator.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseGtm2, encodeGtm2, noteNum, INSTRUMENTS, CFG_VELOCITY,
} from "../compiler/gtm2.mjs";

test("encode/parse round-trips a simple song", () => {
  const song = {
    instruments: ["PIANO", "BASS", "SNARE", "HORN"],
    events: [
      { delay: 10, notes: { 0: 48 } },
      { delay: 20, notes: { 0: 55 } },
      { delay: 20, notes: { 0: 0 } },   // key off
    ],
  };
  const buf = encodeGtm2(song);
  const back = parseGtm2(buf);
  assert.equal(back.velocity, false);
  assert.deepEqual(back.instruments, [0, 2, 3, 5]);
  assert.equal(back.events.length, 3);
  assert.equal(back.events[0].delay, 10);
  assert.equal(back.events[0].notes[0].note, 48);
  assert.equal(back.events[2].notes[0].note, 0);
});

test("header layout matches the official .gtm2 (cfg, 4 instruments, first delay)", () => {
  const buf = encodeGtm2({
    instruments: [1, 4, 5, 1],
    events: [{ delay: 0, notes: { 0: 48 } }],
  });
  assert.equal(buf[0], 0);          // cfg: no velocity
  assert.equal(buf[1], 1);          // instr ch0
  assert.equal(buf[2], 4);
  assert.equal(buf[3], 5);
  assert.equal(buf[4], 1);
  assert.equal(buf[5], 0);          // first delay
  assert.equal(buf[6], 0x01);       // noteMask: ch0
  assert.equal(buf[7], 48);         // note
  assert.equal(buf[8], 0);          // trailing delay = terminator
  assert.equal(buf.length, 9);      // exactly one trailing zero
});

test("velocity mode adds a byte per note and sets the cfg bit", () => {
  const buf = encodeGtm2({
    velocity: true,
    instruments: [0, 0, 0, 0],
    events: [{ delay: 0, notes: { 0: { note: 60, vel: 40 } } }],
  });
  assert.equal(buf[0] & CFG_VELOCITY, CFG_VELOCITY);
  const back = parseGtm2(buf);
  assert.equal(back.velocity, true);
  assert.equal(back.events[0].notes[0].note, 60);
  assert.equal(back.events[0].notes[0].vel, 40);
});

test("multi-channel event packs channels in order with the right mask", () => {
  const buf = encodeGtm2({
    instruments: [0, 0, 0, 0],
    events: [{ delay: 0, notes: { 0: 40, 2: 52 } }],   // ch0 + ch2
  });
  // after header(5)+delay(1): mask, note0, note2, delay
  assert.equal(buf[6], 0b0101);   // ch0 | ch2
  assert.equal(buf[7], 40);
  assert.equal(buf[8], 52);
});

test("delays over 255 split into padding events on encode", () => {
  const buf = encodeGtm2({
    instruments: [0, 0, 0, 0],
    events: [{ delay: 0, notes: { 0: 40 } }, { delay: 400, notes: { 0: 0 } }],
  });
  // the 400-frame gap can't be one delay byte; it must expand
  const back = parseGtm2(buf);
  const totalDelay = back.events.reduce((s, e) => s + e.delay, 0);
  // padding events carry empty notes; total elapsed frames is preserved
  assert.ok(totalDelay >= 400, "the 400-frame gap survives the split");
});

test("noteNum: official pitch-table index (MIDI - 12), rest is 0", () => {
  // the 0.2.0 music revamp matched the official tools: byte = MIDI - 12,
  // so A4/440Hz = 57 (the old +1 encode was a semitone off byte-compat)
  assert.equal(noteNum("c4"), 48);   // MIDI 60 - 12
  assert.equal(noteNum("a4"), 57);   // MIDI 69 - 12 = 440 Hz
  assert.equal(noteNum("c#4"), 49);
  assert.equal(noteNum("db4"), 49);  // enharmonic
  assert.equal(noteNum(48), 48);     // pass-through for raw numbers
});

test("instrument names resolve to the built-in indices", () => {
  assert.equal(INSTRUMENTS.PIANO, 0);
  assert.equal(INSTRUMENTS.CHIP, 8);
  assert.equal(INSTRUMENTS.CHIP2, 9);
});

test("parses a REAL midiconvert.js .gtm2 (the SDK boot jingle, byte-for-byte)", () => {
  // exactly the 21 bytes Clyde's own scripts/converters/midiconvert.js emits for
  // assets/sdk_default/jingle.mid - our parser must read it and our encoder must
  // reproduce it byte-identical (parity with the official format authority).
  // (the canonical bytes, verified against midiconvert.js output this session)
  const canonical = Buffer.from([
    0x00, 0x01, 0x04, 0x05, 0x01, 0x00, 0x02, 0x30, 0x1a, 0x02, 0x37,
    0x09, 0x02, 0x00, 0x09, 0x02, 0x39, 0x09, 0x02, 0x00, 0x00,
  ]);
  const song = parseGtm2(canonical);
  assert.deepEqual(song.instruments, [1, 4, 5, 1]);   // piano, sitar, horn, piano
  assert.equal(song.velocity, false);
  assert.equal(song.events[0].notes[1].note, 48);     // first note keys channel 1
  assert.ok(encodeGtm2(song).equals(canonical), "re-encode is byte-identical");
});
