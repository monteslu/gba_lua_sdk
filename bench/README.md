# gt-lua micro-benchmark harness

Exact **main-CPU cycles per call** for every callable name in the gt-lua API,
plus a correctness unit test for each. Built to drive the "knock cycles down
across the board" optimization sweep.

## Layout

| file | what |
|------|------|
| `harness.mjs` | the measurement engine — builds a cart, runs it, reads cycle deltas |
| `catalog.mjs` | one entry per API name: setup, call, reps, and a `verify()` assertion |
| `run.mjs`     | `node bench/run.mjs [category|name …]` → the cyc/call + verify table |
| `../test/api_units.test.js` | the correctness half — one `node --test` case per entry |

## Requirements

The harness needs a **GT_PROFILE build** of the libretro core (it exports the
cycle-marker ring). Build it once:

```bash
cd ../gametank-libretro && make platform=retroemu CXXFLAGS_EXTRA=-DGT_PROFILE
```

Point elsewhere with `GT_BENCH_CORE=/path/to/gametank_libretro.js`. Release
builds (no `-DGT_PROFILE`) still export the marker functions but record nothing,
so the harness self-skips / reports NO-SAMP against them. The unit tests
auto-skip when no GT_PROFILE core is found.

## Usage

```bash
node bench/run.mjs                 # full sweep, all ~86 names
node bench/run.mjs draw            # one category
node bench/run.mjs sin cos sqrt    # specific names
node bench/run.mjs --json out.json # machine-readable (for before/after diffs)
npm test                           # runs the correctness units (+ compiler/fixed)
```

## How it measures

The emulator burns a **fixed cycle budget per frame** (~59,660 cyc/vsync) and
idle-spins in `gt_endframe`'s vsync wait when the frame's work finishes early —
so whole-frame cycle counting is useless (busy == empty always). Instead the
cart brackets the code under test with in-frame **markers**:

```lua
function _draw()
  gt.mark(1)
  for i = 1, reps do  <call>  end
  gt.mark(2)
end
```

`gt.mark(n)` writes `GT_MARK_ADDR` ($1000); the GT_PROFILE core snapshots the
cumulative cycle counter on that write. The delta between a mark-1 and its
following mark-2 is the exact cost of the bracketed code. The harness takes the
**median** over ~44 samples (70 frames) — deterministic, since the core has no
wall-clock randomness — and subtracts a baseline (an empty body, or `local q=0`
for expression form) so the reported number is the pure per-call cost.

`reps` amortizes the two `gt.mark` calls; a few names need more `frames` (heavy
GRAM ops span multiple vsyncs). Ops that exceed one vsync are flagged
`~N vsyncs — BLOCKING` because their raw number includes the blit-drain /
vsync-wait they block on (in a real game those blits overlap update logic).

## Signal honesty

Entries flagged `signal:"low"` measure little useful per-call signal — inline
state-setters (`color`, `camera`, `autocls`), GRAM/sheet writes with no cheap
in-frame pixel readback (`sset`, the `bg_*`/`track_*` canvas ops), ACP-side
audio (`note`, `sfx`), and the structural callbacks (`_init`/`_draw`/…). They
still get a perf row and a build+run smoke test; the `note` field says why.

## Notes / gotchas baked in

- A marker RAM address must be inside the linker RAM region ($0200–$1EFF);
  $1F00 is above it and its writes never reach the bus handler.
- gt-lua globals need `local x = …` at file scope (no implicit globals).
- Pool `sx`/`sy` must be 16-bit int fields — do NOT list them in the pool's
  byte-field signature string; assign an out-of-signed-byte-range value
  (e.g. 300) at `add()` so they infer as int.
