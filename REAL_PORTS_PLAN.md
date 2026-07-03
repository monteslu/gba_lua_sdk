# Real ports — SDK feature build-out (driven by the actual cart source)

**Directive (2026-07-02):** ports mean the REAL games — actual Lua source
hand-ported, actual art — never mechanic sketches. Cherry Bomb, Combo Pool,
and UFO Swamp are CC4-BY-NC-SA: adapting their code and art with attribution
is what the license permits. Each port dir carries the CC license + credits.
The real cart source is the SDK's acceptance test: when the hand-port of
cherrybomb.p8 compiles and plays, the features below are done by definition.

## Pipeline status

- [x] `scripts/p8extract.mjs` — .p8.png → cart.bin + gfx.bin (the real
  128×128 sheet, 4bpp) + gfx.pgm preview + code.bin. Verified on Cherry
  Bomb (`\0pxa` magic in code.bin).
- [ ] pxa decompressor in p8extract (PICO-8 0.2 compression: move-to-front
  literals + back-references; documented in pico-8 wiki / picotool source)
  → emits the real .p8 Lua text.
- [ ] `gtlua build --sheet gfx.bin` — build-time sheet import: convert 4bpp
  P8 pixels through the palette map into a GRAM-load C array + runtime
  `gt_sheet_load()` at boot (replaces per-pixel sset authoring; sset stays
  for procedural art).
- [x] ACP audio driver produces sound — `gt.note`/`gt.noteoff` play real
  tones (verified: recorded WAV, rms > 4000, arpeggio pitch steps confirmed
  by FFT). Root cause of the old silence: the boot handshake polled the
  BYTE at $3002 (WavePTR low, always $00 — the sine table is page-aligned)
  so `gt_audio_init` spun forever; upstream reads the 16-bit word. Fixed by
  polling $3003 (bounded), plus clean carrier-only amplitude handling
  (modulator ops at 128 = pure sine; op 4 is the carrier).

## Language features the real source needs (in port order)

1. **Structs + object pools (v0.3 core)** — `add(pool, {x=…,y=…})`,
   `for e in all(pool)`, `del`, `foreach`, dot-field access on pool
   elements. Compile: struct layout from the literal, capacity-bounded
   pools (annotation or `--[[cap N]]`), `all()` iteration with
   delete-current support. THE dominant idiom in every real cart.
2. **Strings + print (v0.5, pulled earlier)** — string literals in ROM,
   `print(s,x,y,c)` with the 4×6 font, number-to-string for scores.
3. **sfx/music (v0.4)** — ACP firmware upload at boot + a note-event
   scheduler; converter from `__sfx__`/`__music__` data to GameTank
   note tables (the P8 tracker model maps onto 4 channels 1:1).
4. **spr flip args + palt** — flip_x/flip_y via the blitter's bit-7 W/H
   flags (hardware); palt(0,false) for opaque blits.
5. **map/mget/fget** — only needed for UFO Swamp (Cherry Bomb is mapless).
6. Multiple returns, `%` string-format-free scorekeeping helpers as needed
   by the actual source — port drives the list, nothing speculative.

## Port order

1. **Cherry Bomb** (source extracted; hand-port after features 1-3).
2. **Combo Pool** (CC; small; needs 1 + circles already done).
3. **UFO Swamp Odyssey** (CC; needs map).
4. Celeste Classic / Jelpi — ask the authors first (no license tags).

The five sketch games in ports/ get renamed to examples/ status or replaced
outright by the real ports as they land — nothing labeled "port" until it is
the real game.

## sfx converter (landed 2026-07-02)

- [x] `scripts/p8sfx.mjs` — PICO-8 `__sfx__` → paste-able gtlua block
  (note-event arrays + a one-channel `sfx_play/sfx_tick` player on
  channel 3). Reads text `.p8` AND `.p8.png` extracts (`cart.bin`,
  0x3200 region; layouts round-trip verified). Pitch: gt = p8 + 24
  (`gt.note` sounds MIDI+12 on this stack — FFT-verified; see
  docs/sfx.md for the octave analysis, effect approximations, and the
  gametank-libretro `irqCounter` starvation bug found on the way).
  Verified end-to-end: newleste 9/18/20 + a cherrybomb jingle play the
  right contour on the emulator (Goertzel beats 20/20 shuffled controls).
  Feature 3's remaining half is `__music__` (patterns → the 4 channels).
