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
# convert the port's 4bpp gfx.bin to a native .gtg once (see docs/GRAPHICS.md)
node bin/gtlua.js gfx import ports/combo-pool/gfx.bin -o ports/combo-pool/gfx.gtg
node bin/gtlua.js build ports/combo-pool/main.lua \
  --sheet ports/combo-pool/gfx.gtg --num8 \
  -o ports/combo-pool/main.gtr
```

This produces `ports/combo-pool/main.gtr` (a 2 MB FLASH2M banked image);
copy it to `~/roms/gametank/combo-pool.gtr` to run.

`--num8` is REQUIRED — the port relies on the 8.8-fixed-in-int number model
(see "num8" below); building without it changes the arithmetic and the game
mis-behaves (the life-bar cubic in particular was authored for num8 range).

### The old `build.mjs` is dead — do not use it

`ports/combo-pool/build.mjs` is a stale relic from before the SDK's banked
path could place the audio unit. It only assembles the *old* core SDK objects
(no `gt_music`/`gt_blitq`/`gt_balls`/`gt_poolmv`/`gt_canvas`/… ), so it now
fails to link (63 unresolved externals). **Ignore it.** The gaps it worked
around are all fixed (see below); the CLI `gtlua.js` build is canonical and
was what produced every deployed cart.

### Why a banked (2 MB) cart, not a flat 32 KB one

The flat 32 KB cart **does not fit**: the translated logic is ~1440 lines of
Lua and the sprite sheet alone is 8 KB, so code + data + sheet overflow the
32 KB window by ~14 KB. `gtlua.js` auto-retargets to the FLASH2M banked cart,
which is the correct target. Its automatic placement now handles the audio
unit (homed in private bank 3) and links cleanly.

---

## SDK gap report (prioritized)

**P1–P4 (banked audio placement, string-literal pool, first-class banked
build, stale-placement warning) are all RESOLVED.** They were the reasons the
old `build.mjs` existed. The SDK's banked path now homes the audio unit in a
private bank (bank 3), places the string-literal pool correctly, and does
call-graph-aware placement, so `gtlua.js build … --sheet … --num8` links a
real audio game with no hand-written `PLACEMENT` map. `build.mjs` is dead —
see "How to build" above. (Left the design detail here in git history rather
than the doc; resurrect from a prior revision if a banking regression needs
the background.)

**P5 — no per-frame division budget.** `gt_fdiv` is a ~48-step software loop
(~35K cycles, over half a vsync), so the port cannot divide per ball per
frame. Every `/` in a hot loop was reformulated as a shift-based approximate
(drag `x - x/64 - x/256` ≈ ×0.98) or precomputed into a boot-time table
(`invsq[]` for contact math, `march_off[]`/`phase_off[]` for the menu). The
life bar is the one remaining per-frame divide (`lifecost10/maxallowed10`),
kept because a precomputed `1/maxallowed10` UNDERFLOWS the 8.8 num8 model
(both `400` and its reciprocal wrap) — that wrap once framed the GRAM canvas
for corrupting the game; it was the life-bar math all along. This is inherent
to the 6502 @ 3.5 MHz, not a fixable SDK gap — but a *documented* "divide is
expensive, here are the table idioms (and the num8 range traps)" note in the
SDK docs would save the next porter the same discovery.

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
