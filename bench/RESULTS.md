# Per-function sweep - baseline + optimization results

Full measured cycle cost for every callable gt-lua name (`--num8` / 8.8 fixed
build), via `bench/run.mjs`. Frame budget for scale: **59,660 cyc/vsync**,
**119,321 cyc per 30fps game-frame**.

## Headline: the blit-font cliff (the real whole-game win)

Profiling a real game (driftmania) showed the function-level wins below barely
moved its per-frame cost - because the dominant cost wasn't math, it was **text
rendering**: `_glyph_cpu`, a per-pixel CPU glyph rasterizer, burning **~639,000
cyc/game-frame (~18% of the whole frame)**.

Root cause: driftmania is a large FLASH2M cart, and when the **fixed bank** runs
tight, `bin/gtlua.js` walks a size-relief ladder that ends in dropping the GRAM
**blit font** (`-DGT_NO_BLITFONT`) - after which *every* glyph falls back to the
slow per-pixel path. driftmania was tripping this over **13 bytes** (it failed
`keep-font` with `BSS over by 13`).

Fix: `gt_line.s` had added 13 bytes of BSS (its Bresenham state, moved out of zp
to fit combo-pool's zp budget). Those 13 bytes now **overlay gt_circ's zero-page
draw scratch** (`_gt_draw_scratch`) - line and circle are mutually-exclusive
blocking draws, so they share the region at **zero net zp/RAM cost**. This both
gives `line` its fast zp inner loop back (7,996 vs 9,321 cyc) *and* frees the 13
BSS bytes so driftmania keeps its blit font.

Measured on identical driftmania source, font-dropped vs font-kept:

| driftmania | busy-est / game-frame | `_glyph_cpu` |
|---|--:|--:|
| slow font (old) | 2,575.6k | 638,939 cyc |
| **fast font (fixed)** | **2,416.1k** | **0** |

**~160,000 cyc/game-frame reclaimed** - more than the entire per-function sweep
combined. All 9 games now build with the fast blit font.

## Optimizations shipped this sweep

| function | before | after | speedup | how |
|----------|-------:|------:|:-------:|-----|
| `sgn`  |   120 |    25 | **4.8×** | inline `x<0?-1:1` for cheap-pure args (was a `gt_sgni` cdecl call) |
| `abs`  |   161 |    60 | **2.7×** | inline `x<0?-x:x` for cheap-pure args (was a `gt_absi` cdecl call) |
| `line` (diagonal) | 47,694 | 9,321 | **5.1×** | asm Bresenham VRAM-poke walk (`gt_line.s`) for on-screen diagonals - one `sta $4000+(y<<7)+x` per pixel. (Was 7,985 with the state block in zero page; moved to BSS to fit the zp budget - see the ZP note below - costing ~17% but keeping every line-using game buildable.) |
| `color` |  247 |   148 | **1.7×** | inline `resolve_color` + `__fastcall__` (dropped the cdecl arg round-trip) |
| `atan2` | 2,882 | 930 | **3.1×** | 256-byte angle table replaces two `gt_fmul` (~1,200 cyc), **and** `gt_ratio8` - an 8-round unsigned divide - replaces the 24-round `gt_fdiv` for the ratio. Operands normalized to a byte first (shift both by the same power of 2; the ratio, hence the angle, is preserved). Max angular error vs the exact divide: 1/256 turn = 1.4° |
| `print` (number) | 3,151 | 2,225 | **1.4×** | int→decimal `/10` per digit used cc65's 16-bit `udiv16by8a`; now the exact byte reciprocal `(b*205)>>11` (one `mul8` + shift) once the value fits a byte - every digit of a <256 HUD value |
| `sin`  |   195 |   137 | **1.4×** | native 8.8 sin table (`int16`) - one 2-byte load vs a `long`-table index + 32-bit `>>8` |
| `cos`  |   232 |   174 | **1.3×** | same 8.8 table |
| `rnd`  |   909 |   814 | **1.1×** | route the fraction`×`range multiply through the zp `gt_fmul_zp` (no C-stack marshalling) |

`abs`/`sgn` numbers are with a **variable** arg (a constant folds to nothing and
hides the call). The min/max functions already had this inline treatment; this
sweep extended it to abs/sgn, which had been left as cdecl calls.

**Also reclaimed 1 KB ROM:** the N8 build no longer includes `gt_sintab.h` (the
16.16 long sine table) - only the non-N8 path uses it now; N8 reads the
512-byte 8.8 table.

### Already near-optimal (checked, left as-is)
- `gt_fmul` (617) / `gt_fdiv` (1,366) - hand-tuned N8 asm (quarter-square mul,
  restoring div) with zp entries; the emitter already uses `_zp` for simple
  operands. These are the 6502 floor. (atan2's ratio doesn't need the full
  24-round precision, so it gets the dedicated 8-round `gt_ratio8` instead - see
  above; the general `gt_fdiv` still uses the full-precision routine.)
- `sqrt` (1,133) - division-free restoring-root asm (~550 cyc core + call/fixed
  marshalling); already asm.
- `circ`/`circfill` - one horizontal-span blit per row is the minimum for a
  blitter-filled circle.
- `rect` (3,364) - inherently 4 edge-fills for a hollow box.

## SDK bugs found + fixed by the sweep

The link-gate for `gt_balls.s` only checked `gt_phys_step` (then balls_step), so a cart
using `phys_drag`, `phys_draw`, or `parts_step` **without** `phys_step` failed to
link (`unresolved external`). Both the `.s` assemble gate and the `-DGT_BALLS`
compile gate now check all four. (`bin/gtlua.js`)

**Zero-page regression (caught by the full-game rebuild):** `gt_line.s` first
reserved its whole 15-byte Bresenham state block in zero page. `gt_line.s` links
unconditionally (the always-compiled `GT_LINE_DIAG` imports it), so those 15 bytes
were always resident - and they pushed **combo-pool** over the zp budget
(`ZEROPAGE over by 13`). Fix: only the write pointer `ln_ptr` (2 bytes) needs zp
for the indirect plot; the rest moved to BSS. Costs ~17% on `line` (abs vs zp
addressing in the inner loop) but keeps every line-using game buildable. Lesson:
**unconditionally-linked asm must keep its zp footprint minimal** - zp is a shared
256-byte resource, not per-function scratch.

## Full baseline (post-optimization, cyc/call)

Cheapest → most expensive, excluding the blocking multi-frame GRAM ops.

**Trivial (≤ 30 cyc):** flr 8 · ceil 8 · min 8 · max 8 · mid 8 · rgb 10 · camera
12 · btn 14 · btnp 14 · ticks 14 · del 17 · pool/add 24 · sgn 25 · t/time 28

**Cheap (30–200):** gflush 89 · autocls 111 · srand 120 · sin 137 · color 148 ·
cos 174 · abs 60 · noteoff 361 · pool_anim 355 · pset 391 · pool_sprs 412 · sset
411 · phys_draw 1094 (as balls_draw)

**Moderate (200–3,500):** pal 248 · sfx_bank/music_bank 616 · parts_step 708 ·
rnd 909 · note 996 · sqrt 1133 · pool_edraw 1193 · trail_stamp 1300 (deleted in 0.2.3) · hit_scan
1316 · dbar 1429 · cls 1531 · print 1682 · print_buf 1949 · starfield_draw 2414 ·
sfx 2798 · atan2 2882 · phys_step 3039 (as balls_step) · rect 3364 · rectfill 369

**Heavy per-call (3,500–20,000):** starfield_move 3978 · tiles_draw 4496 ·
chunks_draw 4959 · border 5468 · chain_step_draw 7173 · flakes_draw 8221 ·
flakes_draw2 8317 · bg_tile 8293 · music 8694 · circfill 8917 · track_props
15,717 · bg_draw 16,464 · circ 17,499

**Multi-frame BLOCKING (span >1 vsync - the raw number includes blit-drain the
op waits on; overlaps update logic in a real game):** bg_coln ~1.1v · flakes_init
~1.8v · starfield_init ~3.1v · track_col/row2 ~3.7v · bg_clear ~48v · track_compose
~49v · bg_compose ~52v · track_grid ~118v

## Notable findings (targets for a future pass)

- **`sqrt` = 1,133** - division-free restoring-root asm; near the floor. A
  squared-distance compare avoids it entirely where possible (game-side win).
- **`circ` = 17,499 / `circfill` = 8,917 (r=10)** - scale ~2r blits; a few
  medium circles blow the frame budget (known perf-model fact).
- **`bg_clear`/`bg_compose`/`track_compose`/`track_grid`** are 48–118 vsync
  BLOCKING ops - one-time-per-scene setup, never per frame. The incremental
  `track_col`/`track_row2` (~3.7v) are the per-frame scroll path (driftmania).
- **`rect` = 3,364** - inherently 4 edge-fills; near-optimal for a hollow box.

## Profile-guided round 2 (driftmania gameplay)

Profiled driftmania's steady-state race loop (PC histogram → functions via
`main.dbg`). Non-idle leaders: `gt_q_pump` (blit-queue driver, already tight
asm), `pushax` (cc65 cdecl arg-push, architectural), the HUD print path, and the
fixed-point multiply. Idle was ~26% of the frame - real headroom. Targeted the
HUD and rnd:

| function | before | after | speedup | how |
|----------|-------:|------:|:-------:|-----|
| `flr(rnd(n))` | 532 | 435 | **1.2×** | the integer-rnd path now uses the zp `gt_fmul_zp` (like the fixed `rnd()` already did) - drops the cdecl marshalling from every spawn/particle-count random |

`print`'s ~1,034 cyc fixed overhead is the bank switch to font-bank 0 + queue
flush (required for FLASH2M carts); ~326 cyc/glyph is a single sprite blit, near
the blitter floor. Both left as-is.
