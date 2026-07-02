# Provenance

## sdk/ hardware files

Adapted from [clydeshaffer/gametank_sdk](https://github.com/clydeshaffer/gametank_sdk)
(MIT), commit `9d86e7e` (2026), by way of the single-bank presets in the
romdev project (also MIT-adapted from the same upstream):

- `sdk/gametank.h` — the register/flag map from `src/gt/gametank.h`
  (stale `extern`s for the upstream mirror variables removed; this runtime
  keeps its own mirrors in `gt_api.c`)
- `sdk/crt0.s` — from `src/gt/crt0.s`, stripped for flat 32 KB carts:
  no flash-bank shift-out at boot, no `_sdk_init`, no audio-firmware incbin;
  default interrupt handlers removed (they live in `sdk/interrupt.s`)
- `sdk/vectors.s` — from `src/gt/vectors.s`
- `sdk/gametank.cfg` — the SDK's generated multi-bank layout collapsed to
  one 32 KB ROM bank at `$8000–$FFFF` (a flat 32 KB image is a valid
  EEPROM32K `.gtr`); ZP/stack/RAM ranges match the SDK
- `sdk/interrupt.s` — modeled on `src/gt/interrupt.s` (the non-draw-queue
  variant): IRQ acks the blitter and clears `gt_draw_busy`; NMI releases the
  vsync spin and counts ticks
- `sdk/gt_api.c` — new code, but every register sequence follows
  `src/gt/gfx/gfx_sys.c`, `src/gt/gfx/draw_direct.c`, and `src/gt/input.c`
  verbatim (init values, flip protocol, box-mode flag dance, the
  two-reads-per-pad active-low input protocol)

Register/timing semantics were additionally verified against the blitter and
bus implementations in
[clydeshaffer/GameTankEmulator](https://github.com/clydeshaffer/GameTankEmulator)
(via the gametank-libretro port): W/H counters are 7-bit (bit 7 = flip), the
COLOR register is inverted by the blitter, CPU writes reach VRAM only with
`DMA_CPU_TO_VRAM` set and `DMA_ENABLE` clear, and blitter registers are
write-only (completion is the IRQ, never a poll).

## Toolchain

`scripts/install_tools.sh` builds [cc65](https://github.com/cc65/cc65)
(zlib license) into `tools/cc65/` (gitignored). Developed against cc65
V2.19 git `cc3c40c`. The build flags mirror the C SDK's makefile:
`-t none -Osr --cpu 65c02 --codesize 500 --static-locals`.

## Design references

- [fetchingcat/gametank_basic_sdk](https://github.com/fetchingcat/gametank_basic_sdk)
  — the shape of this SDK (compiler + hardware runtime + examples) and the
  proof that a high-level language SDK works on this console
- PICO-8 — the ergonomics target (compound assignment, the planned 16.16
  fixed-point number model)
