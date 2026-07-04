# Writing fast GameTank Lua

The GameTank runs a 3.58 MHz 65C02 (measured: ~59.7k cycles per vsync — the
NTSC colorburst clock, exactly 2× an NES). That is quick for the 8-bit era,
but there is no PPU: **the CPU composes every frame itself.** An NES draws its
whole screen in dedicated hardware and spends ~20 cycles of CPU per sprite (4
OAM bytes); here a sprite is a blit the CPU must stage, queue, and wait out —
hundreds of cycles each — and the background is yours to repaint. A PICO-8
cart that leans on `sin`, `%`, `/`, and dozens of always-on entities will run —
but at 4–12 fps, not 30. This guide is the set of patterns that close that
gap, learned by profiling the real example carts.

**The target:** a frame must finish in **2 vsyncs** to lock 30 fps. The pacing
tool reports `vsyncs/frame` — 2.0 is the goal, 4.0 is 15 fps, 15.0 is a
slideshow. Measure; don't guess.

Two things dominate a frame: **how many blits you issue** and **how much
fixed-point math you do**. Almost every perf problem is one of those two.

---

## 1. Fixed-point `%` and `/` are ~19,000 cycles each. Avoid them in loops.

This is the single most expensive footgun, and the least obvious.

A number with any fractional part is a **16.16 fixed-point** value. `a % b` and
`a / b` on fixed-point values call the runtime's `gt_ffmod` / `gt_fdiv`, which
do a full 32-bit divide **and** a multiply — roughly **19,000 cycles**. A whole
30 fps frame is only ~120,000 cycles, so **just 6 fixed-point modulos blow the
entire frame budget.** Doing two per particle across 26 particles (as the
celeste2 snow did) costs ~7 vsyncs by itself — half the frame — for math whose
result you immediately floor to a pixel.

**Integer `%` / `/` are ~6× cheaper** (`gt_ifmod` / `gt_ifdiv`), and **power-of-
two divisors are essentially free** — the compiler turns `x % 128` into a
bitmask and `x / 32` into a shift, for *both* int and fixed values.

```lua
-- SLOW: fixed-point modulo, ~19k cycles each, twice per particle
local px = (snow_x[i] - cam_x * 0.5) % 132
local py = (snow_y[i] - cam_y * 0.5) % 132

-- FAST: do the wrap in integer space. The drawn position is a pixel anyway,
-- so floor first, then use integer %. ~6x cheaper, pixel-identical output.
local px = (flr(snow_x[i]) - (cam_x >> 1)) % 132
local py = (flr(snow_y[i]) - (cam_y >> 1)) % 132

-- FASTEST: if you control the constant, make the wrap a power of two.
-- `% 128` on ANY value compiles to a bitmask — near-free.
pay[i] %= 128          -- compiles to `& 0x7FFFFF`, not a divide
paoff[i] += paspd[i] / 32   -- /32 compiles to `>> 5`
```

**Rules of thumb**
- Never put a non-power-of-two fixed `%` or `/` inside a per-frame loop.
- Prefer `>> n` / `<< n` and `& (n-1)` when the operand is an integer or the
  divisor is a power of two — the compiler already does this, so *write your
  constants as powers of two* (128, 64, 32) where you have the choice.
- If you need a wrap and the range isn't a power of two, `flr()` to an int
  first and use integer `%`.
- Replace a runtime `/ k` by a constant with a precomputed lookup table when `k`
  isn't a power of two and the input range is small (driftmania builds a `div3[]`
  table to turn `camx / 24` chunk math into a table read).

*This one pattern (plus a sine LUT, below) took celeste2's gameplay from ~4 fps
to ~8.5 fps with no visual change.*

---

## 2. A blit is a fixed CPU cost, no matter how big. Budget ~68 sprites/frame.

Every `spr`, `rectfill`, `circfill`, `line`, etc. queues a blit, and **the cost
is per-blit, independent of size** — a 1×1 fill costs the same as a 16×16 one.
Measured budgets at 30 fps:

| primitive | budget / frame |
|---|---|
| `spr` | ~68 |
| `rectfill` | ~37 (the C fill path is ~2× a sprite) |
| `circfill(_, _, r, _)` | ~2r blits **each** — a radius-8 circle is ~16 blits |

So a screenful of per-tile `spr()` (a 16×16 tile grid = 256 blits) is ~4× over
budget on tiles alone. Watch for:

- **Filled circles are expensive.** `circfill` emits ~2r scanline blits. Three
  medium circles blow the budget. For a 1–2 px dot (a particle, a bullet), use
  `pset` — it's a direct CPU byte-write, not a blit, and essentially free.
- **`print` is cheap** — it writes glyph pixels directly to VRAM (not blits), so
  text is never your bottleneck.
- **Cull off-screen work.** Only draw the visible window. driftmania walks just
  the visible chunk range, not the whole map.

### Chunk atlases: pre-render repeated blocks, blit once each

When a scrolling world is built from repeated multi-tile blocks (driftmania's
track is 3×3-tile chunks), don't re-issue the tiles every frame — pre-render
each distinct block into the 256×256 GRAM canvas **once at init** and draw one
blit per block:

```lua
function atlas_init()
  gt.bg_clear()                        -- canvas to color 0 (= transparent)
  -- stamp each chunk kind's tiles at its atlas slot (8px grid)
  gt.bg_tile(t, (a & 7) * 24, (a >> 3) * 24)   -- mask+shift slot math, no %
end
function draw_chunk(a, wx, wy)
  gt.gspr((a & 7) * 24, (a >> 3) * 24, 24, 24, wx, wy)   -- ONE blit
end
```

`gt.gspr` is camera-adjusted and colorkey-transparent like `spr()`, so empty
tiles (canvas color 0) vanish exactly as skipped tiles did — layered
ground/decor chunks keep working. driftmania went from ~200 tile blits to ~25
chunk blits per frame: **10.1 → 7.1 vsyncs (6 → 8.4 fps)**, pixel-identical.
This works where a static `bg_compose` background can't — the world (720×720)
never fits the canvas, but its 53 distinct chunk kinds do.

A second shape for levels **wider than 256px but ≤128 tall**: compose the level
as 128-tall strips (strip s = world x `[s*256,(s+1)*256)` at canvas rows
`s*128..s*128+127`) and draw the camera window as **four** `gspr` blits (two
x-pieces at the strip boundary × two 64-tall halves — the blitter's W/H are
7-bit). newleste's whole map pass went from ~80 tile blits to 4: 9.0 → 7.1
vsyncs. Cache which level the canvas holds so death-respawns skip the
recompose (no reload hitch).

**PAGE_OUT gotcha for long canvas work:** the emulator presents from the LIVE
`$2007`, and compose/clear hold their own register state across many vsyncs —
if that state drops the frameflip bit, the presented page goes out of phase
with the flip protocol and screenshots catch half-drawn frames. The SDK's bg
write states now preserve `frameflip`; if you ever hand-roll VDMA state, do the
same.

### The budget is an overlap economy

An important refinement, learned the hard way: **queued blits overlap your
update logic.** A draw call stages an entry and returns; the blitter drains the
queue while the CPU runs the rest of the frame. So in a frame with CPU
headroom, an extra 30 background blits can cost *approximately nothing* —
just-one-boss's 30-blit static arena measured **neutral** when converted to a
single composed-page blit, because those blits had been riding free in its
idle time all along.

The budget numbers above describe the **saturated** regime — a frame already
using its CPU time, where each additional blit's staging cost is real
wall-clock. That's when batching pays. Corollaries:

- Profile before batching: if the cart isn't saturated, cutting blits buys
  nothing *now* (it still buys headroom for heavier moments).
- Synchronous operations break the overlap: `gt.bg_draw` and any CPU-mode
  write (`pset`, `print`) drain the queue before proceeding. Group CPU-mode
  draws together (e.g. all your particles at the end of `_draw`) so you pay
  one transition, not several.

### Static backgrounds: compose once, blit once

The big lever for tilemaps: pre-render the static background into a spare GRAM
page **once per level** with `gt.bg_compose`, then blit the whole thing in **one**
cheap blit every frame with `gt.bg_draw` — instead of a per-tile `spr()` loop.
The bg page is a 256×256 canvas, so a level larger than one screen composes once
and `gt.bg_draw(sx, sy)` scrolls a 128×128 window across it for free. Draw only
your *moving* sprites with `spr()` on top. See the README's "Fast backgrounds"
section for the API.

---

## 3. `sin` / `cos` / `sqrt` / `atan2` / `rnd` are real function calls.

They go through the fixed-point runtime (hundreds of cycles) — fine a few times
a frame, painful per-particle. In the snow loops, one `sin()` per flake across
26 flakes costs ~3 vsyncs.

- Hoist anything loop-invariant **out** of the loop (compute `sin(t)` once, not
  once per entity if the argument is the same).
- For cheap periodic motion, a small precomputed wave table indexed by a
  per-entity phase beats calling `sin` every frame.
- `rnd` is not free either — seed positions once at spawn, don't re-roll every
  frame unless you need to.

---

## 4. Keep values integer when you don't need the fraction.

The compiler keeps a value in fast 16-bit ints as long as it only ever sees
integer operations, and promotes to 16.16 fixed the moment a fraction touches
it. Fixed-point add/subtract are cheap, but fixed `*`/`/`/`%` are not (see §1).

- If a quantity is a whole number (a tile index, a pixel coordinate, a counter),
  keep it integer — don't initialize it as `0.0` or add `0.5` to it.
- Sub-pixel motion needs fixed point, but the *drawing* position is always a
  pixel — `flr()` at the draw boundary and do any wrap/compare in int space.

### The compiler's own optimizations (so you don't hand-tune them)

The emitter narrows counting-loop variables to bytes when bounds are provably
0-254, collapses `arr[x + 1]` to `arr[x]` at compile time, folds the
1-based `-1` into the symbol address for byte-counter indexes, and
strength-reduces `x * C` (C up to 255, e.g. tile sizes like 14 or 24) to
shift-adds — a constant multiply that used to cost ~250 cycles through the
cc65 runtime now costs ~40, so `spr(n, col * 14, row * 14)` grid math is
cheap. Measured on the
entity-update probe: the full stack (narrowed counters + `array8` + index
folds) runs **3.0× faster than the same Lua compiled naively** (561 → 186
cycles per update). Single-`return` helpers AND
if-then-return chains (`sign0`, tile classifiers) inline automatically at
their call sites (~466 cycles of calling convention saved per call — a probe
making 256 helper calls per frame runs 4.0 vsyncs without the inliner, a
locked 2.0 with it), and functions you never call are eliminated entirely —
so small named helpers are FREE: write them for clarity. You get all of it by writing plain counting loops over `array8`
fields — the idiomatic entity-pool shape.

### Byte arrays: `array8` for entity pools

`array(n)` elements are 16-bit; `array8(n)` stores bytes (0-255) — **half the
RAM, and ~2× faster element access in counting loops** (measured: 561 → 280
cycles per `ex[i] += ev[i]` entity update). The catch: the 2× needs a *narrow
index* — a plain counting loop with constant bounds (which the compiler
already narrows to a byte register). A big table indexed by a 16-bit
expression still wins the RAM but little speed, because the pointer
arithmetic dominates. So: entity fields that fit a byte (hp, type, sprite,
timer, color, size) belong in `array8`; a 1024-entry map keeps its speed
profile but drops from 2 KB to 1 KB.

### The `--num8` build flag: 8.8 numbers everywhere

The manual 8.8 tricks below are now a compiler mode: `gtlua build game.lua
--num8` makes every fractional value 8.8 in a 16-bit int instead of PICO-8's
16.16 in a 32-bit long. Every fixed add/compare/array element halves or
better. **Measured: celeste2 gameplay runs 16% faster from the flag alone**,
with exact arithmetic on the whole math test suite (trig, atan2, floored
mod, saturating divide) at 8.8 scale.

The contract: values live in ±127.996 with 1/256 steps, and `t()` wraps at
128 seconds. That fits most games — positions on a 128px screen, speeds,
timers, angles in turns — but it is NOT bit-exact PICO-8: constants like 0.1
round to the nearest 1/256, so replays and physics feel are approximately,
not identically, preserved. Verify your game plays right, then keep the flag.

### Shrink your fixed-point: 8.8 in an int

When a fractional quantity has a small range — a speed that never exceeds ±8, a
subpixel remainder always in (−1, 1) — you don't need 16.16 in a 4-byte long.
Store it as **8.8 fixed-point in a plain int**: `value * 256`, where `256 = 1.0`.
Every add, compare, and assignment is then cheap int math instead of 4-byte
long arithmetic, and nothing that survives to a pixel is lost.

```lua
local pvy8 = 0                    -- player y speed, 8.8 (256 = 1.0)
local pry8 = 0                    -- subpixel remainder, 8.8

pvy8 += 54                        -- gravity 0.21  (0.21*256 ≈ 54)
if pvy8 > 512 then pvy8 = 512 end -- max fall 2.0
pry8 += pvy8                      -- accumulate subpixels
local amt = (pry8 + 128) \ 256    -- == flr(rem + 0.5), bit-exact, a shift
pry8 -= amt * 256
py += amt                         -- whole pixels only
```

The `(x + 128) \ 256` round is **bit-exact** with the classic `flr(rem + 0.5)`
pattern, and `\ 256` compiles to an arithmetic shift. Scale your constants once
(±0.5% rounding on something like gravity is imperceptible) and comment the
original value. This is how the newleste port runs the canonical Celeste
movement engine — the whole player-physics state is 8.8 ints, and its movement
trace stayed **bit-identical** to the 16.16 version.

### Scan once, not three times

Collision helpers love to re-scan the same tiles: newleste's `p_is_solid` did a
one-way-platform check as *two extra full scans* of the same 2×2 tile window on
top of the solid scan (~14k cycles per call, several calls per frame). Restructure
to **one pass that collects every flag you need** (`solid = f & 1`, `oneway = f & 8`),
then decide afterwards. Same trick, smaller scale: hoist `tile_at()`→`mget()`
call chains out of inner loops — after the loop bounds are clamped, a direct
`m[rowb]` array read with `rowb += 64` per row replaces two nested function
calls per tile. celeste2's collision core went further: `tile_solid(mget(bget(
idx)))` was THREE nested calls per tile; inlining the packed-map unpack and the
flag test into the scan cut `p_check_solid` from 0.033 to 0.019 vsyncs per
call — and it runs several times a frame, plus once per pixel moved.

And guard rarely-true work with a cheap **broad-phase test**: fall-floors ran
three precise player-overlap calls per floor per frame; one inline box test
(the union of the three rects) skips them all when the player is nowhere near —
which is nearly every floor, nearly every frame. Springs decayed
`spgdelta *= 0.75` forever after reaching exactly 0 — `if (spgdelta ~= 0)` ends
that. Idle cost is real cost: profile the *standing still* frame too.

---

## How to profile a slow cart

Slow carts almost always have ONE hot function, not a uniformly slow frame.
Bisect:

1. **Split update vs draw.** Stub `_draw`'s body down to `cls()` (leave `_update`
   intact — and double-check you didn't truncate `_update` too) and pace it.
   That tells you the physics floor. The rest is draw.
2. **Stub draw helpers one at a time** (`draw_snow`, `draw_tiles`, `hud`, …) and
   re-pace. The one whose removal collapses the vsync count is your culprit.
3. **Inside the culprit, split math from drawing** — replace the draw call with a
   constant-coord version to isolate whether it's the blits or the arithmetic.
   For celeste2's snow, constant-coord circfills paced 5.0 while the full math
   paced 15.0: the cost was the fixed-point `%`, not the drawing.

The pacing harness reads `_gt_ticks` vs `_gt_time_acc` over a fixed vsync window;
2.00 vsyncs/frame == locked 30 fps.

**Beware vsync quantization.** A frame ends by *waiting for the next vsync*, so
frame time snaps up to whole vsyncs — a change worth 0.3 vsyncs can show
**zero** pace difference if it doesn't cross a boundary, and small stub-based
bisects all read as "no change". When the plateau hides your signal, use an
**amplifier**: call the suspect function 10–30 extra times per frame and divide
the pace delta by the extra calls.

```lua
-- temporarily, at the end of _update():
if pmode == 2 then
  for bi_ = 1, 29 do
    local zz_ = p_is_solid(0, 1)   -- suspect under test
  end
end
-- per-call cost ≈ (amped_pace − baseline_pace) / 29
```

Pick amp bodies that don't corrupt state (pure predicates are ideal; an update
that converges, like hair smoothing, is fine too). This is how the newleste
physics work found `p_is_solid` at ~14k cycles/call and hair smoothing at ~13k
per frame after ordinary bisecting showed nothing.

**Verify with a movement trace, not vibes.** Before touching physics, record a
deterministic trace (e.g. player px/py/state at fixed frame checkpoints from
boot — the spawn animation is perfect: no input, no randomness in the path).
After every optimization step, the trace must match **bit-exactly**. It caught
nothing in the newleste 8.8 conversion because the conversion was chosen to be
exact — that's the point: pick transforms you can prove, then prove them.

**Profile the screen you actually play, not the title.** A cart that boots to a
menu or title screen will pace *that* screen if your harness just loads and
settles — and a title (a logo + a few particles) is nothing like gameplay (a
tilemap + entities + physics). Drive into a real level first (press through the
title, or temporarily auto-advance it), and confirm you're there (read the
level/state variable) before you trust a number. Optimizing the title screen
feels productive and changes nothing players feel.

---

## Measured example-cart numbers (2026-07-04, current compiler)

| cart | vsyncs | fps | state |
|---|---|---|---|
| just-one-boss (gameplay) | 2.25 | ~29 | at PICO-8 speed |
| ufo-swamp / celeste-like | 3.0 | 20 | light + lean |
| cherry-bomb (combat) | 4.5 (was 4.8) | 13 | entity volume; compiler recovered ~0.3 |
| combo-pool (gameplay) | 5.0 | 12 | physics floor 4.0 |
| driftmania | 5.6 (was 10.1) | 10.7 | chunk atlas + inline + shift-add multiplies |
| celeste2 (gameplay) | 5.6 with --num8 (was 14.6) | 10.7 | footgun fixes + compiler inlining + 8.8 numbers |
| newleste | 7.1 (was 11.1) | 8.5 | physics 3x + canvas map |

Gameplay numbers, measured in real play (never the title screen). The compiler
work (inlining, narrowing, index folds, zp params) now recovers real frame
time with zero game-source changes — and every future cart gets it for free.
