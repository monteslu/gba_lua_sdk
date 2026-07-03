# Just One Boss — GameTank / gtlua port notes

A port of **"Just One Boss"** by *bridgs* (ayla nonsense) —
<https://www.lexaloffle.com/bbs/?tid=30767>, original PICO-8 cart, licensed
CC-BY-NC-SA 4.0. This adaptation is released under the same license (see
`LICENSE`). Real game logic, the real sprite sheet, and transcribed tracker
data were carried over; the parts that could not fit the 3-bank FLASH2M code
budget are listed under **Deferred content** below.

The single-file gtlua source is assembled from `src/game.lua` + generated data
(`gen/`) + `src/draw.lua` by `tools/assemble.mjs`. It compiles to a **2 MB
FLASH2M banked cart** (`main.gtr`): 3 game banks (bank0=update path,
bank1=draw/init path, bank2=data) plus the always-visible FIXED bank that
holds the gtlua runtime.

---

## 1. The core translation problem: closures → numeric state machines

The original is written on three gtlua-incompatible pillars:

1. **Closures + upvalues** — every entity is a table of closures capturing
   local state (`self`, timers, target coordinates).
2. **Per-entity method tables** — `entity.update`, `entity.draw`, dispatched
   through a polymorphic `render_layer`/`update` sweep.
3. **A promise/timeline library** — attacks are authored as
   `promise:then(...):then(...):wait(30):then(...)` chains that suspend and
   resume across frames (effectively coroutines).

gtlua has **none** of these by design (no closures, no metatables, no
coroutines, no varargs, no `nil`). So every suspending promise chain is
re-expressed as a flat **(action, step, wait) state machine** driven once per
frame. The mechanical rule used throughout:

```
promise chain                          state machine
-----------------------------------    ------------------------------------
do A; wait(30); do B; wait(10); do C   if A==THIS then
                                          if    S==0 then <A>; W=30; S=1
                                          elseif S==1 then <B>; W=10; S=2
                                          else               <C>; A=NONE
                                          end
                                        end
   ...where each frame:  if W>0 then W-=1 return end   (the wait())
```

State lives in **parallel top-level `array`s indexed by actor**, never in a
per-entity table (gtlua arrays are 1-based, RAM-only, fixed-size — see §4).

### The machine set (what replaced which closures)

| Machine | Arrays | Replaces (original) | Notes |
|---|---|---|---|
| **Rotation** (per mirror) | `rA/rS/rW/rN` | the boss's top-level `co_main` promise that sequences a phase's attacks + the phase-change cinematics | actions `R_INTRO`, `R_P1`, `R_P23`, `R_REEL`, `R_CHG1` |
| **Sub-action** (per mirror) | `sA/sS/sW/sN` + params `sCol/sSweep/sCount/sTgt/sXtra` | one attack's own promise chain (`cards()`, `ready()`, `reel()`) | actions `S_READY`, `S_CARDS`, `S_CARDS_L`, `S_CARDS_R`, `S_REEL` |
| **Hand** (per actor) | `hA/hS/hW/hRow/hFirst` | each hand entity's behavior closure | actions `H_CARDS`, `H_TEMPLE`, `H_FLOURISH` |
| **Movement** (per actor) | `mvon/mvf/mvdur/mvez/mx0..my3` | the entity `move()` / `apply_velocity` cubic-bezier tween | `mv_to`/`mv_to_d` seed the control points; `mv_step` samples one frame |
| **Victory** cinematic | `vA/vW` | the win promise | `start_victory` → curtain + score screen |
| **Death** cinematic | `dA/dW` | the death promise (+ "figment" ghost) | compacted to `start_death` (see Deferred) |
| **Start-game** staging | `sg_step/sg_wait/sg_phase` | the level-load promise | curtain open → spawn player + boss |

Easing (`ease(kind,p)`, kinds `E_LIN/E_IN/E_OUT/E_OUTIN`) and the cubic bezier
(`bez`) are copied verbatim, so **frame counts and motion curves match the
original at 30 fps** — the timing/feel of what shipped is faithful, not
approximated.

### Pattern-by-pattern mapping of the shipped attacks

**Ready pose (`S_READY`)** — original `ready(n)` promise: set the idle pose,
raise both hands, wait, flash the "about to attack" expression. Machine:
`sS 0→1` raises hands (`hand_appear`) + `set_idle`; `sN[b]` carries the beat
count; the per-step waits are the original's `wait()` values.

**Card volley (`S_CARDS` / `S_CARDS_L` / `S_CARDS_R`)** — the signature attack.
Original: each hand runs a `throw_cards` closure that spawns a staggered fan of
`card` entities aimed at the player's row, then returns to rest. Machine:
`sub_step` step 0 calls `hand_start_cards(hand, first, row)` on one or both
hands (staggered right-then-left, mirrored for the reflection in the original);
`hand_step`'s `H_CARDS` then spawns the fan on its own timer (`spawn_card`) and
resolves when the hand's throw animation completes. The card projectile physics
(`update_cards`) — bezier in-flight arc, 4-frame flip animation, row-aimed
target — are carried over unchanged.

**Reel-on-hit (`S_REEL` / `R_REEL`)** — original: when a phase's health bar
fills, the boss recoils, all three actors shake and scatter, then the
phase-change fires. Machine: `R_REEL` cancels the current attack, makes the
boss reappear, runs `S_REEL` (the shake/scatter loop using `mv_to_d` +
`poof_at` per actor for `sN` iterations), then hands off to `R_CHG1`.

**Phase change (`R_CHG1`)** — see Deferred for what was trimmed; the shipped
version keeps the reel + an angry-expression beat before `finish_phase_change`
bumps `boss_phase` and calls `decide_next_action`.

**Intro (`R_INTRO`)** — original 15-beat reveal cinematic. Shipped: a compact
4-beat version (hands appear → cycle expressions 5,6 → top hat pops on via
`poof_at`). Same actors, same expression set (`bexpr` indices), fewer
in-between beats.

---

## 2. What's in the shipped slice

Per the task's explicit fallback ("ship the largest coherent slice — title +
boss fight through its main phases — and list what's deferred"), the cart ships
a **complete two-phase card-dodging fight**:

- **Title screen** with a hand-built **block-letter "JUST ONE / BOSS" logo**
  (`draw_title_logo` / `draw_letter`, stamped from a 3×5 bit-mask `glyph`
  array as `rectfill`s — no font sprite). Press ➡️ / 🅾️ (GT A) to start.
- **Curtain open** stage transition (`draw_curtains` / `update_curtains`).
- **The boss reveal cinematic** (`R_INTRO`): hands rise, the mirror cycles its
  expressions, the top hat pops on in a puff.
- **Player**: tile-to-tile hopping on the grid (`update_player`, bezier hop,
  teeter-on-edge, stun/invincibility flash, 4 hearts).
- **Magic tiles**: the sparkling pickup tiles spawn, you hop onto them to fill
  the boss bar (`update_tiles`, `collect_tile`, the health-streak comets that
  fly to the bar in `update_parts`).
- **Phase 1** (`R_P1`): staggered left-hand then right-hand **card volleys**.
- **Phase transition** (`R_REEL` → `R_CHG1`): the boss reels, shakes, and
  changes.
- **Phase 2** (`R_P23`): a faster **double-handed card barrage**.
- **Boss health bar** with the rainbow-flash on fill; **player hearts** + score
  + timer HUD.
- **Win / lose screens**: fill the bar in phase 2 → victory (`start_victory`,
  score shown); run out of hearts → defeat screen with retry.
- Deterministic **camera shake** on hits (`freeze_shake`).
- Particle **bursts** on tile pickup and the **poof** smoke on
  appear/reel/hat.

The whole fight loop the original is famous for — *dodge the projectiles while
stepping on tiles to damage the boss, survive the phase change, finish it* — is
present and plays end to end.

---

## 3. Deferred content (every divergence from the cart)

All of these were cut **only** to fit the 3-bank FLASH2M code budget (see §5),
in rough order of how much budget they freed. Nothing was cut for difficulty —
each was translated and working at some point; the fight simply exceeds one
cart.

| Deferred | Original behavior | Why | How to restore |
|---|---|---|---|
| **Phases 3 & 4** | the cart escalates to 4 phases incl. the green-mirror reflection duel | code budget | `decide_next_action` handles phases 1–2 only; `health_arrive` routes phase 2 → victory. Re-add `R_P4`/`R_CHG2`/`R_CHG3` + phase-3/4 rotation bodies. |
| **Green mirror** (reflection boss) | a second mirror that mirrors your moves in phase 4 | budget | actor slots `GB/GLH/GRH` + the `R_G*` schedule + `S_CAST` still reserved but unimplemented. |
| **Player reflection** | your character's mirrored twin | budget | `ref_on`/`rprev_*` state kept; `draw_player` reflection branch removed. |
| **Laser attack** (`S_LASERS`) | charge-then-sweep beams | budget | the biggest single attack; `S_LASERS`/`R_*LASERS` enum kept, body removed. |
| **Coin-rain attack** (`S_COINS`) | bouncing coins to dodge | budget | enum kept; body + `coins` pool removed. |
| **Conjure / flower field** (`S_CONJ`) | the mirror plants a field of blooming flowers you must weave through | budget | `S_CONJ` no-ops; `conjure_spawn`/`bloom_flowers`/`flowers` pool removed. |
| **Fist-pound attack** (`S_POUND`/`H_POUND`) | hands slam the grid | budget | `H_POUND` enum + `hand_start_pound` removed. |
| **Background music** | full tracker song | budget (the sfx note tables were the single biggest generated-C cost) | `USED_ROWS=[]` in `tools/mkmusic.mjs`; row sequencer removed. |
| **All sound** (final cut) | interactive one-shots (card throw, hurt, tile, menu) over the gt.note sequencer | budget — the last ~2.5 KB needed to make the banker converge | The **~30 `jb_sfx()`/`music_*()` call sites were left in place at their original beats**; the helpers + `update_audio` are no-ops. Un-stub those four functions and restore `GAME_SFX` in `tools/mkmusic.mjs` to bring sound back. This is the single most-restorable cut. |
| **Bouquet-offering cinematic** | the phase-1→2 change had the boss offer a bouquet, then three fist-pounds | budget | `R_CHG1` trimmed to reel + expression beat; `bbouq`/`g_bouquet` removed. |
| **Screen bezier slides** | title/win/lose screens slide in/out over 100 frames | budget | screens appear/leave in place; `scr_slide` kept as a leave flag. |
| **Floating score popups** | "×N" combo popups | budget | `points` pool + `print_pts` removed; score still accrues. |
| **Score-multiplier HUD** | on-screen ×N combo meter | budget | `score_mult` still drives scoring; the icon draw removed. |
| **Heart pickups** | dropped hearts you can grab mid-fight | budget | `hearts` pool + `update_hearts_pool` removed. |
| **Game-over "figment" ghost** | your ghost drifts to center on death | budget | folded into a compact `start_death` (curtain + screen). |
| **Grayscale sprite variants** | reflection/green tint uses a 2nd palette bank | budget (sheet space) | `SLICE_NO_GRAY` in `tools/mkgfx.mjs` skips the `gr==1` sprite set. |

The `R_*`/`S_*`/`H_*` enum values for the deferred attacks are **left defined**
so the state-machine shape is complete and restoring an attack is "fill in the
branch," not "re-architect."

---

## 4. gtlua dialect walls hit during the port (for future porters)

Concrete things that broke and the fix, beyond the closure→machine rewrite:

- **No `nil`, no `x or default`** — every field must be initialized; option
  defaults become explicit `if`.
- **No boolean returns / no `not x`** — helpers like `hands_busy`, `sub_busy`,
  `try_step`, `coin_die` return `0/1` and are tested `== 0` / `~= 0`. A bare
  `if x then` where `x` is numeric is illegal; must be `if x ~= 0 then`.
- **Pools: fields are frozen by the FIRST `add()`** and are only accessible
  inside `for e in all(pool)`. Every `add()` for a pool must list the **exact
  same field set** (a struct literal), and you cannot read `pool[i].field`
  outside the iterator. Pool cap ≤ 64.
- **`array(N)` is 1-based, top-level, RAM-only, ≤4096, and cannot be
  ROM-initialized** — you can give a scalar fill (`array(6, 0.0)`) but not a
  table of distinct constants. This forced the sprite/glyph data to be
  **generated as `if`-ladder dispatch functions** (`gen/*.lua`) rather than
  data tables — see §5's note on where the RODATA actually comes from.
- **`spr` has no flip and `pal` is 2-arg only (no `palt`)** — every mirrored or
  transparent-keyed sprite had to be baked as a distinct entry in the sheet
  generator, or drawn from primitives.
- **`print` takes a literal or a number, not a concatenation** — no
  `print("score "..n)`; the label and the value are two separate `print`
  calls, which is why the HUD/screens split them.
- **Conditions must be explicit comparisons** and one-line `if (c) stmt` has no
  `then`/`end`.

---

## 5. SDK gap report (prioritized)

> The richest gap report intended for the gtlua/GameTank SDK team. Everything
> here is a real wall hit shipping a real, dense game — ranked by how much it
> cost this port.

### GAP 1 — **3-bank FLASH2M tops out around ~40 KB of game code, and it is
### the *fixed* bank, not the game banks, that overflows.**

This dominated the entire back half of the port. The symptom is a
`FLASH2M bank placement failed: CODE/RODATA/VECTORS over by N` even when **all
three game banks (bank0/1/2) fit comfortably under their margins.** The binding
constraint is the **FIXED bank** (16 KB), which must hold, all together:

- the whole gtlua runtime CODE (~13 KB — non-negotiable),
- the runtime **RODATA** (`gt_math.o` ≈ 1024 B trig/math tables + `gt_api.o` ≈
  498 B — *always linked*, identical to a working reference build),
- every **cross-bank call stub** (a trampoline per bank-crossing call; this port
  generated ~30 stubs ≈ 1.2 KB), and
- any function the banker classifies as reachable from **both** the update and
  the draw/init roots (it must live in the always-visible fixed bank).

So the real game-code ceiling is `16 KB − runtime − RODATA − stubs`, which for a
draw-heavy game is only ~1 KB of headroom. **The stubs are the hidden killer**:
adding a shared helper called from both paths, or an attack that calls a draw-ish
helper, silently grows the fixed bank and can flip a converging build to failing.

Observed dynamics worth documenting for users:
- The banker's `over by N` shrinks **non-linearly** as you cut content — cutting
  5 KB of game code moved the fixed overflow by only ~5 KB across several cuts,
  because the banker re-shuffles CODE between banks each attempt and the fixed
  dump is whatever it couldn't place.
- The **most effective cut was not game logic but reducing cross-bank calls**:
  deleting the (now no-op) `jb_sfx`/`music_*` *call sites* dropped the fixed
  overflow from 1410 B straight to 22 B by removing ~6 stubs — far more than the
  equivalent bytes of logic would have.
- The last few hundred bytes came from **shortening `print()` string
  literals** (they land in fixed RODATA).

**Requests, in priority order:**
1. **More game banks** (or a mode that spills game code into more than 3 banks).
   A 4th/5th 16 KB game bank would have shipped this game's full 4-phase fight
   with music. This is the #1 ask.
2. **Let RODATA (string literals, generated data) be bank-local** the way CODE
   is. String literals for menus should not compete with the trig tables in the
   fixed bank.
3. **A build report that names the fixed-bank breakdown** (runtime / stubs /
   both-reachable / RODATA) and, on failure, **names the functions dumped to
   fixed and the cross-bank edges that generated the most stubs** — so a user
   knows *what to cut* instead of bisecting content for an afternoon.
4. **A pragma / hint to pin a hot shared helper into a specific bank** (or force
   inlining) to cut a stub the user knows is on the hot path.
5. **Banker determinism / a "why did it fail" trace.** During this port the
   reported failing segment flipped between `CODE`, `RODATA`, and `VECTORS`
   across otherwise-identical inputs as the 8-attempt rebalance landed on
   different placements — confusing when you're bisecting by the error string.

### GAP 2 — **Arrays cannot be ROM-initialized with distinct constants.**
`array(N)` is RAM-only with at most a single scalar fill. Any lookup table
(sprite pixels, glyph masks, sfx note sequences, level data) must be emitted as
a generated **`if`-ladder dispatch function** instead of a `const` array. That
is (a) more code bytes than the equivalent packed data, and (b) the reason the
gfx/music are 200 KB+ of generated C. A `const`/`rodata` array form (even
write-once) would massively shrink data-heavy games. **Second-biggest ask.**

### GAP 3 — **`spr` has no horizontal/vertical flip.**
Every mirrored sprite (left vs right hand, the reflection boss) must be baked as
a separate sheet entry, doubling sheet usage for symmetric art. A flip flag on
`spr` would have saved sheet space *and* let the green-mirror reflection ship.

### GAP 4 — **`pal` is 2-arg only; no `palt` (color-key transparency).**
Forced either baking tint variants into the sheet (the grayscale set that got
cut) or drawing from primitives. A palette-remap + transparent-index API would
remove a whole class of baked-variant bloat.

### GAP 5 — **`print` cannot concatenate.**
`print("score "..n)` is illegal; you must emit the label and the value as two
calls at hand-computed x offsets. Minor, but it multiplies string-literal count
(which, per GAP 1, lands in the scarce fixed RODATA).

### GAP 6 — **No boolean values at all.**
Every predicate helper returns `0/1` and every condition is an explicit
comparison. Workable, but it's a constant translation tax porting any codebase
that returns/stores booleans, and an easy source of silent bugs
(`if hands_busy(b) then` compiles-ish but is wrong; must be `~= 0`).

---

## 6. Build & run

```
node ports/just-one-boss/tools/mkgfx.mjs       # sheet.bin + gen/gfx_gen.lua
node ports/just-one-boss/tools/mkmusic.mjs      # gen/music_gen.lua (sfx tables)
node ports/just-one-boss/tools/assemble.mjs     # -> main.lua (+ dead-strip)
node bin/gtlua.js build ports/just-one-boss/main.lua \
     --sheet ports/just-one-boss/sheet.bin       # -> main.gtr (2 MB FLASH2M)
```

Final placement: `functions fixed:0 bank0:66 bank1:32 bank2:3` — **zero game
functions in the fixed bank** (the banker found a clean split once the fixed
budget cleared).

Controls: **d-pad** hops tile to tile; **➡️ / 🅾️ (GT A)** advances menus and
retries.
