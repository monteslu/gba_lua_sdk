# p8sfx — PICO-8 `__sfx__` → gtlua converter

`scripts/p8sfx.mjs` turns the sound effects of a real PICO-8 cart into a
paste-able block of gtlua source: flattened note-event arrays plus a tiny
one-channel player. Ports play their game's ACTUAL sfx instead of
hand-approximated `gt.note` calls.

```
node scripts/p8sfx.mjs carts/newleste-base.p8 --list          # what's in the cart
node scripts/p8sfx.mjs carts/newleste-base.p8 --sfx 18,20,22  # jump, dash, land
node scripts/p8sfx.mjs carts/cherrybomb-extract/cart.bin --sfx 7 --prefix jingle
```

Zero-dep node ESM. `--help` prints the full option list.

## Paste-into-game workflow

1. `--list` the cart, pick the sfx numbers the game's Lua actually calls
   (grep the source for `sfx(` / `psfx`).
2. Generate: `node scripts/p8sfx.mjs cart.p8 --sfx 9,18,20 --out block.lua`
   (or pipe stdout). The block is self-contained top-level gtlua.
3. Paste the block at the top of `main.lua` (top-level array decls must sit
   at top level).
4. Wire three calls:
   - `sfx_init()` once from `_init`
   - `sfx_tick()` once per `_update` (every frame, unconditionally)
   - `sfx_play(sfx_18)` wherever the P8 source called `sfx(18)` —
     the converter emits a named `local <prefix>_<n>` id constant per sfx.
   - `sfx_stop()` cuts playback (P8 `sfx(-1)`).

The player owns ONE audio channel (default 3, `--channel` to move it), so
games keep channels 0–2 for music or direct `gt.note` work. One sfx plays
at a time; `sfx_play` while another is playing replaces it (PICO-8 does the
same on a per-channel basis). Looping sfx (a loop range in the cart) loop
forever until `sfx_stop`/`sfx_play`; one-shots end themselves with a
`gt.noteoff`.

Cost: 6 bytes of RAM per event (three int arrays) plus the init-filler code
in ROM. Typical one-shot sfx are 2–30 events; effect-heavy rows expand to
per-frame events (see below). The emitted header comment reports the exact
event count and RAM bytes.

## Source formats (both verified)

- **Text `.p8`** — the `__sfx__` section: one 168-hex-digit line per sfx.
  8 header digits (editor mode, speed, loop start, loop end; one byte
  each), then 32 notes × 5 digits: pitch (2), waveform (1), volume (1),
  effect (1).
- **Binary `cart.bin`** (from `scripts/p8extract.mjs` on a `.p8.png`) —
  64 records × 68 bytes at 0x3200–0x42FF. Each note is a little-endian
  16-bit word: pitch bits 0–5, waveform 6–8, volume 9–11, effect 12–14,
  custom-instrument flag 15 (flag makes waveform 8–15). The 4 header bytes
  sit at the END of the record: editor mode, speed, loop start, loop end.

Verification: `--roundtrip` re-encodes a text cart through the binary
layout and re-parses it — bit-identical for all three text carts in
`carts/` (newleste 63 sfx, minima 64, driftmania 63). The binary path was
additionally sanity-checked against real `.p8.png` extracts (celeste2,
cherry bomb, just-one-boss): waveforms are coherent per sfx, speeds/loops
sane, and a converted cherrybomb jingle plays the right melody (see
Validation).

## Timing model

A PICO-8 row lasts `speed / 128` seconds (128 ticks/s). The gtlua player
ticks once per `_update` (30 fps → 4.267 ticks per frame; `--fps 60` for
`_update60` games). The converter resamples each sfx on the frame grid —
sampling row/effect state at each frame's midpoint — then run-length-merges
identical frames into `(note, vol, duration-in-frames)` events. Properties:

- No drift: total length is `round(rows × speed × fps / 128)` frames, and
  boundaries always land on the honest nearest frame.
- Rows shorter than a frame (speed ≤ 4) are resampled: some in-between rows
  drop out, but contour and total duration survive. newleste's 4-row jump
  at speed 2 (62 ms) becomes 2 frames — audibly still a rising blip.
- One-shots trim trailing silent rows; interior rests are kept as
  volume-0 (noteoff) events.
- A loop range forces an event boundary at the loop start so the player
  can jump back cleanly; per-pass length is re-rounded once per pass.

## Pitch: the octave decision (+24 default)

PICO-8 pitch `p` sounds at `65.406 × 2^(p/12)` Hz — p8 pitch 33 is A4
(440 Hz, MIDI 69), so p8 pitch 0 is MIDI 36 on paper.

The GameTank side: `gt.note(n)` indexes a MIDI-shaped pitch table (from the
upstream gametank_sdk), but the ACP firmware advances the phase accumulator
once per DAC sample at ~13.98 kHz (315000000/88/256/60 × 60), which is
**one octave above** the 6991.3 Hz rate the table's MIDI naming implies.
Measured on the emulator by FFT (sustained-tone ladder, this repo's
converter work, 2026-07-02):

| gt.note | measured   | = MIDI |
|---------|-----------|--------|
| 69      | 877.5 Hz  | 81     |
| 81      | 1754.5 Hz | 93     |
| 40→56 sweep, step 4 | steps measure 3.97–4.01 semitones | linear |

So on this stack `gt.note(n)` sounds at MIDI `n + 12`, and true-pitch
conversion from PICO-8 is **gt = p8 + 24** — the converter default. A
cherrybomb jingle converted at that offset plays at the same absolute pitch
as PICO-8 renders it.

If a future core/firmware revision runs the table at 6991.3 Hz (making
`gt.note(69)` = 440 Hz), regenerate with `--transpose 36`. To re-verify the
octave after any core/firmware change: build a ROM that holds
`gt.note(3, 69, 127)` and FFT the `audioDebug` WAV — 880 Hz means +24,
440 Hz means +36.

### Known core artifact (affects fidelity, not the converter)

The gametank-libretro ACP starves ~43% of the time: `int16_t irqCounter`
(vendor/audio_coprocessor.h) wraps under the shim's
`clksPerHostSample=1024` vs `irqRate=255` (net −769/host-sample), so after
each wrap the DAC freezes for 32 of every ~75 host samples. Audible result:
a 187 Hz chop/buzz on every tone, and tones below `gt.note` ≈ 64 read
~10 semitones flat on a spectrum (the fundamental line is suppressed;
perceived pitch ≈ 0.571× intended). Fix belongs in the core (clamp the
counter instead of letting it wrap, or widen it and re-add bounded
semantics); sfx data converted at +24 is correct as-is and will sound
clean the moment the core is fixed.

## Effects: what's approximated, what's dropped

Effects finer than one frame (4.27 ticks) can't be expressed at a 30 fps
tick, so the converter bakes them into per-frame events (which RLE-merge
back down when nothing changes):

| fx | PICO-8 meaning | converter behavior |
|----|----------------|--------------------|
| 0  | none           | exact (one event per row) |
| 1  | slide          | per-frame pitch+volume steps from the previous row's values (integer-semitone rounding; P8 glides continuously) |
| 2  | vibrato        | **dropped** — plays the plain note (±¼-semitone wobble; the gt pitch table has no detune steps) |
| 3  | drop           | per-frame pitch steps falling linearly to the floor across the row |
| 4  | fade in        | per-frame volume ramp 0 → v |
| 5  | fade out       | per-frame volume ramp v → 0 |
| 6  | arpeggio fast  | per-frame steps cycling the 4-row group (P8 steps every 4 ticks, 2 when speed ≤ 8 — sub-frame, so the cycle is sampled per frame) |
| 7  | arpeggio slow  | same, 8-tick (4 when speed ≤ 8) steps |

Volume: P8 0–7 maps to `gt.note` 0–127 as `round(v × 127/7)`. Note that the
GameTank amplitude control is a phase-offset trick (not linear gain), so
the loudness curve differs somewhat from PICO-8's linear volumes.

Waveforms: the current GameTank voice is a single sine per channel, so all
eight P8 waveforms (triangle, tilted saw, saw, square, pulse, organ, noise,
phaser) render as sine — pitch, rhythm, and dynamics survive; timbre does
not. **Noise (waveform 6)** is the biggest loss: P8 drums/hits become tonal
sine blips (the emitted header flags every sfx that uses noise). Custom SFX
instruments (waveform 8–15) are not expanded; those rows play as a plain
sine at the row pitch (also flagged).

## Player API (generated, `--prefix` renames everything)

```lua
sfx_init()      -- fill the event arrays; call once from _init
sfx_play(id)    -- start a sfx (id = the emitted sfx_<n> constants, 1-based)
sfx_stop()      -- cut playback + noteoff
sfx_tick()      -- advance one frame; call every _update
-- state: sfx_pos (current event index, 0 = idle) is readable for UI/debug
```

## Validation evidence (2026-07-02)

End-to-end on the emulator via the rom-dev MCP (`loadMedia` platform
`gametank` → `frame` → `audioDebug record` → offline Goertzel/FFT):

- newleste sfx 9/18/20 demo (text-cart path): WAV rms 1185–3024 > 0, sound
  onsets exactly at the scheduled `_update` ticks, silence after the
  one-shots end (noteoff verified).
- cherrybomb sfx 7 (binary-cart path, 24 events, 4 s): alignment-scored
  Goertzel over the expected event grid — the +12-octave hypothesis beats
  +0/+24/−12 by 2.5×, and the TRUE note contour beats 20/20
  random-shuffled contours (1.56× the shuffle mean, above the best
  shuffle). The specific melody is what plays, at the expected tempo.
- tone ladder / chromatic sweep: absolute-pitch table above; uniform
  4.00-semitone steps.
