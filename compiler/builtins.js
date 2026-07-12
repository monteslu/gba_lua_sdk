// gtlua builtin functions - the PICO-8 global API surface (v0.2 slice) plus
// the gt.* GameTank extras.
//
// Param kinds:
//   coord - pixel coordinate/radius: C int; fixed args are floored (>>16)
//   num   - 16.16 number: C long; int args are promoted (<<16)
//   int   - small integer (button index, player): C int; fixed args floored
//   color - PICO-8 color 0-15 or gt.rgb() raw; optional -> -1 sentinel
// Ret kinds: fixed | int | bool | void | same (polymorphic with args)

export const BUILTINS = {
  // ---- graphics -------------------------------------------------------------
  cls:      { params: [["color", true]], ret: "void", c: "gt_p8_cls" },
  camera:   { params: [["coord", true], ["coord", true]], ret: "void", c: "gt_p8_camera" },
  color:    { params: [["color", false]], ret: "void", c: "gt_p8_color" },
  pset:     { params: [["coord", false], ["coord", false], ["color", true]], ret: "void", c: "gt_p8_pset" },
  rect:     { params: [["coord", false], ["coord", false], ["coord", false], ["coord", false], ["color", true]], ret: "void", c: "gt_p8_rect" },
  rectfill: { params: [["coord", false], ["coord", false], ["coord", false], ["coord", false], ["color", true]], ret: "void", c: "gt_p8_rectfill" },
  circ:     { params: [["coord", false], ["coord", false], ["coord", false], ["color", true]], ret: "void", c: "gt_p8_circ" },
  circfill: { params: [["coord", false], ["coord", false], ["coord", false], ["color", true]], ret: "void", c: "gt_p8_circfill" },
  line:     { params: [["coord", false], ["coord", false], ["coord", false], ["coord", false], ["color", true]], ret: "void", c: "gt_p8_line" },
  pal:      { params: [["int", true], ["color", true]], ret: "void", c: "gt_p8_pal" },
  sset:     { params: [["coord", false], ["coord", false], ["color", true]], ret: "void", c: "gt_p8_sset" },
  spr:      { params: [["int", false], ["coord", false], ["coord", false], ["int", true], ["int", true], ["flip", true], ["flip", true]], ret: "void", c: "gt_p8_spr" },
  // native frame-table sprite: sprf(frame, x, y, [flipx], [flipy]) draws frame
  // `frame` from a .gsi table (arbitrary size/offset, any 256x256 quadrant).
  // The two flip flags pack into one arg (bit0=X, bit1=Y) for gt_gspr_frame.
  sprf:     { params: [["int", false], ["coord", false], ["coord", false], ["flip", true], ["flip", true]], ret: "void", c: "gt_gspr_frame" },

  // ---- input ---------------------------------------------------------------
  btn:      { params: [["int", false], ["int", true]], ret: "bool", c: "gt_p8_btn" },
  btnp:     { params: [["int", false], ["int", true]], ret: "bool", c: "gt_p8_btnp" },

  // ---- sound (gt_music.c) --------------------------------------------------
  // sfx(n, [ch]) - fire built-in effect n (0-7); ch omitted = auto channel.
  // music(n, [loop]) - start built-in tune n; music(-1) stops (PICO-8).
  // `audio` pulls in gt_audio_init()+gt_music.o at build time.
  sfx:   { params: [["int", false], ["int", true]], ret: "void", c: "gt_sfx", audio: true },
  sfx_bank: { params: [["array8", false]], ret: "void", c: "gt_sfx_bank", audio: true },
  music_bank: { params: [["array8", false]], ret: "void", c: "gt_music_bank", audio: true },
  // `loop` is a truthy flag (default on): music(0) loops, music(0,false) plays once.
  music: { params: [["int", false], ["flip", true]], ret: "void", c: "gt_music", audio: true },
  // song(data, [loop]) - play a native .gtm2 FM song (Clyde's format); data is a
  // hexdata() blob. loop defaults on. gt.song_stop() halts it. See docs/MUSIC.md.
  song: { params: [["array8", false], ["flip", true]], ret: "void", c: "gt_gtm2_play", audio: true },
  song_stop: { params: [], ret: "void", c: "gt_gtm2_stop", audio: true },

  // ---- math ------------------------------------------------------------------
  flr:   { params: [["num", false]], ret: "int", c: null, special: "flr" },
  ceil:  { params: [["num", false]], ret: "int", c: null, special: "ceil" },
  abs:   { params: [["num", false]], ret: "same", c: null, special: "abs" },
  sgn:   { params: [["num", false]], ret: "int", c: null, special: "sgn" },
  min:   { params: [["num", false], ["num", true]], ret: "same", c: null, special: "min" },
  max:   { params: [["num", false], ["num", true]], ret: "same", c: null, special: "max" },
  mid:   { params: [["num", false], ["num", false], ["num", false]], ret: "same", c: null, special: "mid" },
  sqrt:  { params: [["num", false]], ret: "fixed", c: "gt_fsqrt" },
  sin:   { params: [["num", false]], ret: "fixed", c: "gt_fsin" },
  cos:   { params: [["num", false]], ret: "fixed", c: "gt_fcos" },
  atan2: { params: [["num", false], ["num", false]], ret: "fixed", c: "gt_fatan2" },
  rnd:   { params: [["num", true]], ret: "fixed", c: "gt_p8_rnd" },
  srand: { params: [["num", false]], ret: "void", c: "gt_p8_srand" },
  t:     { params: [], ret: "fixed", c: "gt_p8_time", isValue: false },
  time:  { params: [], ret: "fixed", c: "gt_p8_time" },

  // fixed-capacity numeric array (v0.3): `local pool = array(16)`.
  // Top-level only; 1-based indexing; #a is the capacity. Checker handles it.
  array: { params: [["int", false], ["num", true]], ret: "array", special: "array" },
  // byte variant: elements 0-255 in one byte each (half RAM, ~half cycles/access)
  array8: { params: [["int", false], ["num", true]], ret: "array", special: "array" },

  // struct pools (v0.3): `local bullets = pool(8)` at top level, then
  // add(bullets, {x=1, y=2}), `for b in all(bullets)`, del(bullets, b).
  // Field set is frozen by the first add(); #pool = live count.
  pool: { params: [["int", false]], ret: "pool", special: "pool" },
  print: { params: [], ret: "int", special: "print" },
  add:  { params: [], ret: "void", special: "add" },
  del:  { params: [], ret: "void", special: "del" },
};

// gt.* extras (GameTank-specific)
export const GT_MEMBERS = {
  // gt.rgb(byte) - raw GameTank palette byte 0-255 (the full ~200-color space,
  // beyond the 16 PICO-8 indices). gt.rgb(r,g,b) - pick by RGB (0-255 each,
  // constant); resolved to the nearest hardware color at compile time.
  rgb:    { kind: "fn", params: [["int", false]], ret: "int", special: "rgb" },
  ticks:  { kind: "fn", params: [], ret: "int", c: "(int)gt_ticks", isValue: true },
  border: { kind: "fn", params: [["color", false]], ret: "void", c: "gt_p8_border" },
  // frame clear queued after the page flip - its pixel time hides inside the
  // fps30 second vsync wait. Call once (usually _init); pass -1 to disable.
  autocls: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_autocls_set" },
  note:    { kind: "fn", params: [["int", false], ["int", false], ["int", true]], ret: "void", c: "gt_note", audio: true },
  noteoff: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_noteoff", audio: true },
  // parallax starfield: the whole field moves/draws in one tight C loop each,
  // instead of ~1000 cycles of cc65 call overhead per star from the game loop.
  starfield_init: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_starfield_init" },
  starfield_move: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_starfield_move" },
  starfield_draw: { kind: "fn", params: [], ret: "void", c: "gt_starfield_draw" },
  // ambient flake field (snow/motes/slow clouds): SDK-owned state, CPU-mode
  // pokes - ~60 cycles per flake vs ~350 for the Lua-loop + rectfill shape
  flakes_init: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_flakes_init" },
  flakes_draw: { kind: "fn", params: [["int", false], ["int", false]], ret: "void", c: "gt_flakes_draw" },
  // layered range draw: (first, count, camdx8, camdy8) - clouds behind the
  // map and snow in front share one engine
  flakes_draw2: { kind: "fn", params: [["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_flakes_draw2" },
  // manual slot setup for the non-snow layer: (i, x, y, w, h, spd8, col)
  flakes_set: { kind: "fn", params: [["int", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_flakes_set" },
  // follower chain (hair/tails): eases 5 segments toward (x,y), draws p8
  // round dots r=2,2,1,1,1 in the given color - all in asm (gt_flakes.s)
  flakes_mode: { kind: "fn", params: [["int", false], ["int", false]], ret: "void", c: "gt_flakes_mode" },
  chain_step_draw: { kind: "fn", params: [["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_chain_step_draw" },
  // the 4-piece 128x128 canvas window blit (scrolling composed maps)
  // flakes draw through CPU pokes (1x1 fields, frame-tail only)
  flakes_draw2_cpu: { kind: "fn", params: [["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_flakes_draw2_cpu" },
  canvas_view: { kind: "fn", params: [["int", false], ["int", false], ["int", true], ["int", true]], ret: "void", c: "gt_canvas_view" },
  // visible-window tile scan in asm: draws every flag&1 tile of
  // map[j0..j1][i0..i1] (byte tiles, row-major, lvlw wide) as an 8x8 sprite
  tiles_draw: { kind: "fn", params: [["array8", false], ["array8", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_tiles_draw" },
  // one ball-table physics substep in asm: fixed x/y/vx/vy arrays (16.16,
  // engine drives the embedded 8.8 core), int active array, byte bounce
  // flags, byte pair list out (i,j 1-based, 0-terminated)
  balls_step: { kind: "fn", params: [["array", false], ["array", false], ["array", false], ["array", false], ["array", false], ["array8", false], ["array8", false], ["int", false]], ret: "void", c: "gt_balls_step" },
  // drag pass on the same fixed arrays: v -= (v>>6)+(v>>8) per active ball
  balls_drag: { kind: "fn", params: [["array", false], ["array", false], ["array", false], ["int", false]], ret: "void", c: "gt_balls_drag" },
  // one 16x16 sprite per nonzero cell byte at (int(x)-8, int(y)-7)
  balls_draw: { kind: "fn", params: [["array", false], ["array", false], ["array8", false], ["int", false]], ret: "void", c: "gt_balls_draw" },
  // HUD meter bar: bg strip + value fill + highlight + deficit, staged in
  // one asm call (px, py, v, m, c, c2, bg; v/m 0..100; bg >= 16 skips)
  dbar: { kind: "fn", params: [["int", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_dbar", special: "dbar" },
  // print a cached ASCII byte buffer (NUL-terminated) in one call
  print_buf: { kind: "fn", params: [["array8", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "int", c: "gt_p8_print_buf" },
  // particle pool step: x += vx, y += vy, v *= 0.953 (v -= v>>5 + v>>6)
  // on every used slot; the pool needs fixed fields x, y, vx, vy
  parts_step: { kind: "fn", params: [["pool", false]], ret: "void", c: "gt_parts_step", special: "partsstep" },
  // bulk pool integration: gt.pool_move(pool, mode) - moves every used slot
  // (x += sx, y += sy; mode 1 also damps velocities by v -= v>>3 + v>>5).
  // The pool must have int fields x, y, sx, sy.
  pool_move: { kind: "fn", params: [["pool", false], ["int", false]], ret: "void", c: "gt_pool_move", special: "poolmove" },
  // bulk animation: gt.pool_anim(pool, "frame", "spd", "maxf") - frame +=
  // spd per used slot, reset to 16 when frame > maxf (16ths-frames)
  // life-cost sum + cooldown decay: sum(cost[act[i]-1]) + lm[i]=max(0,lm[i]-5)
  // ball motion trails: stamp sprs[act[i]-1] at (tx-3,ty-3) when moved >= 2px
  trail_stamp: { kind: "fn", params: [["array", false], ["array", false], ["array", false], ["array8", false], ["array8", false], ["array8", false], ["int", false], ["int", false]], ret: "void", c: "gt_trail_stamp" },
  cost_decay: { kind: "fn", params: [["array", false], ["array8", false], ["array8", false], ["int", false]], ret: "int", c: "gt_cost_decay" },
  pool_anim: { kind: "fn", params: [["pool", false], ["str", false], ["str", false], ["str", false]], ret: "void", c: "gt_pool_anim", special: "poolanim" },
  // full enemy sprite pass: cell from per-type desc + anim frame + flash,
  // shake nudge, edge clip. gt.pool_edraw(pool, "ani","type","flash","shake",
  // desc_bytes, nudge)
  pool_edraw: { kind: "fn", params: [["pool", false], ["str", false], ["str", false], ["str", false], ["str", false], ["array8", false], ["int", false]], ret: "void", c: "gt_pool_edraw", special: "pooledraw" },
  // 24px atlas-chunk grid window (racing tracks): grid ints, two decode
  // LUTs (road, decal), a props byte-list out, stride, cell window
  chunks_draw: { kind: "fn", params: [["array", false], ["array8", false], ["array8", false], ["array8", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_chunks_draw" },
  // torus track cache (GRAM group 3): compose a 256x256 window from a packed
  // chunk grid ONCE, then restore it each frame with one windowed blit
  // (gt.track_view) - no per-tile repaint. track_col/track_row2 refresh a single
  // canvas column/row for incremental scroll; track_props collects the prop
  // (idx, screenx, screeny) triples for sprites layered over the cached track.
  // grid/ckdt/ctiles are array (16-bit); props is array8. See gt_bg.c / gt_api.c.
  track_grid:  { kind: "fn", params: [["array", false], ["array", false], ["array", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_track_grid" },
  track_col:   { kind: "fn", params: [["array", false], ["array", false], ["array", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_track_col" },
  track_row2:  { kind: "fn", params: [["array", false], ["array", false], ["array", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_track_row2" },
  track_props: { kind: "fn", params: [["array", false], ["array8", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_track_props" },
  track_view:  { kind: "fn", params: [["int", false], ["int", false]], ret: "void", c: "gt_track_view" },
  track_compose: { kind: "fn", params: [["array8", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_track_compose" },
  // bulk sprite pass: every used slot whose byte field (arg 2, a field
  // name string) is nonzero blits an 8x8 cell at (x>>4, y>>4)
  pool_sprs: { kind: "fn", params: [["pool", false], ["str", false], ["int", true], ["int", true]], ret: "void", c: "gt_pool_sprs", special: "poolsprs" },
  // two-pool AABB overlap scan: gt.hit_scan(A, "w", "h", B, "w", bh, shift,
  // pairs) - pairs get (a_ord, b_ord) live ordinals, 0-terminated
  hit_scan: { kind: "fn", params: [["pool", false], ["str", false], ["str", false], ["pool", false], ["str", false], ["int", false], ["int", false], ["array8", false]], ret: "void", c: "gt_hit_scan", special: "hitscan" },
  // Offscreen-GRAM background canvas. The GameTank has 512 KB of GRAM (32
  // pages of 128x128); the SDK uses only page 0 (the sheet). A background
  // drawn as ONE big blit from a spare page costs the same as one 8x8 blit
  // (~free), vs a per-tile spr() loop (~1 blit per visible tile). Compose the
  // level's tiles into the bg page ONCE (per level load), then blit it whole
  // every frame. The bg page is a 256x256 canvas (cw/ch up to 32 cells), so
  // gt.bg_draw(sx,sy) scrolls a 128x128 window across it seamlessly.
  //   gt.bg_compose(map, cols, cx, cy, cw, ch)  -- CPU-paint tiles -> bg page
  //   gt.bg_draw([sx], [sy])                     -- blit/scroll window -> screen
  bg_compose: { kind: "fn", params: [
    ["array", false], ["int", false], ["int", false], ["int", false],
    ["int", false], ["int", false]], ret: "void", c: "gt_bg_compose" },
  // Freeform canvas building (atlases of pre-rendered chunks, big composed
  // sprites): clear the 256x256 canvas, stamp individual sheet tiles anywhere
  // (multiples of 8), then gt.gspr(gx,gy,w,h,x,y) queue-blits any rect of the
  // canvas to the screen - camera-adjusted + colorkey like spr(), ONE blit no
  // matter how many tiles it covers.
  bg_clear: { kind: "fn", params: [], ret: "void", c: "gt_bg_clear" },
  bg_tile: { kind: "fn", params: [["int", false], ["int", false], ["int", false]],
    ret: "void", c: "gt_bg_tile" },
  // stamp a vertical run of cells with one GRAM mode dance (ring columns)
  bg_coln: { kind: "fn", params: [["array8", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_bg_coln" },
  gspr: { kind: "fn", params: [
    ["int", false], ["int", false], ["int", false], ["int", false],
    ["coord", false], ["coord", false]], ret: "void", c: "gt_gspr" },
  bg_draw: { kind: "fn", params: [["coord", true], ["coord", true]], ret: "void", c: "gt_bg_draw" },
};

// PICO-8 color indices 0-15 -> GameTank CAPTURE-palette bytes.
// Computed by nearest-match (redmean) against the emulator palette, then
// hand-tuned: black/greys/white pinned to the neutral ramp, brown moved off
// the red row, yellow moved to the yellow-green row.
export const P8_PALETTE = [
  0x00, 0xA9, 0x5A, 0xDB, 0x33, 0x03, 0x06, 0x07,
  0x5B, 0x3E, 0x1F, 0xFE, 0xBE, 0x8C, 0x5E, 0x2F,
];

export const CALLBACKS = ["_init", "_update", "_update60", "_draw"];
