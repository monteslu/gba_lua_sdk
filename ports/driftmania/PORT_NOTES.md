# Driftmania — GameTank port notes

Hand-translation of **"Driftmania"** by **maxbize** (Frenchie14) — PICO-8,
<https://github.com/maxbize/PICO-8> — to the GameTank via the `gtlua` SDK.
Original and this port are both CC-BY-NC-SA 4.0 (see `LICENSE`).

Reference used: `carts/driftmania.p8` (the original cart: its `__lua__`
source, `__gfx__` sheet, `__map__` and `__gff__` sections). The track data
was extracted from the cart's own RLE chunk streams; see
`tools/data_a1.js` (the raw cart tables) and `tools/gen.js` (the converter).

This is a **playable single-track slice**: track **A1** (the cart ships
several tracks; A1 is the first/default). Real drift physics, the real A1
track geometry, the real car with 32 pre-rotated headings, checkpoints and
3-lap timing with the cart's medal thresholds.

---

## How to build

```
node ports/driftmania/tools/gen.js     # (re)generate gfx.bin + GENDATA in main.lua
node ports/driftmania/build.mjs        # -> ports/driftmania/main.gtr (2 MB FLASH2M)
```

`main.gtr` is copied to `roms/driftmania.gtr` and
`~/roms/gametank/driftmania.gtr`.

### Why a banked (2 MB) cart, not a flat 32 KB one

The flat `node bin/gtlua.js build … --sheet …` **does not fit**: it
overflows the 32 KB window by ~12.6 KB. The port is genuinely big — ~1800
lines of Lua (of which ~1050 are generated track/car data init and ~750 are
the hand-written game) plus the 8 KB sprite sheet, so code + data + sheet
≈ 45 KB. The FLASH2M banked target is the only correct one.

`bin/gtlua.js`'s **auto-retarget** to FLASH2M then fails with
`FLASH2M bank placement failed: RODATA over by 3192` (the same audio-firmware
problem combo-pool hit). `build.mjs` uses a hand-tuned `PLACEMENT` map plus
two build-time source transforms (P1/P2 below) and links cleanly. **So the
fix for the "RODATA over by 3192" blocker is: build with `build.mjs`, not
the CLI auto-retarget.**

Post-link segment occupancy (all under 0x4000 per bank):

| bank | contents | end / size |
|------|----------|-----------|
| BANK0 | B0CODE (update / physics / gd_3–gd_5 data-init) | size 0x3313 |
| BANK1 | B1CODE + B1RODATA (all drawing + HUD + gd_1/gd_2/gd_4/gd_5 init + print literals) | size 0x347D |
| BANK2 | SHEET (8 KB sheet + 4 KB ACP firmware = 0x3000) + B2CODE (`_init`) | size 0x3006 |
| FIXED ($C000) | CODE + RODATA + VECTORS (runtime, shared unpackers, stubs) | ends 0xFFFF |
| RAM ($0200) | DATA 0xA7 + BSS 0x187E | ends 0x1B24 (of 0x1F00) |

RAM is the binding constraint on the GameTank (only ~7.4 KB, and the stack
lives at the top of it). See "RAM budget" below.

---

## SDK gap report (prioritized)

`build.mjs` and `tools/gen.js`'s packing exist ONLY because of these gaps.
Gaps 1–3 are shared with combo-pool; gap 0 is the one that shaped this port
the most.

**P0 — no read-only / flash-resident array. THE dominant constraint.**
`gtlua`'s `array(N)` and `pool(N)` are always in RAM (C `int[]` in BSS, or a
DATA array that still *runs* in RAM). Driftmania's lookup tables — the 30×30
chunk grid, per-angle collision-outline probes (32×8), wheel offsets (32×4),
tile-definition and collision-mask tables — are **written once at init and
only read during play**, i.e. they are pure ROM data. But with no way to
declare a `const` array that lives in a flash bank, all of them consume the
scarce ~7.4 KB RAM. The *un-packed* layout needed 7.26 KB of arrays alone,
which does not fit alongside the stack + scalars — the build failed with
`BSS over by 653`. There is **no `peek`/`poke`/`mget`-style byte reader** in
the dialect either, so a port cannot even hand-roll a flash table and index
it. Workaround (see `tools/gen.js`): pack two small values per 16-bit int
everywhere the hot path can cheaply unpack them — draw-kind|uniform-tile,
two tile-ids per int, `(x+8)|(y+8)<<8` wheel offsets, `(dx+16)|(dy+16)<<8`
bbox probes. This halved the array RAM to ~5.0 KB and made the port fit
(0x187E BSS, ~1 KB headroom). *Fix (highest value for this SDK):* a
`const`/`rodata` array qualifier that places a read-only `array(N)` into a
switchable flash bank, plus a `peek8(bank, addr)` (or an indexed accessor)
so games can keep large read-only tables out of RAM entirely. This would
delete all of the packing in `gen.js` and roughly **double** the data budget
a GameTank gtlua game can carry.

**P1 — banked builds can't place audio's ACP firmware.**
`sdk/gt_audio.c` `#include`s a ~4 KB ACP firmware blob (`gt_acp_fw.h`) into
RODATA. In a banked build cc65 lands that blob in the **fixed** bank, which
overflows it (`RODATA over by 3192` here). `build.mjs` text-transforms a copy
of `gt_audio.c` to wrap the include in `#pragma rodata-name(push,"SHEET") …
(pop)` so the blob rides in bank 2 next to the sheet, and calls
`gt_sheet_init()` (which selects bank 2) immediately before
`gt_audio_init()` so the firmware is mapped in when the one-time upload runs.
*Fix:* let the banked linker plan give the firmware a home in a switchable
bank, or expose an SDK `#pragma` hook so a game need not rewrite
`gt_audio.c`.

**P2 — cc65 string-literal pool ignores the active `#pragma rodata-name`.**
cc65 defers the string-literal pool to the *end* of the translation unit,
after `emit.js`'s `#pragma rodata-name` scopes have popped, so every
`print("…")` literal lands in the fixed bank's RODATA. `build.mjs` appends
`#pragma rodata-name("B1RODATA")` to the generated `main.c` so the tail pool
is parked in bank 1 (all of this game's literals are the HUD strings, which
live in bank-1 draw functions). *Fix:* have the compiler emit an explicit
end-of-unit `rodata-name`, or route string literals into a placement-aware
segment. Fragile: a game whose literals span multiple banks can't be fixed
by a single tail pragma.

**P3 — no first-class banked build for a sheet + audio game.**
`bin/gtlua.js`'s automatic function/data placement isn't good enough for a
real banked game (see the auto-retarget failure above); a hand-written
`PLACEMENT` map is required. *Fix:* call-graph-aware, RODATA-balancing
default placement so `node bin/gtlua.js build … --sheet …` "just works".

**P4 — no per-frame division / trig budget documented.** `sin/cos/atan2/
sqrt/` `/` are software routines; the physics uses `cos`, `sin`, `sqrt`,
`atan2` and a few divides **per frame** (not per entity), which is
affordable, but a porter has to discover the cost. A "trig and divide are
~Nk cycles, budget accordingly" note in the SDK docs would help. (This port
stays within budget because there is exactly one car; a multi-car AI field
would need a CORDIC/table approach.)

**P5 — cosmetic: the flat-build error only says "re-targeting … failed",**
not "your RAM/BSS is over budget, shrink your data". The `BSS over by N`
line does appear, but the first-time porter reads "FLASH2M bank placement
failed" and assumes it's a code-size/bank problem, not a RAM problem. A
clearer "this is a RAM (not flash) overflow" message would save time.

---

## Map-and-car built-in data spec (what `tools/gen.js` emits)

The section of `main.lua` between the `GENERATED DATA` markers is produced
by `tools/gen.js` and must not be hand-edited. Its shape:

**Chunk grid.** The A1 track is 30×30 *chunks* of 3×3 tiles (90×90 tiles,
720×720 px) — bigger than one 128×128 screen. Each of the three PICO-8 map
layers (road, decals, props) is dictionary-compressed to layer-local dense
chunk ids (≤31 each), and the three ids are packed into one grid word:

```
cgrid[cy*30 + cx + 1] = road | decal<<5 | prop<<10
```

A layer id of 0 means "empty in that layer". Each dense id resolves through
two shared, packed tables:

* `ckdt[id]` = **draw-kind** (low byte) `|` **uniform-tile** (high byte).
  Draw-kind: `0` = skip, `1..15` = a solid 24×24 color fill, `16+k` =
  tile-definition `k` (a full 3×3 tile chunk). Decal ids add base `decb`,
  prop ids add base `propb`.
* `ctiles` = the flattened 3×3 tile-definitions, two tile ids per int
  (`ctiles[(i>>1)+1]` low/high byte for flat index `i`).

**Collision.** `tmi[t+1]` maps a tile id to a mask index; `tcls[mi]` is the
class (1 = grass, 2 = wall); `tmask` is 8 row-bytes per mask (bit `x` set =
that pixel collides). A1 has no water/boost/jump tiles (verified by
`gen.js`), so the port drops those systems. `wallbit` is a coarse
"this 8×8 tile has wall ink" bit-grid (90×90 bits, 16 per int, 6 ints/row)
used as the cheap first-level wall test before the per-pixel mask.

**Car.** The cart rotates the car at runtime with `tline`; the GameTank
blitter can't rotate, so `gen.js` **pre-renders the car at all 32 headings**
offline (the cart's five stacked "3D" slices, rotated + composed into 16×16
frames with anchor (8,10), garage palette baked in) into sheet cells
128–255. The runtime picks the cell for heading `ai` (0..31) with
`128 + (ai>>3)*32 + (ai&7)*2`. Per-heading collision probes (`bpk`, 8 points
× 32 angles, `(dx+16)|(dy+16)<<8`) and wheel offsets (`wpk`, 4 wheels × 32
angles, `(x+8)|(y+8)<<8`) are likewise baked from the cart's outline sprite
and hand-tuned wheel table.

`div3[]` (tile-coord ÷3) is precomputed to avoid runtime divides in the map
lookups; mod-3 is `tc - div3[tc+1]*3`.

---

## Gameplay divergences from the original cart

1. **Single track (A1) only.** The cart ships multiple tracks + a menu; this
   port is the A1 slice. The map built-in and physics are the real cart's;
   adding tracks is a data-only change (more `cgrid`/tile tables) but each
   track's ~5 KB of packed data does not co-reside in RAM, so multiple
   tracks would need P0's flash-resident arrays (or a bank-swap-in loader) —
   deferred rather than shipped as a slideshow. **A playable single track at
   an honest 30 fps was chosen over three tracks at a slideshow.**

2. **30 fps, constants rescaled.** The cart runs `_update60` (60 fps); this
   port runs `_update()` (30 fps). Per-frame velocity deltas are ×4 (two
   60fps sub-steps at doubled px/frame units), velocities/turn-rates ×2, and
   the cart's `0.94` over-limit decay becomes `0.94² = 0.88`. Movement is
   still **pixel-stepped** (move 1 px at a time, testing walls each step) so
   fast cars can't tunnel through fences even at the doubled step size.

3. **Car rotation is pre-rendered, not runtime `tline`** (see the built-in
   spec + P0). 32 headings, the exact snap the cart uses (`round_nth`).

4. **Out-of-bounds system dropped.** A1 is fully enclosed by fences (verified
   by a flood-fill from spawn in `gen.js`), so the cart's world-border OOB
   handling isn't needed.

5. **Audio is a gt.note approximation.** GameTank `gt.note(ch,note,[vol])` /
   `gt.noteoff(ch)` (4 channels) stands in for the cart's PICO-8 sfx: a
   pitch-follows-speed engine drone (ch 0), a two-note skid blip while
   drifting (ch 1), a low grass rumble (ch 2), and countdown / checkpoint /
   lap / crash blips (ch 3). Events match the cart; the timbre does not.
   `scripts/p8sfx.mjs` (the real `__sfx__` converter) exists and a future
   pass could swap these for converted note arrays.

6. **Trails are a fixed 64-mark ring buffer of world-space `pset`s** (the
   GameTank double-buffers + clears each frame, so there's no persistent
   framebuffer smear to leave). Drift lays black rear-wheel marks; a front
   wheel on grass kicks a brown dirt mark. Oldest marks recycle.

7. **Only the visible chunk window is drawn.** `_draw` computes the ~6×6
   chunk window covering the 128×128 camera view and draws only non-empty
   layers of those chunks (empties are skipped at the `cgrid[...] != 0`
   gate), then the car, then props above the car, then the HUD. This is what
   keeps a 720×720 map affordable per frame.

---

## Controls (GameTank)

| GameTank button | raw libretro | action |
|-----------------|--------------|--------|
| D-pad Up | up | throttle (same as A) |
| D-pad Down | down | brake / reverse |
| D-pad Left/Right | left/right | steer |
| A | `b` | throttle |
| B | `y` | drift handbrake |
| START | start | restart race |

On the results screen, **A** restarts the race.

Drift by tapping the handbrake (B) mid-corner: the car keeps its momentum
while the nose swings, and the velocity vector slowly rotates back toward the
facing — the classic Driftmania feel. Grass under ≥2 wheels cuts your grip,
steering, and top speed; hitting a fence bounces you and stuns the throttle.

---

## FPS / pacing

`_update()` (no `_update60`) → the compiler enables `gt_p8_fps30()`, so the
game runs the PICO-8 30 fps contract with the rescaled constants above.
Target pacing is **2.0 vsyncs per game frame** (an honest 30 fps on a 60 Hz
field). Measure at runtime from `_gt_ticks` (0x2AA) and `_gt_time_acc`
(0x204): `vsyncs_per_frame = ticks / ((time_acc/1092)/2)`.

Measured pacing: see the "Verified" section — filled in from a live emulator
run reading those two RAM addresses.
