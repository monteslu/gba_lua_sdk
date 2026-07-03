# newleste — GameTank (gtlua) port notes

A hand-port of `carts/newleste-base.p8` — the CelesteClassic community's
base cart (Celeste Classic on the evercore v2.0.2 engine) — to the GameTank
console via the gtlua SDK.

- Original game: **Maddy Thorson** and **Noel Berry** (Celeste Classic).
- Base cart / evercore: the **CelesteClassic community** (taco360, meep,
  gonengazit, akliant, and contributors) — <https://github.com/CelesteClassic/newleste.p8>.
- GameTank port: **Luis Montes**.
- License: **GPL-3.0** (see `ports/newleste/LICENSE`), matching the upstream cart.

## What this port is

The whole point of a Celeste port is the *movement* — jump/dash momentum,
dash restore on ground, spike/fall death, berries. This port is a faithful,
near-line-for-line translation of newleste's `__lua__` into gtlua:

- `p_update()` / `p_move()` — the full player state machine (grace frames,
  jump buffer, wall jump, 8-direction dash with the diagonal `3.5355…`
  speed, dash startup accel table, wall-slide fall cap, soft-dash off walls).
- `p_is_solid` / `p_is_flag` / `p_spiked` / `p_oob` — the tile-flag collision,
  including one-way platforms (flag 8, only from above) and the four
  directional spike tiles (16-19) with the exact overlap sub-rules.
- Entities: fall floors, springs (floor + wall), refills, fly-fruit, fruit +
  the fruit-train / berry-bank, life-up popups, smoke, clouds, snow, dead
  particles, the room-transition wipe, and the timer HUD.
- Hair simulation, sprite animation (walk/jump/wall-slide/crouch/look-up),
  screenshake (P2 ⬆️ toggles it, newleste-default OFF).

### Playable slice

The port ships **two rooms**, the largest honest slice that fits the port's
64-column map window and the perf budget:

- **Level 1** — the classic first room (16×16), spawn + spikes + the first
  jumps. Exits at the top into level 2.
- **Level 2** — a wide 48×8 room (springs, fall-floors, a refill, the
  fly-fruit, one-way platforms, berries).

`load_level(id)` sets the level's map-x origin and width; `next_level()`
walks 1 → 2. The map/flag data for these rooms is generated straight from
the cart's `__map__` / `__gff__` (see the asset pipeline below), so the
geometry is the real Celeste Classic geometry, not hand-drawn.

## Frame rate & movement constants (IMPORTANT)

**No velocity/counter rescale was applied, and none is needed.**

- The source cart defines `_update()` (not `_update60()`), i.e. it runs its
  logic at **30 fps** in PICO-8.
- gtlua's compiler detects `_update()` without `_update60()` and emits the
  30 fps runtime mode (`gt_p8_fps30()` — it burns the second of the two 60 Hz
  vsyncs so logic+draw run once per 1/30 s). See `compiler/emit.js` (`thirty`)
  and `sdk/gt_api.c` (`fps30`).
- Because both the source and this port tick logic at 30 fps, every movement
  constant transfers **1:1**: `accel` 0.4/0.6, gravity 0.105/0.21, `maxfall`
  2.0, jump `pspdy=-2`, spring `-3`, dash `dspd=5.0` / diagonal `3.5355…`,
  the dash-startup accel table (`1.06066…`, `1.5`), the 7-frame grace, the
  5-frame jump buffer, `pdash_t=4`, etc. Jump apex height and dash distance
  therefore match the original's pixel geometry exactly (the levels depend on
  this, and they were copied unmodified).

The task brief's "rescale ×2 / ÷2" instruction is a contingency for an SDK
that runs the port at 60 fps; gtlua does **not** here, so applying it would
have *broken* the feel. This is the single most important divergence-that-
wasn't to record.

Numbers are exactly PICO-8 16.16 fixed-point in gtlua, so the fractional
constants (0.105, 0.15748 wipe slope, hair `/1.5`, etc.) carry over with no
requantization.

## Sprite flipping & recoloring (the blitter has no flip / no pal-on-sprites)

The GameTank blitter's `spr()` has **no horizontal-flip bit**, and `pal()`
cannot recolor an already-loaded sheet sprite. Celeste both flips Madeline
(facing) and recolors her hair (blue while the dash is charged). The port
handles this by **pre-authoring derived sheet cells** at asset-gen time
(`tools/genassets.mjs`), not at runtime:

- cells **64-70** — player frames 1-7 **mirrored** (red hair).
- cells **72-78** — player frames 1-7 with hair recolored **8→12 (blue)**.
- cells **80-86** — blue-hair frames **mirrored**.
- cells **88-90** — fly-fruit wing frames (12/13/14) mirrored.
- cell **91** — the side (wall) spring mirrored.
- cells **92-95** — the floor spring squashed by 1..4 px (the cart draws this
  with `sspr(72,0,8,8-delta,…)`, which the blitter can't do with a partial
  height, so each squash step is a baked cell).

`draw_player()` then selects the right cell from `pspr` + an offset
(`+63` mirror, `+71` blue, `+79` blue+mirror). This is the standard GameTank
idiom and costs sheet space (cells 64-95, otherwise-unused rows) instead of
runtime work. The task's alternative (`sset()` the mirrored pixels at boot)
was **not** used — baking at asset-gen keeps `_init` cheap and the flips
identical every run.

## Rendering strategy (perf)

- `cls()` is the first call in `_update()` — it kicks the framebuffer clear
  off in hardware while the frame's logic runs.
- The room is drawn from the map arrays with **`spr()` per non-zero tile
  only** (`if v > 0`), and the pass is **viewport-culled** to the visible
  8×8 window (`tx0..tx1`, `ty0..ty1`), so a sparse Celeste room is a few dozen
  blits, not a 256-blit full redraw. One-way platform tiles are collected in
  the same pass and drawn last (over entities), matching the cart's third
  `map()` layer.
- Background (clouds, snow) is `rectfill`, not sprites.
- `camera(draw_x, draw_y)` is set per room for world-space draws and reset with
  `camera()` for the screen-space HUD / particles / wipe.

## Audio — SILENT (a real SDK gap, documented below)

The cart's real `__sfx__` (jump 18, wall-jump 19, dash 20, failed-dash 21,
dash-restore 22, fall-floor 12/13, berry/life-up 9/10/11, refills 15/16/17)
were converted to a gtlua note-event player with `scripts/p8sfx.mjs`
(`gt.note` / `gt.noteoff` on channel 3, 30 fps tick, +24 semitone true-pitch),
and wired through `sfx_play`. **It does not fit and had to be removed.**

Root cause (measured, exact):

- Referencing `gt.note` links the ACP audio firmware object `gt_audio.o`.
- That object contributes **4312 bytes (0x10D8) of RODATA** to the **FLASH2M
  FIXED bank** ($C000-$FFFF, 16 KB). The firmware RODATA is **pinned to the
  fixed bank** — the banker moves game *functions* to B0/B1/B2 but cannot
  relocate this blob.
- With this game's runtime already using **~13.9 KB of fixed-bank CODE** plus
  ~1.5 KB of fixed RODATA (gt_api 498 B + gt_math sin/cos table 1024 B + this
  game 31 B), adding the firmware overflows the fixed bank's RODATA by
  **exactly 3758 bytes** (`FLASH2M bank placement failed: RODATA over by 3758`).
- The game itself contributes only **31 bytes** of fixed RODATA, so shrinking
  the game cannot recover the 3758 bytes — the shortfall *is* the firmware.
- This is not newleste-specific: the sibling `ports/celeste2` (which uses
  `gt.note`) overflows the same fixed bank by **43 bytes** — i.e. the fixed
  bank is at ~99.7 % just from runtime+firmware, with essentially no room for
  a large game's fixed content.

The sfx code path is preserved (`psfx` → `sfx_play`) so audio can be
reinstated the instant the SDK can bank the firmware — see the gap report.

## Map / flag builtin spec (what the SDK lacks, and how the port fills it)

gtlua has no `mget` / `fget` (map + sprite-flag lookups). The port supplies
them from generated arrays:

- `local m = array(1024)` — the map, **64 cols × 16 rows**, row-major:
  `mget(x,y) == m[y*64 + x + 1]` (1-based). Level 1 lives in cols 0-15,
  level 2 in cols 16-63. `tile_at(x,y)` reads at the current level's origin:
  `mget(lvl_x + x, lvl_y + y)`.
- `local fl = array(64)` — sprite flags, `fl[tile+1] = fget-byte(tile)`:
  bit0 (1) solid, bit1 (2) terrain/spike, bit2 (4) background, bit3 (8) one-way.

`tools/genassets.mjs` reads the cart's `__map__` (cols 0-63 only — a build-time
assertion fails if any tile lands in cols ≥ 64) and `__gff__`, RLE-collapses
runs into `for` loops, and splices them into `map_init()` between the
`-- @gen-map-begin` / `-- @gen-map-end` markers. It also builds `gfx.bin`
(the 128×128 `__gfx__` plus the derived cells above) in the SDK's 4bpp
two-pixels-per-byte, low-nibble-left format.

**A first-class `map()` / `mget()` / `fget()` in the SDK** (backed by a
packed map blob in a switched bank, like the sheet) would remove the whole
generated-array approach and free the RAM the 1024-entry `m` array uses.

## Divergences from the source cart

- **Two rooms** instead of the full 30-room game (the honest playable slice;
  the map window and perf budget scope it). `next_level()` and the exit tests
  are general, so more rooms are a data problem, not a code one.
- **Silent** (see the audio section) — the only behavioral divergence forced
  by the platform.
- Sprite flips/recolors are **baked cells**, not runtime transforms (visually
  identical; documented above).
- The floor-spring squash and wall-spring lean are approximated with baked
  squash cells / a 1 px lean (the blitter has no partial-height blit).
- Vibrato (sfx effect 2) would have been dropped even with audio (the pitch
  table has no sub-semitone detune) — moot while silent.

## SDK gap report (prioritized)

1. **Bank the ACP audio firmware RODATA.** This is the #1 blocker: any
   non-trivial game (newleste, celeste2) that wants `gt.note` overflows the
   16 KB fixed bank because the 4.3 KB firmware RODATA is pinned there.
   Placing `gt_audio.o`'s RODATA (the wavetable/sample blob) into a switched
   bank — or trimming/compressing it — would immediately re-enable sound for
   this and every other large port. Everything else here is nice-to-have; this
   one gates audio for the whole platform's "real game" tier.
2. **First-class `map()` / `mget()` / `fget()`** with a packed map blob in a
   switched bank (mirrors the existing SHEET segment). Removes the
   generated-array map (and its 1 KB+ of work RAM) from every tile-based game.
3. **A blitter flip flag (or an `sspr`/`pal`-on-sheet path).** Every game that
   flips or recolors a sprite currently burns sheet cells on mirrored/recolored
   copies. A hardware/emulated horizontal flip in `spr()` would halve the sheet
   cost of any character with a facing.
4. **Partial-height / partial-width blits** (`sspr` with a source rect) — the
   floor-spring squash and any scaled/clipped sprite need this; today they're
   baked frames.

## Build & verify

```sh
# regenerate map + gfx from the source cart, then build the 2 MB cart
node ports/newleste/tools/genassets.mjs
node bin/gtlua.js build ports/newleste/main.lua --sheet ports/newleste/gfx.bin \
  -o ports/newleste/main.gtr
```

The 32 KB EEPROM target overflows (this is a large game), so the build
auto-retargets the 2 MB FLASH2M banked cart. `node --test` covers the
compiler/dialect (34 tests).

Pacing target for the port is ~2.0 vsyncs per logical frame (30 fps); measure
with the `_gt_ticks` / `_gt_time_acc` symbols in `build/main.lbl`
(`vsyncs/frame = ticks / ((time_acc/1092)/2)`).
