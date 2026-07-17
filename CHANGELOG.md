# Changelog

## 0.3.0

### Audio

The chiptune / module-music path had a choppy, clicking, popping character.
Root cause was two-fold and both are fixed:

- **maxmod mixer starvation on frame overrun.** `mmFrame` was pumped from the
  main-loop position, so when a heavy render (e.g. Mode 4) overran a frame the
  mixer refill was skipped and the DirectSound FIFO drained — an audible
  dropout. `mmFrame` now runs off the VCOUNT IRQ, a true 60 Hz clock that
  survives frame overruns. Mix rate raised to 31 kHz.

- **Over-processed instruments.** The GBA maxmod mixer is non-interpolated
  (nearest-neighbor resampling), so the band-limiting, DC-balancing,
  attack/release envelopes, and fadeouts layered onto the default instruments
  made the output worse, not smoother. Decoding maxmod's own reference chiptune
  showed the clean baseline is raw square waves at period 64, no volume
  envelope, no fadeout, constant volume — kept clean by a bright, sustained,
  sparse arrangement. Both instrument banks (the default `assets/` tune and the
  web tracker's `compiler/xm-write.mjs` bank) now follow that design.

Pulse samples are still DC-balanced by area in `xm-write.mjs` (a naive ±amp
pulse carries a large subsonic DC offset); that stays.

## 0.2.0

Package renamed to `gbalua`; CLI is `bin/gbalua.js`. Browser-safe asset +
music pipeline (pure-JS inflate/PNG, `.xm`/`.mod`/`.it`/`.s3m` module music via
`romdev-maxmod`). Aseprite/Tiled/tracker imports.
