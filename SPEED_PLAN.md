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

## Real-game breakdown: newleste level 1 (measured 2026-07-03)

The microbenches told us primitive COST; a real port tells us where the frame
actually GOES. Measured on newleste (a Celeste-classic port), fps30, delta
protocol over 600 vsyncs, by stubbing pieces of the frame:

| Configuration                                  | vsyncs/frame |
|------------------------------------------------|:------------:|
| Baseline (per-tile spr map loop)               |   **10.91**  |
| bg blit (gt.bg_draw) + all entities            |    **9.75**  |
| bg blit + player only                          |    **5.88**  |
| bg blit only (update still running)            |    **4.98**  |

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
heavy games — but they do NOT move these ports' pacing. The REAL remaining
lever is cc65 codegen of the game's own update logic: zp temporaries + hot
loop counters in the emitter (the original stage-5 idea), pool-iteration
codegen, and 16-bit-coordinate paths. That is the true next sprint.

### 6. Banked audio done right (P1) + string pool (P2)
gt_audio_init switches to the firmware's bank before the ARAM upload
(mirroring the sheet loader), bank chosen by the CLI via -DGT_FW_BANK.
Every banked port gets its sound back. Audibility (recorded WAV, rms > 0)
is the acceptance test, not a clean link. emit.js appends the tail
rodata-name pragma so print() literals stop overflowing the fixed bank.

### 7. Rebuild the six ports untouched and publish the before/after table
No per-game changes allowed — that's the whole point. Cherry Bomb combat
is the acceptance benchmark.

## Explicitly out of scope (for now)
- Emitting 6502 directly from our compiler (own code generator). The
  biggest possible win but weeks of work; stages 2-5 recover most of the
  gap by making the runtime native-cost like PICO-8's.
- Reducing entity counts or any visual change: forbidden.
