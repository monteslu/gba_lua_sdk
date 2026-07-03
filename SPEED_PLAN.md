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

### 5. zp temporaries in the emitter
Compiler temps + hot loop counters move from BSS to a zero-page pool:
faster and smaller code on every 32-bit op (smaller also helps banking).

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
