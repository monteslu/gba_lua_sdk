# SPEED_PLAN — closing the gap to PICO-8 performance

Goal: games written in plain gtlua run at locked 30fps (2.0 vsyncs/frame)
**without per-game tuning**. PICO-8 gets there because its primitives are
hand-tuned native code; ours go through cc65's C ABI. The fix is the same
architecture PICO-8 uses: slow language on top, native-speed runtime below.

## Measured facts (from the six real ports)

- Cherry Bomb, 32 enemies, draw fully stubbed: **3.2 vsyncs of pure update**
  → ~6,000 cycles per enemy for simple move/animate logic. A hand count of
  the same math is ~300-600 cycles. The overhead is cc65 codegen + runtime
  calls, not the game.
- Draw side adds ~9 vsyncs in combat: per-primitive call cost ~500-2000
  cycles regardless of pixels (C-stack arg pushes, clip math through cc65,
  spin-wait on the blitter per call).
- Proven fix instance: batching the 100-star parallax field into one tight
  C loop took it from ~1 vsync to unmeasurable.
- Budget: 6502 @ 3.58 MHz, ~59.7K cycles/vsync, 30fps frame = ~119K cycles.

## Microbench baseline (measured 2026-07-03, delta protocol over 600 vsyncs)

Empty game = exactly 2.00 vsyncs/frame (locked 30fps), so every number
below is pure cost of the op under test. Cycles/call = extra vsyncs x
59,659 / N.

| op                        | cycles/call | native target |
|---------------------------|------------:|--------------:|
| `spr(n,x,y)`              |         932 |   ~100 (enqueue) |
| `rectfill(x1,y1,x2,y2,c)` |       1,864 |   ~100 (enqueue) |
| `pset(x,y,c)`             |         699 |   ~60 |
| `circfill(x,y,4,c)`       |      13,050 |   ~700 (9 enqueues) |
| `btn(i)`                  |         233 |    ~10 (inline bit test) |
| `acc = acc + f * g` (16.16)|      8,485 |   ~400 |

The headline: **one fixed-point multiply-add statement costs 8.5K cycles**
through cc65's long runtime — the update-path killer that explains Cherry
Bomb's 6K-cycles-per-enemy floor. The draw path's per-call costs match the
port measurements. Both paths get attacked; neither alone is enough.

## AFTER (same microbenches, stages 1-4 landed: 1a2d747/20d81ef/5fdeaab)

| op                        | before | after | note |
|---------------------------|-------:|------:|------|
| `spr(n,x,y)` x64/frame    |    932 | **~free** | spr64 locks at 2.00 vsyncs/frame (asm spr_z) |
| `btn(i)` x256/frame       |    233 | **~free** | btn256 locks at 2.00 (inline zp bit test) |
| `rectfill(...)`           |  1,864 |   932 | argless fill_clipped_z, staging + asm push |
| `pset(x,y,c)`             |    699 |   466 | zp ABI (C body remains) |
| `circfill(x,y,4,c)`       | 13,050 | 9,283 | spans through fill_clipped_z |
| `acc = acc + f * g`       |  8,485 | 2,795 | asm gt_fmul (remaining = cc65 long marshalling) |

Stability: 18,000-frame soak clean; orbit + real-sheet sprite scenes render
pixel-correct (transparency, edge clips, camera).

Big lesson from the bring-up: the "queue crashes" that ate half the sprint
were artifacts — benches were being rebuilt against a parallel agent's
half-written gt_fmul while it worked in the same tree, and post-crash reads
used zp addresses its scratch had shifted. Never debug against a moving
tree; pin addresses per build from the .lbl.

## The honest per-cart CEILING — update floors (2026-07-03, third pass)

The update floor (pace with `_draw` stubbed to `cls()`, IN GAMEPLAY) is the max
fps a cart can EVER reach, since physics runs every frame no matter how cheap the
draw. This reframes everything — some carts are physics-capped below 30 and no
draw work will fix them:

| cart | update floor | MAX fps | current | draw-fixable to 30? |
|---|---:|---:|---:|:--:|
| just-one-boss | 2.0 | **30** | 8.6 | YES — pure draw headroom |
| combo-pool | 2.0 | **30** | 14 | YES |
| driftmania | 3.0 | ~20 | 6 | capped at 20 |
| celeste2 (gameplay) | 3.2 | ~19 | 8.5 | capped at 19 |
| newleste | 5.0 | **~12** | 5.6 | NO — physics-bound, 12fps ceiling |

⚠ MEASURE THE RIGHT SCREEN. Several carts boot to a title/menu (celeste2
level_index 0, combo-pool mainmenu). A load-and-settle harness paces THAT, not
gameplay — and a title (logo + particles) is nothing like a level (tilemap +
entities + physics). celeste2's title paced 5.0 / its gameplay 7.1; its title
update-floor is 2.0 / its gameplay floor 3.2. Drive into a level and confirm the
state var before trusting any number. Earlier this session I optimized celeste2's
snow against title-screen paces — the win held in gameplay (14.6→7.1) only because
gameplay runs the same snow, but the attribution was luck, not method.

RIGHT TARGETS for reaching locked 30fps: just-one-boss and combo-pool (2.0 floor,
draw-bound). newleste is a lost cause for 30fps (5.0 physics floor); best it can
do is ~12. celeste2/driftmania cap at ~19-20 (need physics cuts, not draw).

## Blit-count is the draw bottleneck — profiled 2026-07-03 (second pass)

A full re-profile of all nine carts nailed down the draw-side cost model:

- **Draw cost tracks blit COUNT, not pixel area.** Measured: 64× 1×1, 64× 8×8,
  and 64× 16×16 fills all pace IDENTICALLY (4.0 vsyncs); 1× 64×64 = 2.0. A blit
  is a fixed per-primitive CPU cost; the blitter's own W*H drain is negligible
  at sprite sizes (an 8×8 drains in 64 cycles).
- **Per-frame blit budget @ 30fps (2.0 vsyncs):** sprites ~**68**, rectfills
  ~**37** (was ~33 before the fill fast-path). Sprites are ~2× cheaper than the
  C fill path per call — the asm `_gt_p8_spr_z` staging vs the two nested cc65 C
  calls (`rectfill_z`→`fill_clipped_z`).
- **circfill/circ are blit-count bound by nature:** a radius-r filled circle is
  ~2r scanline blits, so ~3 medium circles already blow the budget. No per-call
  optimization fixes that — only fewer blits (e.g. a pre-rendered circle sprite)
  would, which is a game-authoring choice.

SHIPPED win (commit a397fed, SDK-level, no game changes, no visual change): a
fast-path in fill_clipped_z for on-screen ordered non-128 rects + a lean
hspan_raw for circle scanlines. Result: celeste-like 4.0→3.0, jelpi 4.9→4.0,
newleste 11.11→10.71, driftmania 10.17→10.08. Sprite-bound carts unchanged.

⚠ MEASUREMENT CAUTION (a bug I hit and caught): when stubbing `_draw` to
isolate update cost, a regex that grabbed the wrong `end` ALSO truncated
`_update`, giving a bogus "2.0 vsyncs, update is free" reading. The CORRECT
isolation (verified `_update` still 56 lines) gives **5.0 vsyncs** — see the
table below. Always re-check the stubbed source actually kept the other half.

## Real-game breakdown: newleste level 1 (measured 2026-07-03)

The microbenches told us primitive COST; a real port tells us where the frame
actually GOES. Measured on newleste (a Celeste-classic port), fps30, delta
protocol over 600 vsyncs, by stubbing pieces of the frame:

| Configuration                                  | vsyncs/frame |
|------------------------------------------------|:------------:|
| Baseline (per-tile spr map loop)               |   **10.91**  |
| + fill fast-path (a397fed), full game          |   **10.71**  |
| _update intact, _draw stubbed to cls()         |    **5.00**  |
| bg blit (gt.bg_draw) + all entities            |    **9.75**  |
| bg blit + player only                          |    **5.88**  |
| bg blit only (update still running)            |    **4.98**  |

**The frame is ~half update, ~half draw** (5.0 update + ~5.7 draw = 10.7). Both
are ~5-vsync levers. The draw half is blit-count (batch/cut sprites, bg_compose
static layers); the update half is the 16.16 fixed-point physics floor spread
across p_update/p_move/update_* — no single hot function, inherent to Celeste-
scale physics on a 6.7 MHz 6502.

- **Tilemap draw -> one big GRAM blit: ~1.15 vsyncs saved.** The new
  gt.bg_compose/gt.bg_draw path works and helps — but the map was only ~11%
  of the frame. It was never the bottleneck.
- **Non-player entity draw (particles, clouds, collectibles, HUD): ~3.9
  vsyncs — the single biggest chunk.** At ~1193 cycles of SETUP per blit
  regardless of size, decorative particles are what blow the ~50-blit budget.
- **_update physics: ~5 vsyncs floor** (fixed-point PICO-8 physics on 65C02).

RANKED levers now: (1) cut/batch decorative sprites — needs source changes,
so it's the #1 topic for the GameTank-idiomatic patterns guide (also:
pre-compose static pickups into the bg page); (2) cheaper _update (leaf
inlining + integer-where-PICO8-used-fixed); (3) native map() batching is now
secondary — bg_compose already handles single-screen levels.

### gt.bg_compose / gt.bg_draw (SHIPPED)

The GameTank has 512 KB GRAM = 32 pages of 128x128; the stock SDK uses only
page 0 (the sheet). gt.bg_compose(map, cols, cx, cy, cw, ch) CPU-paints a
tilemap window into a spare GRAM page (group 1) ONCE per level load (clears to
color 0, skips tile 0); gt.bg_draw([sx],[sy]) blits that whole page in one
cheap blit per frame. FLASH2M: bin/gtlua.js recompiles gt_bg.c with -DGT_BANKED
-DGT_SHEET_BANK=2 so compose maps the sheet's bank; it restores the caller's
bank after (gt_cur_bank, C-visible via the _gt_cur_bank alias). See
gt_bg.c for the blitter-state discipline (compose/draw both hand the blitter
back in the same state a normal queued frame runs under, or all later blits
render black — the bug that cost a debugging session).

## The plan (in order, each measured against a microbenchmark)

### 1. Microbench baseline
ROM that does N of each primitive + N fixed-mul per frame; read
_gt_ticks/_gt_time_acc → exact cycles/call. Re-run after every stage.

### 2. zp-arg fastcall ABI for primitives
The emitter controls every call site, so stop using the C stack: write args
to fixed zero-page slots (sta zp, ~3 cycles/byte) and jsr. Kills the
dominant per-call cost. btn()/btnp() become inline bit tests against a
per-frame pad cache — no call at all.

### 3. Async blit queue drained by the blitter IRQ
Primitives stop programming + spin-waiting the blitter. They append an
8-byte descriptor to a ring buffer and return; the IRQ handler programs the
next blit the moment the previous one finishes. Draw overlaps game logic
completely — the CPU cost of drawing collapses to enqueue cost (~40
cycles/blit). Flush points: any CPU-mode VRAM op, frame end (existing
dummy-VDMA-read emulator fix preserved).

### 4. Hand-asm 16.16 core
gt_fmul (4 partial products through cc65 long math) and gt_fdiv become
tuned 65C02 asm with the same zp ABI. Exact P8 semantics preserved
(mathcheck's RAM-verified cases are the gate).

### 5. zp fastcall ABI for the fixed hot ops + a table multiply

CORRECTED FINDING (measured 2026-07-03, fmul64/fmul_only benches at 6000
vsyncs): the ~1000-cycle "cc65 cdecl marshalling" this plan blamed for the
2,795-cycle multiply-add **does not exist** at this granularity. A forced-
cdecl build and a zp-fastcall build measure IDENTICALLY (4.9988 vs 4.9988
vsyncs/frame). The entire 2,795 cycles is the 32-iteration shift-add loop in
gt_fmul itself. `acc = f*g` (no accumulate) costs the same as `acc = acc + f*g`
— the accumulate and the marshalling are both noise next to the multiply core.

So stage 5 splits:
 (a) zp fastcall ABI for gt_fmul/gt_fdiv — DONE. The emitter stores operands
     into zp longs fa/fb and calls argless gt_fmul_zp/gt_fdiv_zp; nested/mixed
     sites (an operand that itself emits a fixed mul/div, ~rare) fall back to
     cdecl gt_fmul/gt_fdiv so fa/fb can't collide. Buys ~0 on fmul (proven)
     but it's the plumbing the fast multiply reads, and it de-marshals fdiv.
     Verified bit-exact (mathcheck RAM values + closed-form test, 45/45).
 (b) Quarter-square TABLE multiply (a*b = f(a+b)-f(a-b), f(x)=x²/4). Three
     tiers by operand magnitude: A (both |v|<1.0, 4 partials) 3.0x, B (both
     |v|<256, 9 partials) 1.5x, C (full 32x32) parity. 1 KB RODATA (two 512B
     tables sqlo/sqhi). Bit-exact: ~113M-vector JS-model-vs-reference (0 fail)
     + mathcheck RAM values + a 130-vector 3-tier checksum on hardware. The
     +1 KB overflowed the FULL FLASH2M fixed bank, so cold gt_math.c (sin/cos/
     atan2/rnd + its 1 KB sine table) was relocated to bank 1 via fixed-bank
     far-call stubs (net +1920 B reclaimed); all 6 ports link + render.
     MEASURED on fmul benches: A 4.9988->2.9993, B ->3.9990 vsyncs/frame.

SECOND CORRECTED FINDING — the multiply is NOT the real-port bottleneck.
After shipping (b), newleste (13 fmul, the most physics-heavy port) measured
11.76 vsyncs/frame in gameplay vs 11.5 before — UNCHANGED (noise). A game does
a HANDFUL of multiplies amid hundreds of other ops per frame; the 64-mul/frame
microbench massively over-represented it. newleste's ~700K-cycle frame is
dominated by cc65-compiled UPDATE LOGIC (pool scans, 16-bit coordinate math,
collision, the draw queue), not fixed multiplies. So the table multiply + zp
ABI are a genuine, verified 1.5-3x on multiply-DENSE code and cost nothing
(Tier C = parity, empty bench still 2.00) — worth keeping for future physics-
heavy games — but they do NOT move these ports' pacing.

### zp-globals codegen: TRIED, ZERO EFFECT (2026-07-03)

The long-assumed "next lever" — hot update-logic variables into zero page —
was BUILT and MEASURED, and it does nothing. The emitter ranked scalar globals
by reference count and placed the busiest ~40 bytes in the ZEROPAGE segment
(verified working: `_gtl_px` landed at $0054, real zp addressing). newleste
paced **11.11 vsyncs/frame with AND without it — identical.** Why: `-Osr`
already keeps hot LOCALS in the zp regbank, and `--static-locals` already keeps
globals out of the software stack (absolute BSS, not `(sp),y`). Promoting a
global from absolute to zp saves ~1 cycle + 1 byte per access — real, but lost
in the noise of a ~660K-cycle frame whose cost is fixed-point CALL overhead and
blit dispatch, not global-load cycles. Reverted; do not re-attempt without a
profile showing global loads are actually hot. The measured levers that DO move
the frame are entity-draw batching (~3.9 vsyncs of per-sprite blits) and a
cheaper fixed-point call path — NOT addressing-mode micro-opts.

### ACP music-sequencer offload: PREMISE DISPROVEN (2026-07-03)

The audit's highest-ceiling perf idea — move the per-frame music sequencer off
the main 6502 onto the idle audio coprocessor — rests on the premise that music
sequencing is a meaningful main-CPU cost. It isn't. A busy update loop paces
**4.00 vsyncs/frame with music ON and 4.00 with music OFF — identical.**
`gt_music_tick` (envelope advance + song step) is invisible against blit
dispatch and fixed-point call overhead. Writing a custom self-sequencing ACP
firmware — high risk, could regress the just-shipped FM audio — to offload a
free tick buys nothing. NOT attempted. This is the THIRD audit-predicted lever
(multiply, zp-globals, ACP-offload) that measured to exactly zero; the frame is
blit-dispatch + fixed-point-CALL bound, full stop. Any future perf work must
start from a profile of THOSE two, not from CPU-side micro-optimizations.

### 6. Banked audio done right (P1) + string pool (P2)
gt_audio_init switches to the firmware's bank before the ARAM upload
(mirroring the sheet loader), bank chosen by the CLI via -DGT_FW_BANK.
Every banked port gets its sound back. Audibility (recorded WAV, rms > 0)
is the acceptance test, not a clean link. emit.js appends the tail
rodata-name pragma so print() literals stop overflowing the fixed bank.

### 7. Rebuild the six ports untouched and publish the before/after table
No per-game changes allowed — that's the whole point. Cherry Bomb combat
is the acceptance benchmark.

## NEXT SPRINT: the codegen program — make the transpiler emit tighter 6502

THE CASE (measured 2026-07-04): update floors cluster at ~3.0 vsyncs across
four carts = ~60k cycles/frame of compiled game logic each; the asm sprite
path budgets 1.8x the compiled fill path for comparable work. The cc65 tax is
NOT addressing modes (zp-globals measured zero) — it is:
  (a) 16-bit-everything arithmetic where values fit in a byte,
  (b) the cdecl software-stack call convention on per-frame functions,
  (c) expression traffic through the A/X primary register + runtime compares.
Ranked tracks, measure-first on the update floors:

### C1. 8-bit narrowing pass (biggest, hardest)
Range analysis in the checker: loop bounds, `& mask` results, constants,
array sizes, and 8.8-style scaled values prove many locals/globals/pool
fields fit signed/unsigned char. Emit char types; cc65 char ops are roughly
half the cost of int. MUST respect PICO-8 16-bit wrap semantics — narrow only
on proven ranges, never on inference vibes. Prototype on loop counters (the
`for i` induction var with constant bounds is trivially provable) and
measure before widening scope.

### C2. Peephole pass over the generated .s (safest, incremental)
gtlua already post-reads cc65 output for sizes; add a pattern-rewriter for
the classic cc65 misses (redundant lda after sta, 16-bit ops on known-zero
high bytes, jsr/rts -> jmp tails, push/pop pairs). Every game benefits with
zero source or emitter semantics changes. Validate: byte-identical
framebuffer on the example carts + the movement traces.

### C3. zp-fastcall for hot user functions (proven pattern, small-medium)
The draw builtins' gt_a0..a5 zp ABI already dodges cdecl (that's why spr is
cheap). The emitter controls both definition and every call site of user
functions — pass the first 2-3 int args of NON-RECURSIVE hot functions in zp
slots. p_check_solid/appr-class callees are called 5-10x/frame everywhere.

### C0 FIRST — the ceiling probe
Before building any of it: hand-asm ONE hot compiled function (celeste2
box_solid or newleste p_is_flag), measure the per-call delta with the
amplifier. That number bounds what perfect codegen buys and calibrates how
much of each floor is cc65 tax vs inherent work. If the probe says 2x,
the program is worth weeks; if 1.2x, stop at C2.

HONEST EXPECTATION: floors 3.0 -> ~2.4-2.6 (logic ~2x) puts several carts
near 20-25fps and future designed-for-GameTank games comfortably at 30-60.
It does NOT make 24-enemy PICO-8 ports hit 30 by itself — entity volume and
blit count still rule (see the cart ceilings above).

## Explicitly out of scope (for now)
- Emitting 6502 directly from our compiler (own code generator). The
  biggest possible win but weeks of work; stages 2-5 recover most of the
  gap by making the runtime native-cost like PICO-8's.
- Reducing entity counts or any visual change: forbidden.
