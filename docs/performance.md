# Writing fast GameTank Lua

The GameTank runs a 6.5 MHz 6502. That is *fast* for the 8-bit era, but it is
~1000× slower than the machine PICO-8 runs on. A PICO-8 cart that leans on
`sin`, `%`, `/`, and hundreds of draw calls per frame will run — but at 4–8 fps,
not 30. This guide is the set of patterns that keep a port at playable speed,
learned by profiling the real example carts.

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

**Profile the screen you actually play, not the title.** A cart that boots to a
menu or title screen will pace *that* screen if your harness just loads and
settles — and a title (a logo + a few particles) is nothing like gameplay (a
tilemap + entities + physics). Drive into a real level first (press through the
title, or temporarily auto-advance it), and confirm you're there (read the
level/state variable) before you trust a number. Optimizing the title screen
feels productive and changes nothing players feel.

---

## Measured example-cart baseline (2026-07-03)

| cart | vsyncs | fps | bound by |
|---|---|---|---|
| ufo-swamp | 3.0 | 20 | sprites |
| celeste-like | 3.0 | 20 | fills |
| cherry-bomb | 3.9 | 15 | sprites |
| jelpi | 4.0 | 15 | fills + sprites |
| combo-pool | 4.4 | 14 | sprites |
| just-one-boss | 7.0 | 8.6 | sprites |
| driftmania | 10.1 | 6 | full-screen tile blits |
| newleste | 10.7 | 5.6 | half physics / half draw |
| celeste2 (gameplay) | 7.1 (was 14.6) | 8.5 | tilemap + snow + physics |

(celeste2's row is *gameplay*; its title screen paces differently — see the
profiling note above.) None yet hit locked 30 fps — the light carts sit at ~20.
The heavy ports are blit-volume bound (the biggest lever left is `gt.bg_compose`
for their tilemaps) with fixed-point-math footguns on top (celeste2's snow, now
fixed: 14.6 → 7.1 gameplay vsyncs from integer `%` + a sine LUT).
