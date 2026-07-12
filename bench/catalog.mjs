// catalog.mjs — the per-function benchmark + unit-test catalog.
//
// Every callable name in the gt-lua API surface (39 globals + 45 gt.* members +
// 4 callbacks; the benchmark-only `gt.mark` is excluded) gets ONE entry here.
// Each entry drives BOTH:
//   - a perf test  (bench/run.mjs measures cycles/call via the marker harness)
//   - a unit test  (test/api_units.test.js asserts `verify(state)` after a call)
//
// Entry shape:
//   {
//     name:       display name (unique)
//     category:   "draw" | "math" | "input" | "audio" | "table" | "text" |
//                 "engine" | "bg" | "control" | "callback" | "special"
//     setup:      Lua run once in _init (declare locals, seed state)
//     call:       Lua expression (default) or full statement (statement:true)
//     statement:  true if `call` is a void statement (draw ops), else it's an
//                 expression assigned to `local q`
//     reps:       loop count inside the marked window (amortizes mark overhead)
//     verify:     (state) => true|string  — unit-test assertion. state = {
//                   ram: Uint8Array(0x2000), vram: Uint8Array(0x8000),
//                   px(x,y,page=0): hw color at (x,y), HW: p8 index->hw color
//                 }. Return true if correct, or a failure message string.
//                 Omit for names where a per-call output check isn't meaningful
//                 (flagged `signal:"low"`) — those still get a perf row.
//     signal:     "low" — measurement carries little useful signal (inline
//                 special forms, no-op-ish ops); reported honestly.
//     note:       one-line human note (why signal is low, caveats)
//   }
//
// The p8 index -> hardware palette color, captured from the live core (pset a
// color, read VRAM[0]). Used by verifiers to assert drawn pixels.
export const HW = {
  0: 0, 1: 169, 2: 90, 3: 219, 4: 51, 5: 3, 6: 6, 7: 7,
  8: 91, 9: 62, 10: 31, 11: 254, 12: 190, 13: 140, 14: 94, 15: 47,
};

// pixel helper: VRAM is two stacked 128x128 pages; page 0 is the front buffer
// after a flip. offset = page*16384 + y*128 + x.
const pxAt = (vram, x, y, page = 0) => vram[page * 16384 + y * 128 + x];

// ---------------------------------------------------------------------------
// DRAW OPS  (the pilot category — verified end-to-end)
// ---------------------------------------------------------------------------
const draw = [
  {
    name: "pset", category: "draw", statement: true, reps: 8,
    call: "pset(10,20,8)",
    verify: (s) => pxAt(s.vram, 10, 20) === HW[8] || `pset: (10,20)=${pxAt(s.vram, 10, 20)} want ${HW[8]}`,
  },
  {
    name: "cls", category: "draw", statement: true, reps: 2,
    call: "cls(3)",
    verify: (s) => pxAt(s.vram, 64, 64) === HW[3] || `cls: center=${pxAt(s.vram, 64, 64)} want ${HW[3]}`,
  },
  {
    name: "rectfill", category: "draw", statement: true, reps: 8,
    call: "rectfill(10,10,50,50,8)",
    verify: (s) => pxAt(s.vram, 30, 30) === HW[8] || `rectfill: (30,30)=${pxAt(s.vram, 30, 30)} want ${HW[8]}`,
  },
  {
    name: "rect", category: "draw", statement: true, reps: 8,
    call: "rect(10,10,50,50,8)",
    verify: (s) => (pxAt(s.vram, 10, 30) === HW[8] && pxAt(s.vram, 30, 30) !== HW[8]) ||
      `rect: edge=${pxAt(s.vram, 10, 30)} interior=${pxAt(s.vram, 30, 30)} (want edge ${HW[8]}, interior clear)`,
  },
  {
    name: "line", category: "draw", statement: true, reps: 8,
    call: "line(0,0,40,40,8)",
    verify: (s) => pxAt(s.vram, 20, 20) === HW[8] || `line: (20,20)=${pxAt(s.vram, 20, 20)} want ${HW[8]}`,
  },
  {
    name: "circfill", category: "draw", statement: true, reps: 8,
    call: "circfill(64,64,10,8)",
    verify: (s) => pxAt(s.vram, 64, 64) === HW[8] || `circfill: center=${pxAt(s.vram, 64, 64)} want ${HW[8]}`,
  },
  {
    name: "circ", category: "draw", statement: true, reps: 8,
    call: "circ(64,64,10,8)",
    verify: (s) => (pxAt(s.vram, 64, 64) !== HW[8]) || `circ: center should be hollow, got ${pxAt(s.vram, 64, 64)}`,
  },
  {
    name: "spr", category: "draw", statement: true, reps: 8,
    call: "spr(0,20,20)",
    // sheet cell 0 -> just assert it doesn't crash + queue drains (a sprite may
    // be all-transparent depending on the sheet); low output signal.
    signal: "low", note: "sheet-dependent pixels; verified as 'runs + queue drains'",
  },
  {
    name: "sset", category: "draw", statement: true, reps: 8,
    call: "sset(0,0,8)",
    signal: "low", note: "writes the sprite sheet in GRAM, not VRAM; no cheap in-frame readback",
  },
  {
    name: "color", category: "draw", statement: true, reps: 32,
    call: "color(8)",
    signal: "low", note: "sets the current draw color (state); no pixel output",
  },
  {
    name: "camera", category: "draw", statement: true, reps: 32,
    call: "camera(4,4)",
    signal: "low", note: "sets the camera offset (zp state); no pixel output",
  },
  {
    name: "pal", category: "draw", statement: true, reps: 16,
    call: "pal(8,12)",
    signal: "low", note: "remaps the runtime palette table; effect shows on the next draw",
  },
  {
    name: "border", category: "draw", statement: true, reps: 4,
    call: "gt.border(5)",
    signal: "low", note: "GameTank overscan border color; not in the 128x128 VRAM window",
  },
];

// ---------------------------------------------------------------------------
// MATH  (expressions; result read back from a global via resultGlobal)
// 8.8 fixed = value*256. flr/ceil/sgn return int; abs/min/max/mid return the
// arg's type; sin/cos/atan2/sqrt/rnd/t return fixed. sin is PICO-8-negated.
// ---------------------------------------------------------------------------
const R = { globals: "local res = 0", statement: true }; // result-via-global preamble
const math = [
  { name: "flr", category: "math", ...R, reps: 16, call: "res = flr(3.5)", resultGlobal: "res", verify: (s, r) => r.result === 3 || `flr(3.5)=${r.result} want 3` },
  { name: "ceil", category: "math", ...R, reps: 16, call: "res = ceil(2.1)", resultGlobal: "res", verify: (s, r) => r.result === 3 || `ceil(2.1)=${r.result} want 3` },
  // abs/sgn use a VARIABLE arg (not a constant) so the number reflects real
  // per-call cost — a constant folds away and hides the win.
  { name: "abs", category: "math", globals: "local res = 0\nlocal v = -3", statement: true, reps: 16, call: "res = abs(v)", resultGlobal: "res", verify: (s, r) => r.result === 3 || `abs(v=-3)=${r.result} want 3` },
  { name: "sgn", category: "math", globals: "local res = 0\nlocal v = -5", statement: true, reps: 16, call: "res = sgn(v)", resultGlobal: "res", verify: (s, r) => r.result === -1 || `sgn(v=-5)=${r.result} want -1` },
  { name: "min", category: "math", ...R, reps: 16, call: "res = min(5,3)", resultGlobal: "res", verify: (s, r) => r.result === 3 || `min(5,3)=${r.result} want 3` },
  { name: "max", category: "math", ...R, reps: 16, call: "res = max(5,3)", resultGlobal: "res", verify: (s, r) => r.result === 5 || `max(5,3)=${r.result} want 5` },
  { name: "mid", category: "math", ...R, reps: 16, call: "res = mid(5,3,8)", resultGlobal: "res", verify: (s, r) => r.result === 5 || `mid(5,3,8)=${r.result} want 5` },
  { name: "sqrt", category: "math", ...R, reps: 8, call: "res = sqrt(4)", resultGlobal: "res", verify: (s, r) => r.result === 512 || `sqrt(4)=${r.result} want 512 (2.0)` },
  { name: "sin", category: "math", ...R, reps: 16, call: "res = sin(0.25)", resultGlobal: "res", verify: (s, r) => r.result === -256 || `sin(0.25)=${r.result} want -256 (PICO-8 negated)` },
  { name: "cos", category: "math", ...R, reps: 16, call: "res = cos(0)", resultGlobal: "res", verify: (s, r) => r.result === 256 || `cos(0)=${r.result} want 256 (1.0)` },
  { name: "atan2", category: "math", ...R, reps: 16, call: "res = atan2(1,0)", resultGlobal: "res", verify: (s, r) => Number.isInteger(r.result) || `atan2 no result` },
  { name: "rnd", category: "math", ...R, reps: 16, call: "res = rnd(10)", resultGlobal: "res", signal: "low", note: "returns a fixed in [0,10); value varies, only cost is measured" },
  { name: "srand", category: "math", statement: true, reps: 16, call: "srand(42)", signal: "low", note: "seeds the RNG (state); no return" },
  { name: "t", category: "math", ...R, reps: 16, call: "res = t()", resultGlobal: "res", signal: "low", note: "elapsed time (fixed); grows over frames — cost only" },
  { name: "time", category: "math", ...R, reps: 16, call: "res = time()", resultGlobal: "res", signal: "low", note: "alias of t()" },
  { name: "rgb", category: "math", ...R, reps: 16, call: "res = gt.rgb(0)", resultGlobal: "res", verify: (s, r) => Number.isInteger(r.result) || `gt.rgb no result`, note: "raw GameTank palette color (0x100|byte)" },
  { name: "ticks", category: "math", ...R, reps: 16, call: "res = gt.ticks()", resultGlobal: "res", signal: "low", note: "frame tick counter; grows — cost only" },
];

// ---------------------------------------------------------------------------
// INPUT
// ---------------------------------------------------------------------------
const input = [
  { name: "btn", category: "input", ...R, reps: 16, call: "if btn(4) then res = 1 else res = 0 end", resultGlobal: "res", verify: (s, r) => r.result === 0 || `btn(4) with no input should be 0, got ${r.result}` },
  { name: "btnp", category: "input", ...R, reps: 16, call: "if btnp(4) then res = 1 else res = 0 end", resultGlobal: "res", verify: (s, r) => r.result === 0 || `btnp(4) with no input should be 0, got ${r.result}` },
];

// ---------------------------------------------------------------------------
// AUDIO  (fire-and-forget to the ACP; no cheap in-frame readback -> low signal)
// ---------------------------------------------------------------------------
const audio = [
  { name: "note", category: "audio", statement: true, reps: 8, call: "gt.note(0,60,8)", signal: "low", note: "sends a note to the ACP; no main-CPU-visible output" },
  { name: "noteoff", category: "audio", statement: true, reps: 16, call: "gt.noteoff(0)", signal: "low", note: "note-off to the ACP" },
  { name: "sfx", category: "audio", statement: true, reps: 8, call: "sfx(0,0)", signal: "low", note: "triggers a built-in SFX; ACP-side" },
  { name: "music", category: "audio", statement: true, reps: 8, call: "music(0)", signal: "low", note: "starts a music track; ACP-side" },
  { name: "sfx_bank", category: "audio", ...R, reps: 4, globals: "local bank = array8(4)", call: "sfx_bank(bank)", statement: true, signal: "low", note: "installs an SFX bank pointer (state)" },
  { name: "music_bank", category: "audio", globals: "local bank = array8(4)", call: "music_bank(bank)", statement: true, reps: 4, signal: "low", note: "installs a music bank pointer (state)" },
];

// ---------------------------------------------------------------------------
// TABLE / DATA  (constructors + list ops — mostly one-time allocs; low signal)
// ---------------------------------------------------------------------------
const table = [
  { name: "array", category: "table", statement: true, reps: 8, globals: "local a = array(8,0)\nlocal res = 0", call: "res = a[1]", resultGlobal: "res", verify: (s, r) => r.result === 0 || `array(8,0)[1]=${r.result} want 0` },
  { name: "array8", category: "table", statement: true, reps: 8, globals: "local a = array8(8)\nlocal res = 0", call: "res = a[1]", resultGlobal: "res", verify: (s, r) => r.result === 0 || `array8(8)[1]=${r.result} want 0` },
  // pool entities are field-typed; add() takes a table literal, del() takes a
  // loop var from `for e in all(pool)`. Measured as the amortized add+drain of
  // one entity (the pool re-fills each frame since del clears it).
  { name: "pool", category: "table", statement: true, reps: 2, globals: 'local p = pool(4)', call: "add(p, {x = 1})", signal: "low", note: "ctor is _init-only; add() acquires a slot (saturates at cap 4)" },
  { name: "add", category: "table", statement: true, reps: 2, globals: 'local p = pool(4)', call: "add(p, {x = 1})", signal: "low", note: "acquire a pool slot with a field-typed entity (saturates at cap)" },
  { name: "del", category: "table", statement: true, reps: 1, globals: 'local p = pool(8)', setup: "add(p, {x = 1})", call: "for e in all(p) do del(p, e) end", signal: "low", note: "release pool slots via the all() iterator" },
];

// ---------------------------------------------------------------------------
// TEXT
// ---------------------------------------------------------------------------
const text = [
  { name: "print", category: "text", statement: true, reps: 4, call: 'print("HI",8,8,7)', signal: "low", note: "CPU-mode glyph run; pixels are font-dependent, verified as runs" },
  { name: "print_buf", category: "text", globals: "local buf = array8(4)", setup: "buf[1]=8 buf[2]=5 buf[3]=0", statement: true, reps: 4, call: "gt.print_buf(buf,0,8,8,7)", signal: "low", note: "prints a byte buffer as glyphs; buffer-driven" },
  { name: "dbar", category: "text", statement: true, reps: 8, call: "gt.dbar(10,10,5,10,7,0,0)", signal: "low", note: "draws a labeled value bar (debug HUD widget)" },
];

// ---------------------------------------------------------------------------
// CONTROL / SPECIAL  (callbacks + inline forms; measured for completeness)
// ---------------------------------------------------------------------------
const special = [
  { name: "autocls", category: "special", statement: true, reps: 16, call: "gt.autocls(0)", signal: "low", note: "sets the post-flip auto-clear color (state)" },
  { name: "gflush", category: "special", statement: true, reps: 2, call: "gt.gflush()", signal: "low", note: "drains the blit queue + restores draw state; cost depends on queue depth" },
  // callbacks: not callable as expressions — measured as 'the empty-body frame
  // cost' which the baseline already captures. Flagged as structural.
  { name: "_init", category: "callback", statement: true, reps: 1, call: "", signal: "low", note: "lifecycle callback; runs once at boot, not per-frame — no per-call cost" },
  { name: "_update", category: "callback", statement: true, reps: 1, call: "", signal: "low", note: "30fps logic+draw mode callback; structural, not a call" },
  { name: "_update60", category: "callback", statement: true, reps: 1, call: "", signal: "low", note: "60fps logic callback; structural" },
  { name: "_draw", category: "callback", statement: true, reps: 1, call: "", signal: "low", note: "per-frame draw callback; structural (it's the frame body itself)" },
];

// ---------------------------------------------------------------------------
// ENGINES — the gt.* power-tools. These mutate GRAM / arrays / pools, so per-
// call PIXEL verification is impractical; they're measured for CYCLE COST and
// verified structurally (builds + reaches _draw's markers). Setup mirrors the
// real port call sites (driftmania / the ball/enemy demos). All signal:"low".
// ---------------------------------------------------------------------------
const engine = [
  // --- starfield ---
  { name: "starfield_init", category: "engine", statement: true, reps: 1, call: "gt.starfield_init(60)", signal: "low", note: "seed 60 parallax stars (one-time in real use)" },
  { name: "starfield_move", category: "engine", statement: true, reps: 8, setup: "gt.starfield_init(60)", call: "gt.starfield_move(1)", signal: "low", note: "scroll the starfield one step" },
  { name: "starfield_draw", category: "engine", statement: true, reps: 4, setup: "gt.starfield_init(60)", call: "gt.starfield_draw()", signal: "low", note: "plot all stars (CPU pokes)" },
  // --- flakes (parallax snow/particles) ---
  { name: "flakes_init", category: "engine", statement: true, reps: 1, call: "gt.flakes_init(26)", signal: "low", note: "seed 26 flakes" },
  { name: "flakes_set", category: "engine", statement: true, reps: 8, setup: "gt.flakes_init(26)", call: "gt.flakes_set(0, 10, 10, 1, 1, 256, 7)", signal: "low", note: "configure one flake" },
  { name: "flakes_mode", category: "engine", statement: true, reps: 16, setup: "gt.flakes_init(26)", call: "gt.flakes_mode(0, 2)", signal: "low", note: "set one flake's scroll mode" },
  { name: "flakes_draw", category: "engine", statement: true, reps: 4, setup: "gt.flakes_init(26)", call: "gt.flakes_draw(0, 0)", signal: "low", note: "draw all flakes (blit path)" },
  { name: "flakes_draw2", category: "engine", statement: true, reps: 4, setup: "gt.flakes_init(26)", call: "gt.flakes_draw2(0, 26, 0, 0)", signal: "low", note: "draw a flake range (blit)" },
  { name: "flakes_draw2_cpu", category: "engine", statement: true, reps: 2, setup: "gt.flakes_init(26)", call: "gt.flakes_draw2_cpu(0, 26, 0, 0)", signal: "low", note: "draw a flake range (CPU poke path)" },
  // --- offscreen canvas / bg (256x256 GRAM canvas) ---
  { name: "bg_clear", category: "bg", statement: true, reps: 1, frames: 220, call: "gt.bg_clear()", signal: "low", note: "clear the 256x256 canvas (big GRAM fill)" },
  { name: "bg_tile", category: "bg", statement: true, reps: 8, call: "gt.bg_tile(1, 16, 16)", signal: "low", note: "stamp one sheet tile into the canvas" },
  { name: "bg_compose", category: "bg", statement: true, reps: 1, frames: 220, globals: "local arena = array(256)", call: "gt.bg_compose(arena, 16, 0, 0, 16, 16)", signal: "low", note: "compose a 16x16 tile map into the canvas" },
  { name: "bg_draw", category: "bg", statement: true, reps: 1, frames: 220, setup: "gt.bg_clear()", call: "gt.bg_draw(0, 0)", signal: "low", note: "blit the canvas window to VRAM (one sync blit)" },
  { name: "bg_coln", category: "bg", statement: true, reps: 4, globals: "local colbuf = array8(16)", call: "gt.bg_coln(colbuf, 4, 4, 16)", signal: "low", note: "paint a column of tiles from a byte buffer" },
  { name: "canvas_view", category: "bg", statement: true, reps: 1, frames: 220, call: "gt.canvas_view(0, 0, 1, 128)", signal: "low", note: "blit a canvas view (opaque, height)" },
  { name: "gspr", category: "bg", statement: true, reps: 1, frames: 220, setup: "gt.bg_clear()", call: "gt.gspr(0, 0, 8, 8, 20, 20)", signal: "low", note: "blit an 8x8 region FROM the canvas to VRAM" },
  // --- track cache (driftmania) ---
  { name: "track_compose", category: "bg", statement: true, reps: 1, frames: 220, globals: "local map = array8(64)", call: "gt.track_compose(map, 8, 0, 0, 8, 8)", signal: "low", note: "compose a tile-map into the track canvas" },
  { name: "track_view", category: "bg", statement: true, reps: 1, frames: 220, setup: "gt.bg_clear()", call: "gt.track_view(0, 0)", signal: "low", note: "restore the track window with one windowed blit" },
  { name: "track_grid", category: "bg", statement: true, reps: 1, frames: 220, globals: "local grid = array(900)\nlocal ckdt = array(32)\nlocal ctiles = array(32)", call: "gt.track_grid(grid, ckdt, ctiles, 30, 0, 0, 5, 0)", signal: "low", note: "paint the 32x32 torus canvas from the packed chunk grid" },
  { name: "track_col", category: "bg", statement: true, reps: 1, frames: 220, globals: "local grid = array(900)\nlocal ckdt = array(32)\nlocal ctiles = array(32)", call: "gt.track_col(grid, ckdt, ctiles, 30, 0, 0, 5, 0)", signal: "low", note: "refresh one canvas column (incremental scroll)" },
  { name: "track_row2", category: "bg", statement: true, reps: 1, frames: 220, globals: "local grid = array(900)\nlocal ckdt = array(32)\nlocal ctiles = array(32)", call: "gt.track_row2(grid, ckdt, ctiles, 30, 0, 0, 5, 0)", signal: "low", note: "refresh one canvas row" },
  { name: "track_props", category: "bg", statement: true, reps: 2, globals: "local grid = array(900)\nlocal props = array8(48)", call: "gt.track_props(grid, props, 30, 0, 0, 5, 5)", signal: "low", note: "props-only walk (emit idx,sx,sy triples)" },
  // --- ball engine (28-body physics from the ball demo) ---
  {
    name: "balls_step", category: "engine", statement: true, reps: 1,
    globals: "local bx = array(28,0.0)\nlocal by = array(28,0.0)\nlocal bvx = array(28,0.0)\nlocal bvy = array(28,0.0)\nlocal bc = array(28)\nlocal bfl = array8(32)\nlocal bp = array8(64)",
    call: "gt.balls_step(bx, by, bvx, bvy, bc, bfl, bp, 28)",
    signal: "low", note: "28-body integrate + collision-pair build (the heavy demo core)",
  },
  {
    name: "balls_drag", category: "engine", statement: true, reps: 2,
    globals: "local bvx = array(28,0.0)\nlocal bvy = array(28,0.0)\nlocal bc = array(28)",
    call: "gt.balls_drag(bvx, bvy, bc, 28)",
    signal: "low", note: "apply drag to 28 velocities",
  },
  {
    name: "balls_draw", category: "engine", statement: true, reps: 1,
    globals: "local bx = array(28,0.0)\nlocal by = array(28,0.0)\nlocal bcell = array8(32)",
    call: "gt.balls_draw(bx, by, bcell, 28)",
    signal: "low", note: "blit 28 ball sprites",
  },
  {
    name: "parts_step", category: "engine", statement: true, reps: 2,
    globals: 'local parts = pool(24)',
    setup: "add(parts, {x = 10.0, y = 10.0, vx = 0.5, vy = 0.5})",
    call: "gt.parts_step(parts)",
    signal: "low", note: "integrate a particle pool (needs fixed x,y,vx,vy)",
  },
  {
    name: "trail_stamp", category: "engine", statement: true, reps: 1,
    globals: "local bc = array(28)\nlocal bx = array(28,0.0)\nlocal by = array(28,0.0)\nlocal tx = array8(28)\nlocal ty = array8(28)\nlocal ts = array8(7)",
    call: "gt.trail_stamp(bc, bx, by, tx, ty, ts, 28, 1)",
    signal: "low", note: "record + stamp motion trails for 28 entities",
  },
  {
    name: "cost_decay", category: "engine", ...R, reps: 2,
    globals: "local bc = array(28)\nlocal blm = array8(28)\nlocal cost = array8(7)\nlocal res = 0",
    call: "res = gt.cost_decay(bc, blm, cost, 28)",
    signal: "low", note: "decay per-entity cooldowns, return total (int result)",
  },
  {
    name: "chunks_draw", category: "engine", statement: true, reps: 1,
    globals: "local cgrid = array(900)\nlocal lut = array8(32)\nlocal lut2 = array8(32)\nlocal props = array8(48)",
    call: "gt.chunks_draw(cgrid, lut, lut2, props, 30, 0, 0, 5, 5)",
    signal: "low", note: "draw a chunk-grid window (tilemap blit walk)",
  },
  {
    name: "tiles_draw", category: "engine", statement: true, reps: 1,
    globals: "local map = array8(256)\nlocal flags = array8(256)",
    call: "gt.tiles_draw(map, flags, 16, 0, 8, 0, 8)",
    signal: "low", note: "draw a tile-map region (platformer tiles)",
  },
  { name: "chain_step_draw", category: "engine", statement: true, reps: 8, call: "gt.chain_step_draw(20, 20, 7)", signal: "low", note: "plot one chain link (CPU poke)" },
  // --- pool systems (field-typed entity pools) ---
  {
    name: "pool_move", category: "engine", statement: true, reps: 2,
    globals: 'local buls = pool(28, "spr")',
    setup: 'add(buls, {x = 10, y = 10, sx = 300, sy = -300, spr = 0})',
    call: "gt.pool_move(buls, 0)",
    signal: "low", note: "integrate a pool's x/y by sx/sy (one live entity here)",
  },
  {
    name: "pool_anim", category: "engine", statement: true, reps: 2,
    globals: 'local en = pool(40, "aniframe,anispd,maxani")',
    setup: 'add(en, {x = 0, y = 0, sx = 300, sy = -300, aniframe = 0, anispd = 2, maxani = 4})',
    call: 'gt.pool_anim(en, "aniframe", "anispd", "maxani")',
    signal: "low", note: "advance per-entity animation frames",
  },
  {
    name: "pool_edraw", category: "engine", statement: true, reps: 1,
    globals: 'local en = pool(40, "aniframe,type,flash,shake")\nlocal edesc = array8(16)',
    setup: 'add(en, {x = 20, y = 20, sx = 300, sy = -300, aniframe = 0, type = 0, flash = 0, shake = 0})',
    call: 'gt.pool_edraw(en, "aniframe", "type", "flash", "shake", edesc, 0)',
    signal: "low", note: "draw a pool of animated enemies (blit + effects)",
  },
  {
    name: "pool_sprs", category: "engine", statement: true, reps: 2,
    globals: 'local buls = pool(28, "spr")',
    setup: 'add(buls, {x = 10, y = 10, spr = 0})',
    call: 'gt.pool_sprs(buls, "spr", 0, 0)',
    signal: "low", note: "blit a pool's sprites (needs x,y only)",
  },
  {
    name: "hit_scan", category: "engine", statement: true, reps: 1,
    globals: 'local en = pool(40, "cw,ch")\nlocal buls = pool(28, "colw")\nlocal hp = array8(64)',
    setup: 'add(en, {x = 10, y = 10, sx = 300, sy = -300, cw = 8, ch = 8})\nadd(buls, {x = 10, y = 10, sx = 300, sy = -300, colw = 4})',
    call: 'gt.hit_scan(en, "cw", "ch", buls, "colw", 8, 4, hp)',
    signal: "low", note: "AABB overlap scan between two pools (asm)",
  },
];

export const CATALOG = [...draw, ...math, ...input, ...audio, ...table, ...text, ...engine, ...special];

export const CATEGORIES = ["draw", "math", "input", "audio", "table", "text", "engine", "bg", "control", "callback", "special"];
export { pxAt };
