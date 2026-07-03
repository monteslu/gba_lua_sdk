# Combo Pool — GameTank port notes

Hand-translation of **"Combo Pool"** by **NuSan** (PICO-8, p8jam2 —
<https://www.lexaloffle.com/bbs/?tid=3467>) to the GameTank via the `gtlua`
SDK. Original and this port are both CC-BY-NC-SA 4.0 (see `LICENSE`).

Extract used as the reference: `carts/combo-pool-extract/source.p8.lua`
(the un-minified cart Lua) + `carts/combo-pool-extract/gfx.bin` (the 8 KB
sprite sheet).

---

## How to build

```
node ports/combo-pool/build.mjs
```

This produces `ports/combo-pool/main.gtr` (a 2 MB FLASH2M banked image) and
is copied to `roms/combo-pool.gtr` and `~/roms/gametank/combo-pool.gtr`.

### Why a banked (2 MB) cart, not a flat 32 KB one

The obvious `node bin/gtlua.js build … --sheet …` (flat 32 KB) **does not
fit**: it overflows the 32 KB window by ~14 KB. The game is genuinely big —
the translated logic is ~1440 lines of Lua and the sprite sheet alone is
8 KB, so code + data + sheet ≈ 38 KB. There is no way to shave 14 KB
without gutting the game, so the FLASH2M banked target is the correct one.

`bin/gtlua.js`'s **auto-retarget** to FLASH2M then fails with
`FLASH2M bank placement failed: RODATA over by 3744`. That is the *naive*
placement heuristic in `bin/gtlua.js` — it packs the read-only DATA into the
fixed bank and overflows it. **`build.mjs` uses a hand-tuned `PLACEMENT`
map** (update/physics/audio in bank 0, all drawing in bank 1, init/bake +
menu-draw + sheet + ACP firmware in bank 2) plus two build-time source
transforms (below), and links cleanly with every segment inside its 16 KB
bank. So the fix for the "RODATA over by 3744" blocker is simply: **build
with `build.mjs`, not the CLI auto-retarget.**

Post-link segment occupancy (all under 0x4000 per bank):

| bank | contents | size |
|------|----------|------|
| BANK0 | B0CODE (update/physics/audio) | 0x3FA7 |
| BANK1 | B1CODE + B1RODATA (all drawing + print literals) | 0x3634 |
| BANK2 | SHEET + B2CODE (init/bake + menu draw) | 0x3A7B |
| FIXED ($C000) | CODE + RODATA + VECTORS (runtime, shared, stubs) | ends 0xFF56 |

---

## SDK gap report (prioritized)

These are the compiler/SDK limitations this port had to work around. `build.mjs`
exists ONLY because of gaps 1–3; delete it once they are fixed.

**P1 — banked builds can't place audio's ACP firmware.**
`sdk/gt_audio.c` `#include`s a ~4 KB ACP firmware blob (`gt_acp_fw.h`) into
RODATA. In a banked build cc65 lands that blob in the **fixed** bank, which
overflows it. `build.mjs` works around it by text-transforming a copy of
`gt_audio.c` to wrap the include in `#pragma rodata-name(push,"SHEET") …
(pop)` so the blob rides in bank 2 next to the sheet, and calls
`gt_sheet_init()` (which selects bank 2) immediately before
`gt_audio_init()` so the firmware is mapped in when the one-time upload runs.
*Fix:* let the banked linker script/segment plan give the firmware a home in
a switchable bank, or expose a `#pragma` hook from the SDK so a game doesn't
have to rewrite `gt_audio.c`.

**P2 — cc65 string-literal pool ignores the active `#pragma rodata-name`.**
cc65 defers the translation-unit's string-literal pool to the *end* of the
unit, after `emit.js`'s `#pragma rodata-name` scopes have popped, so every
`print("…")` literal lands in the fixed bank's RODATA and overflows it.
`build.mjs` works around it by appending
`#pragma rodata-name("B1RODATA")` to the generated `main.c` so the tail pool
is parked in bank 1 (all of this game's literals belong to bank-1 draw
functions). *Fix:* have `emit.js`/the compiler emit an explicit
`rodata-name` at end-of-unit, or route string literals into a
placement-aware segment. This is fragile: a game whose literals span
multiple banks can't be fixed by a single tail pragma.

**P3 — no first-class banked build for a game with a sheet + audio.**
`bin/gtlua.js`'s banked path exists but its automatic function/data placement
isn't good enough for a real game (see the "RODATA over by 3744" failure
above). A game currently needs a hand-written `PLACEMENT` map. *Fix:* a
smarter default placement (call-graph-aware, RODATA-balancing across banks)
so `node bin/gtlua.js build … --sheet …` "just works" for banked games, and
a stale-`PLACEMENT`-entry warning is only informational (see P4).

**P4 — cosmetic: stale-placement warning.** `build.mjs` prints
`placement: no function 'draw_ball_plain' (stale entry?)` — that name is in
the `PLACEMENT` map but the function was renamed/inlined during translation.
Harmless (a missing placement entry just leaves the function in the default
bank), left in as documentation of the intended layout. Not a bug.

**P5 — no per-frame division budget.** `gt_fdiv` is a ~48-step software loop
(~35K cycles, over half a vsync), so the port cannot divide per ball per
frame. Every `/` in a hot loop was reformulated as a shift-based approximate
(drag `x - x/64 - x/256` ≈ ×0.98) or precomputed into a boot-time table
(`invsq[]` for contact math, `march_off[]`/`phase_off[]` for the menu, one
`inv_maxlife = 1/maxallowed10` division at level start). This is inherent to
the 6502 @ 3.5 MHz, not a fixable SDK gap — but a *documented* "divide is
expensive, here are the table idioms" note in the SDK docs would save the
next porter the same discovery.

---

## Gameplay divergences from the original cart

All are performance-driven; none change the feel of the game.

1. **Ball table is capped at 28** (the cart's ball list is unbounded). 28 is
   far more than a normal life bar allows on-screen; you'd have to be losing
   badly to hit it. Overflowing simply drops the launch (returns slot 0),
   which is a natural "table full" — but in practice the life drain ends the
   game first.

2. **Physics: 2 collision substeps per frame, not 5.** The cart integrates
   in 5 substeps; this port uses 2 with a wider (8 px vs 3 px/substep)
   contact range so fast balls still can't tunnel through each other. The
   combo-cooldown (`lastmult`) is still ticked 5×/frame to keep multiplier
   timing identical.

3. **Contact math uses a `1/d²` lookup table** (`invsq[128]`, built at boot)
   instead of a per-contact division — see P5. Accurate for the whole
   contact range (`d² < 64`).

4. **Aiming is d-pad only** (the cart also supported the PICO-8 mouse — the
   GameTank has no mouse). Left/Right rotate the launcher; holding the launch
   button (GT A) switches to a finer rotation step, exactly as the cart's
   "hold for precise rotations" hint describes.

5. **Balls are pre-baked sprites, not per-frame `circfill`.** The cart draws
   each ball procedurally (3 nested `circfill`s + backdrop + shadow ≈ 5
   primitives, ~15K cycles). At GameTank blit cost that's unaffordable per
   ball per frame, so `_init` bakes each tier's launcher/field/blink ball
   into free sheet cells and the game draws **one `spr()` per ball**. The
   discs are drawn with the same midpoint-circle spans as `circfill`, so the
   baked balls are pixel-identical to the procedural ones. (This is the
   dialect rule "match the source's look": the marbles still read as the
   circular, shaded marbles of the original.)

6. **Border / lattice / HUD panel are composed sheet STRIPS.** `build.mjs`
   pre-composes the field weave rows, borders, and the 56×16 HUD panel into
   the blank bottom rows of the sheet so each draws with ONE wide `spr()`
   instead of dozens of per-cell blits (~2.9K cycles/blit measured). Same
   pixels, a fraction of the calls.

7. **Aim guide is a single line, not a 5-pass bold line.** The cart's
   `boldline()` is five 130 px Bresenham passes (~1.5 vsyncs of `pset`s). The
   guide here is one line in the same color over the opaque field strips.

8. **Score-popup shadow is a 2-print drop shadow, not a 4-direction
   outline.** The cart outlines popup text with 4 offset prints (+ the fill =
   5); this port draws one black shadow pass + the white fill (2 prints).
   Visually near-identical, 60% fewer text blits.

9. **Audio is an approximation.** GameTank's `gt.note(ch,note,[vol])` /
   `gt.noteoff(ch)` (4 channels) stands in for the cart's PICO-8 sfx tracker.
   A tiny per-channel sequencer (`update_audio`, driven by `playfx(id)`)
   reproduces the *events* — launch, combo tick, merge, bomb, fanfare — with
   base note + slide/arpeggio envelopes rather than the exact PICO-8 SFX. The
   `scripts/p8sfx.mjs` real-`__sfx__` converter exists in this SDK; a future
   pass could swap the hand-tuned envelopes for converted note arrays for a
   closer match.

10. **Trails are stamped sprites, not framebuffer smears.** The cart leaves
    persistent framebuffer smears; the GameTank double-buffers and clears, so
    trails are approximated by stamping a small per-tier trail sprite behind a
    fast-moving ball.

---

## Controls (GameTank)

| GameTank button | raw libretro | action |
|-----------------|--------------|--------|
| D-pad Up/Down | up/down | menu select |
| D-pad Left/Right | left/right | aim launcher |
| A | `b` | shoot / confirm menu / (hold) fine aim |
| B | `y` | confirm menu (alt) |
| C | `a` | toggle ball numbers |

Rules: aim, drop a marble; two marbles of the same color **merge** into the
next color; merging the last color triggers a **bomb** (victory outside
endless). Keeping too many marbles on the table **drains the life bar** — let
it hit zero and you lose (except ENDLESS, which has no life budget). Bouncing
a marble off a wall raises its combo multiplier.

## FPS / pacing

`_update()` (no `_update60`) → the compiler enables `gt_p8_fps30()`, so the
game runs the PICO-8 30 fps contract with constants rescaled ×2 where noted
in the source. Target pacing is 2.0 vsyncs per game frame (an honest 30 fps
on a 60 Hz field). Measure at runtime from `_gt_ticks` (0x2AE) and
`_gt_time_acc` (0x204): `vsyncs_per_frame = ticks / ((time_acc/1092)/2)`.
