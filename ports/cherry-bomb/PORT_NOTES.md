# Cherry Bomb — GameTank port notes

A hand-translation of "Cherry Bomb" by Krystman / Lazy Devs Academy
(PICO-8, https://www.lexaloffle.com/bbs/?tid=48986) to the gtlua SDK.
Real game logic, real extracted sprite sheet, real bullet-hell shmup.

Move with the d-pad, shoot with GT B (❎), drop a cherry bomb with GT A (🅾️).
Fly in, survive nine waves, kill the boss.

## How to build

```
# convert the extracted 4bpp sheet to a native .gtg once (see docs/GRAPHICS.md)
node bin/gtlua.js gfx import carts/cherrybomb-extract/gfx.bin -o ports/cherry-bomb/gfx.gtg
node bin/gtlua.js build ports/cherry-bomb/main.lua \
     --sheet ports/cherry-bomb/gfx.gtg -o ports/cherry-bomb/main.gtr
```

The source is ~1400 lines and its object code plus the 8 KB sprite sheet
overflow a flat 32 KB EEPROM cart, so the build auto-retargets a 2 MB
FLASH2M banked cart (see below).

### Why a banked (2 MB) cart, not a flat 32 KB one

`main.lua` compiles to more code than fits the GameTank's flat 32 KB
window. The `gtlua build` toolchain detects the 32 KB link overflow and
re-targets the **FLASH2M** 2 MB cartridge: a banked `$8000-$BFFF` 16 KB
window plus a fixed `$C000-$FFFF` bank (127). This port was the first real
consumer of that path, so a fair amount of the banking engine
(`sdk/gametank_flash2m.cfg`, `sdk/gt_bank.s`, and the far-call routing in
`compiler/emit.js` + the bank solver in `bin/gtlua.js`) exists because
Cherry Bomb needed it.

How the solver placed this game's 55 functions:

| bin   | count | what lands here                                             |
|-------|-------|-------------------------------------------------------------|
| fixed | 0     | (only the SDK runtime + far-call stubs; no game functions)  |
| b0    | 32    | the `_update` path: movement, collisions, spawning, AI      |
| b1    | 17    | the `_draw` path + `_init`                                   |
| b2    | 3     | cold spill (wave/boss setup) + the sprite sheet's rodata    |

Placement rules that matter for correctness *and* speed:

* **Any** placement is correct — every cross-bank call is bridged by a
  generated far-call stub in `stubs.s` that lives in the fixed bank,
  saves A/X around two `gt_bank_raw` bank switches, and forwards the
  cc65 fastcall registers blindly (works for any signature).
* A far-call stub is **expensive** (two 7-bit bit-banged bank switches),
  so the hot per-frame paths are kept stub-free: the `_update` call graph
  is pinned to b0 and the `_draw` call graph to b1, so a helper called
  every frame from within one path is same-bank (a plain `jsr`, no stub).
  Only 12 distinct callees are ever reached through a stub, and every one
  of them is on a **cold** edge (wave spawners `prow`/`spawnwave`, the
  event-driven `explode`/`fire`/`firespread`/`bossfire`/`popfloat`), never
  a per-entity inner loop.
* The sprite sheet (8 KB) is parked in b2, keeping b0/b1 free for code.

## Performance

The frame budget is exact and unforgiving. From the core's timing model:

* main CPU = 315000000/88 = **3,579,545 Hz**
* one vsync = clock/60 = **59,659 cycles**
* a blit costs **width × height cycles** (1 cycle/pixel), charged to the
  CPU as spin-wait in `await_drawing()` — blits serialize on the DMA
* `_update()` (no `_update60`) enables `gt_p8_fps30()`, so `gt_endframe`
  burns **2 vsyncs** per game frame. All of update + draw must finish
  inside that window (**119,318 cycles**) or the frame overruns into a 3rd
  vsync and pacing climbs above 2.0.

The single dominant cost turned out to be **cc65 per-call overhead**, not the
drawing itself. A blit's DMA is cheap (an 8×8 sprite is 64 cycles); but each
`spr()`/`circfill()`/`pset()` is a C call with a 5-argument ABI + camera math
+ clip + volatile register writes, measured at ~500–2000 cycles *per call*.
The game issues a lot of primitives per frame — 100 stars, 32 enemy sprites, a
HUD, and up to ~56 particle circfills during a burst — so the call overhead,
not the pixels, is what fills the budget.

Optimizations applied (all behaviour- and pixel-preserving):

* **The 100-star parallax field moved into the SDK** (`gt.starfield_*`). Drawn
  one `pset()` per star from Lua it cost ~1 vsync/frame in call overhead
  alone; the SDK moves and draws the whole field in one tight C loop each,
  with a split-Y byte representation so the draw loop has no per-star shift.
  Measured: the field went from ~1 vsync to fitting *inside* the 2-vsync
  budget (effectively free).
* `cls()` is issued **first** in `_update`, so its 127×127 (~16 K-cycle)
  clear DMA overlaps the frame's update logic instead of stalling the draw.
* Positions/velocities are **1/16-pixel ints**, not 16.16 fixed: the 65C02
  does 16-bit int math far cheaper than 32-bit fixed, and 1/16 px is
  invisible on a 128×128 screen. Trig stays real 16.16 (sin/cos), floored.
* Entity pools carry a compiler-maintained **high-water mark** (see below) so
  a loop over a lightly-used pool scans only the live prefix, not the full
  capacity — a pool empty between explosions costs a near-zero scan.
* `gt_p8_spr`'s off-screen clip drops the per-call `-8*w` runtime multiply.

### Measured pacing

Measured on the libretro core (the shipping timing model) by reading
`_gt_ticks` ($0298) and `_gt_time_acc` ($0204) from work-RAM across a window:
`vsyncs/frame = Δticks / ((Δtime_acc/1092)/2)`. 2.0 = a locked 30 fps.

| scene                                   | vsyncs/frame | fps  |
|-----------------------------------------|--------------|------|
| logo / start screen                     | ~4.0         | ~15  |
| gameplay, wave up, no fire (32 enemies) | ~5.1         | ~12  |
| gameplay, holding fire                  | ~11          | ~5.5 |
| gameplay, fire + moving + explosions    | ~13          | ~4.6 |
| — reference: same scenes, draw stubbed  | 3.2 / 6.9 / 7.9 | (update-only) |

### Why 2.0 is not reachable for this game on this hardware

This is the honest bottom line, and it is arithmetic, not a missing
optimization (a prior pass independently bottomed out at "floor 3.0"):

* Wave 1 is a **4×8 = 32-enemy** Space-Invaders formation — this is the
  *original cart's* design (`placens` in `carts/cherrybomb-extract/source.p8.lua`),
  not a port artifact, and the "no visual/gameplay downgrade" rule keeps it.
* With **draw entirely stubbed**, a 32-enemy wave still measures **~3.2
  vsyncs/frame of pure update** (movement easing/trig + two collision passes
  + animation, once per enemy). That alone is above the 2-vsync budget, so
  **no amount of draw optimization can reach 2.0** while 32 enemies are live.
* PICO-8 runs the same 32 enemies at 30 fps because its `pset`/`spr` are
  near-free VM ops; GameTank's 3.58 MHz 65C02 doing real per-entity 16-bit
  math + cc65-ABI calls cannot match that throughput.

Reaching a locked 2.0 would require reducing the on-screen entity count or
rewriting the per-entity update in hand-batched SDK C (an SDK-owned enemy
system, the way the starfield was batched) — the first is a gameplay change
(disallowed), the second is a large SDK undertaking that still only closes the
*draw* gap, not the ~3.2-vsync update floor. The starfield batching is the
proven, shipped instance of that technique; batching enemy sprites and the
particle burst the same way would pull firing/explosion frames down toward the
update floor (~3–4 vsyncs) but not to 2.0.

| scene                                   | vsyncs/frame |
|-----------------------------------------|--------------|
## SDK gap report

Things the port had to work around, in priority order:

0. **Per-call draw overhead is the perf ceiling.** The biggest lesson from
   this port: cc65's function-call ABI makes every `spr`/`circfill`/`pset`
   cost ~500–2000 cycles regardless of how few pixels it draws, so a
   primitive-heavy frame is call-bound, not pixel-bound. The fix is *batching*
   — an SDK primitive that iterates many items in one C loop. The starfield
   (`gt.starfield_*`) is the shipped example; a batched sprite-list and a
   batched particle system would be the highest-value SDK additions for
   entity-dense games (an SDK particle system was prototyped and works, but a
   16 KB fixed-ROM-bank overflow blocked landing it here — the fixed bank is
   near-full with the runtime + font, so it needs the bank solver to spill
   fixed-bank pressure first).
1. **No `pal()` sprite tinting.** The original flashes enemy/pickup
   silhouettes white via PICO-8 palette tinting. On GameTank the
   framebuffer bytes *are* colours, so the blitter can't recolour a
   sprite. Workaround: at boot we stamp white/pink silhouette copies of
   the real art into free sheet cells (`makesil`/`silrow`/`silcell`) and
   blit those. A future `spr` tint/recolour path would remove ~40 lines
   of boot code and free those sheet cells.
2. **No `cartdata`/`dset`/`dget`.** The high score is per-session only
   (see the `TODO cartdata` markers). Needs a `save_ram` region + a
   persist-on-write hook in the SDK.
3. **No sprite flips.** `spr` has no `flip_x`/`flip_y`. This port never
   needed them (the art is symmetric or pre-mirrored in the sheet), but
   it is a general gap.
4. **Sound is stubbed.** The many `TODO sfx(n)` / `music(n)` markers are
   where the original triggers PICO-8 SFX. The gtlua audio surface is
   `gt.note`/`gt.noteoff`; wiring the real `__sfx__` through
   `scripts/p8sfx.mjs` (per `docs/sfx.md`) is the remaining audio work.

## Gameplay divergences from the original cart

* **Pools are bounded** (PICO-8 tables are not). Capacities:
  enemies 40, bullets 28, enemy-bullets 48, particles 56, shockwaves 12,
  pickups 8, floats 8. An `add()` that overflows drops silently — the
  caps are set well above anything a real wave produces.
* **Modes/missions are ints, not strings** (`MSTART`..`MLOGO`,
  `MI_FLYIN`..`MI_B5`) — gtlua has no strings outside `print`.
* Particle damping is `v*27/32` (0.84375) done in ints vs the original's
  `*0.85`; star drift and easings are shift approximations of the
  original divides (documented inline). All sub-pixel, invisible.
* Trig is a 16.16 table (`sin`/`cos`); the flicker/bob phases match the
  original within a frame.

## Controls (GameTank)

| GameTank      | action        | PICO-8 equiv |
|---------------|---------------|--------------|
| d-pad         | move ship     | ⬅️➡️⬆️⬇️      |
| GT B (❎)     | shoot         | X (btn 5)    |
| GT A (🅾️)     | cherry bomb   | O (btn 4)    |
| GT A / GT B   | start / retry | any key      |
