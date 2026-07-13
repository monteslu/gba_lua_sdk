// compiler/gtm2.mjs - GameTank .gtm2 song format (FM music).
//
// gt-lua uses the OFFICIAL GameTank .gtm2 song format byte-for-byte (the one
// ~/code/cliemu/gametank_sdk/scripts/converters/midiconvert.js writes and
// src/gt/audio/music.c plays). A .gtm2 is a linear, 4-channel FM event stream:
//
//   byte 0     : config flags        (bit0 = per-note velocity byte present)
//   bytes 1-4  : instrument index per channel 0..3 (see the instrument list)
//   byte 5     : the first delay (frames until the first event)
//   then events: repeated
//       u8 noteMask                  (bit c set => channel c changes this event)
//       per set bit c: u8 note [, u8 velocity if cfg.velocity]   (note 0 = off)
//       u8 delay                     (frames until the NEXT event)
//   long gaps (>255 frames) are padding events {u8 time<=128, u8 mask=0}.
//   trailing 0 byte = terminator.
//
// note values are the console's raw PITCH-TABLE indices, keyed unshifted - the
// exact bytes Clyde's midiconvert.js writes and music.c plays (0 = key-off).
// The table is tuned so index = MIDI - 12: A4 (440 Hz) = 57. noteNum() below
// does that conversion, so callers can keep thinking in note names / MIDI.
//
// This module parses/encodes that format and offers a hand-authoring helper so
// you can write a song from a simple event list without needing a MIDI file.
// No external dependencies. See docs/MUSIC.md.

export const CFG_VELOCITY = 0x01;

// built-in FM instrument indices (match sdk/gt_music.h GT_INSTR_*)
export const INSTRUMENTS = {
  PIANO: 0, GUITAR: 1, BASS: 2, SNARE: 3, SITAR: 4,
  HORN: 5, BELL: 6, BELL2: 6, BLIP: 7, CHIP: 8, CHIP2: 9,
};
export const NUM_INSTR = 10;

function instrIndex(x) {
  if (typeof x === "number") return x & 0xff;
  const i = INSTRUMENTS[String(x).toUpperCase()];
  if (i === undefined) throw new Error(`unknown instrument "${x}" (see INSTRUMENTS)`);
  return i;
}

// ---------------------------------------------------------------------------
// parse a .gtm2 blob into a structured song
// ---------------------------------------------------------------------------
// Returns { velocity, instruments:[4], events:[{delay, notes:{ch:{note,vel?}}}] }
// where each event's `delay` is the frames BEFORE it fires (the stream's leading
// delay lands on events[0]).
export function parseGtm2(buf) {
  if (buf.length < 6) throw new Error(".gtm2 too short (need cfg + 4 instruments + a delay)");
  const velocity = (buf[0] & CFG_VELOCITY) !== 0;
  const instruments = [buf[1], buf[2], buf[3], buf[4]];
  const events = [];
  let p = 5;
  let delay = buf[p++];
  // walk events until the terminating 0-length tail
  while (p < buf.length) {
    const noteMask = buf[p++];
    if (p > buf.length) break;
    const notes = {};
    for (let ch = 0; ch < 4; ch++) {
      if (noteMask & (1 << ch)) {
        const note = buf[p++];
        const vel = velocity ? buf[p++] : undefined;
        notes[ch] = velocity ? { note, vel } : { note };
      }
    }
    events.push({ delay, notes });
    if (p >= buf.length) break;
    delay = buf[p++];
    // a padding gap is {mask:0}; parseGtm2 keeps them as empty-notes events so
    // encode round-trips, but authors normally use big delays instead.
  }
  return { velocity, instruments, events };
}

// ---------------------------------------------------------------------------
// encode a structured song into a .gtm2 blob
// ---------------------------------------------------------------------------
// song = {
//   velocity?: bool,
//   instruments: [i0, i1, i2, i3]   // names or indices
//   events: [{ delay, notes: { ch: note | {note, vel} } }, ...]
// }
// `delay` on events[0] is the lead-in; each event's delay is frames before it
// fires (matching parseGtm2). Gaps >255 are split into padding events for you.
export function encodeGtm2(song) {
  const velocity = !!song.velocity;
  const instr = song.instruments.map(instrIndex);
  if (instr.length !== 4) throw new Error("a .gtm2 needs exactly 4 channel instruments");
  const out = [velocity ? CFG_VELOCITY : 0, instr[0], instr[1], instr[2], instr[3]];

  const events = song.events || [];
  // emit: leading delay, then for each event [noteMask, notes...], next delay.
  // split any delay > 255 into padding {time<=128, mask 0} events first.
  const pushDelay = (d) => {
    let rem = d | 0;
    while (rem > 255) {
      const t = Math.min(128, rem - 255 > 0 ? 128 : rem);
      out.push(t, 0);          // padding event: time, empty mask (no notes)
      rem -= t;
    }
    out.push(rem & 0xff);
  };

  pushDelay(events.length ? (events[0].delay | 0) : 0);
  events.forEach((ev, i) => {
    let mask = 0;
    const chans = [];
    for (let ch = 0; ch < 4; ch++) {
      const n = ev.notes ? ev.notes[ch] : undefined;
      if (n === undefined || n === null) continue;
      mask |= 1 << ch;
      chans.push(typeof n === "object" ? n : { note: n });
    }
    out.push(mask);
    for (const n of chans) {
      out.push(n.note & 0xff);
      if (velocity) out.push((n.vel ?? 63) & 0xff);
    }
    // delay before the NEXT event; the last event's trailing 0 delay IS the
    // stream terminator (matches midiconvert.js's single trailing zero).
    const next = events[i + 1];
    pushDelay(next ? (next.delay | 0) : 0);
  });
  if (!events.length) out.push(0);   // empty song still needs the terminator
  return Buffer.from(out);
}

// convenience: the .gtm2 note byte for a name like "c4", "a#3", "eb5".
// The byte is the console's pitch-table index = MIDI - 12 (A4/440 = 57), the
// same value Clyde's midiconvert emits and music.c keys unshifted. Clamped to
// 1..107 so it never collides with 0 = key-off.
const SEMI = { c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11 };
export function noteNum(name) {
  if (typeof name === "number") return name;
  const m = /^([a-gA-G])([#b]?)(-?\d+)$/.exec(String(name).trim());
  if (!m) throw new Error(`bad note "${name}" (want like c4, a#3, eb5)`);
  let semi = SEMI[m[1].toLowerCase()] + (m[2] === "#" ? 1 : m[2] === "b" ? -1 : 0);
  const midi = (parseInt(m[3], 10) + 1) * 12 + semi;   // MIDI: c-1 = 0
  const idx = midi - 12;                               // table index (A4 = 57)
  return Math.max(1, Math.min(107, idx));
}
/** Hz for a .gtm2 note byte (0 = rest -> 0). Table tuning: index 57 = 440 Hz. */
export function noteHz(note) {
  if (!note) return 0;
  return 440 * Math.pow(2, (note - 57) / 12);
}
