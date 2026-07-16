// gtlua builtin functions - the PICO-8 global API surface (v0.2 slice) plus
// the gt.* GameTank extras.
//
// Param kinds:
//   coord - pixel coordinate/radius: C int; fixed args are floored (>>16)
//   num   - 16.16 number: C long; int args are promoted (<<16)
//   int   - small integer (button index, player): C int; fixed args floored
//   color - a GameTank palette byte 0-255. A static 0-15 literal is baked from
//           the PICO-8 palette at compile time; gt.rgb() gives any byte;
//           optional -> -1 sentinel (keep current draw color)
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
  sset:     { params: [["coord", false], ["coord", false], ["color", true]], ret: "void", c: "gt_p8_sset" },
  spr:      { params: [["int", false], ["coord", false], ["coord", false], ["int", true], ["int", true], ["flip", true], ["flip", true]], ret: "void", c: "gt_p8_spr" },
  // native frame-table sprite: sprf(frame, x, y, [flipx], [flipy]) draws frame
  // `frame` from a .gsi table (arbitrary size/offset, any 256x256 quadrant).
  // The two flip flags pack into one arg (bit0=X, bit1=Y) for gt_gspr_frame.
  sprf:     { params: [["int", false], ["coord", false], ["coord", false], ["flip", true], ["flip", true]], ret: "void", c: "gt_gspr_frame" },
  // GBA-only: rotated+scaled hardware sprite. sprr(n, x, y, angle, [scale]).
  // angle is PICO-8 turns (0..1, like sin/cos); scale is a fixed multiplier
  // (default 1.0). Uses a real OBJ affine matrix — the GBA affine hardware the
  // whole SDK leans into. (No GameTank analog; the emitter only reaches this on
  // the gba target.)
  sprr:     { params: [["int", false], ["coord", false], ["coord", false], ["num", false], ["num", true]], ret: "void", c: "gba_sprr", gbaOnly: true },
  // sprr2(n,x,y,angle,sx,sy): rotated + NON-uniform scale (squash/stretch, spinning coin).
  sprr2:    { params: [["int", false], ["coord", false], ["coord", false], ["num", false], ["num", false], ["num", false]], ret: "void", c: "gba_sprr2", gbaOnly: true },
  // spr8(t,x,y,[flip]): an 8x8 sprite from raw tile index t (bullets, pickups).
  spr8:     { params: [["int", false], ["coord", false], ["coord", false], ["flip", true]], ret: "void", c: "gba_spr8", gbaOnly: true },
  // per-sprite modifiers for the next spr()/spr8() this frame (reset each frame):
  spr_pal:  { params: [["int", false]], ret: "void", c: "gba_spr_pal", gbaOnly: true },
  spr_prio: { params: [["int", false]], ret: "void", c: "gba_spr_prio", gbaOnly: true },
  // spr_blend()/spr_blend_off(): next spr() translucent (uses blend weights) or opaque.
  spr_blend:     { params: [], ret: "void", c: "gba_spr_blend", gbaOnly: true },
  spr_blend_off: { params: [], ret: "void", c: "gba_spr_blend_off", gbaOnly: true },
  // spr_window(): next spr() is a shaped OBJ-window mask (pair with window_obj).
  spr_window:    { params: [], ret: "void", c: "gba_spr_window", gbaOnly: true },
  // spr_mosaic(on): apply the mosaic() grid to the next spr().
  spr_mosaic:    { params: [["flip", false]], ret: "void", c: "gba_spr_mosaic", gbaOnly: true },

  // ---- GBA hardware tile backgrounds (Mode 0) — the real scrolling-game path ----
  // These control the 4 hardware BG layers. The tileset/tilemap DATA comes from
  // the build (--maptiles/--map convert a PNG to a layer's tiles + map), so the
  // Lua game just shows/scrolls/edits layers — no giant arrays in Lua source.
  // map_show(layer): display the build-bundled tilemap on a layer (loads its
  //   tiles + map, enables it). Call once (usually _init).
  map_show:  { params: [["int", true]], ret: "void", c: "gba_map_show", gbaOnly: true },
  layer_show:{ params: [["int", false], ["flip", false]], ret: "void", c: "gba_layer_show", gbaOnly: true },
  layer_pri: { params: [["int", false], ["int", false]], ret: "void", c: "gba_layer_priority", gbaOnly: true },
  // camera(x,y) already exists (PICO-8) and maps to gba_camera — hardware scroll.
  layer_scroll:{ params: [["int", false], ["coord", false], ["coord", false]], ret: "void", c: "gba_layer_scroll", gbaOnly: true },
  parallax:  { params: [["int", false], ["num", false]], ret: "void", c: "gba_layer_parallax", gbaOnly: true },
  // tget/tset: read/set a tile in a layer's map at (col,row). (Distinct from the
  // GameTank mget/mset above, which have a different 2-arg signature.)
  tget:      { params: [["int", false], ["int", false], ["int", false]], ret: "int", c: "gba_mget", gbaOnly: true },
  tset:      { params: [["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gba_mset", gbaOnly: true },

  // ---- color effects (hardware blend unit — free, composites in the PPU) ----
  // blend(layer, alpha): draw a layer semi-transparent over the scene behind it
  //   (glass/ghosts/dimmed UI). layer 0..2 tiles, 3 text, 4 sprites; alpha 0..1.
  // fade(amount, [white]): fade the whole screen to black (or white) — the level-
  //   wipe / hit-flash / pause-dim workhorse. amount 0..1; white truthy = to white.
  // blend_off(): clear all color effects.
  blend:     { params: [["int", false], ["num", false]], ret: "void", c: "gba_blend", gbaOnly: true },
  fade:      { params: [["num", false], ["flip", true]], ret: "void", c: "gba_fade", gbaOnly: true },
  blend_off: { params: [], ret: "void", c: "gba_blend_off", gbaOnly: true },
  // mosaic(n)/mosaic2(bh,bv): hardware pixelate (0=off..15). Dissolve/hit-flash/heat.
  mosaic:    { params: [["int", false]], ret: "void", c: "gba_mosaic", gbaOnly: true },
  mosaic2:   { params: [["int", false], ["int", false]], ret: "void", c: "gba_mosaic2", gbaOnly: true },
  // backdrop(color): the void behind all layers (PICO-8 index or raw). screen_off/on:
  // force-blank the display instantly (hide a mid-frame rebuild, instant cut).
  backdrop:   { params: [["color", false]], ret: "void", c: "gba_backdrop", gbaOnly: true },
  screen_off: { params: [], ret: "void", c: "gba_screen_off", gbaOnly: true },
  screen_on:  { params: [], ret: "void", c: "gba_screen_on", gbaOnly: true },
  // pal(i,r,g,b) / spr_col(i,r,g,b): set a BG / OBJ palette color at runtime (0..255
  // components). Palette swap, day/night, animated cycling (rotate entries each frame).
  pal:       { params: [["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gba_pal", gbaOnly: true },
  spr_col:   { params: [["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gba_spr_col", gbaOnly: true },
  // hgradient(table): per-scanline BACKDROP gradient via the HBlank IRQ. `table` is
  // an array of 160 raw BGR555 colors (fill with rgb()/color numbers, one per line):
  // sunset skies, underwater bands, a fire glow. Pass it once/frame; nil/0 = off.
  hgradient: { params: [["array", false]], ret: "void", c: "gba_hgradient", gbaOnly: true },
  // save(slot, array8, n) / load(slot, array8, n): battery SRAM persistence. `slot`
  // 0..15 (1 KB each); keep game state in an array8 and save/load it. load returns
  // the byte count restored (0 = slot never written -> start fresh).
  save:      { params: [["int", false], ["array8", false], ["int", false]], ret: "void", c: "gba_save", gbaOnly: true },
  load:      { params: [["int", false], ["array8", false], ["int", false]], ret: "int",  c: "gba_load", gbaOnly: true },
  // timer_start()/timer_read(): a free-running hardware timer (Timer 3, ~16 kHz) for
  // sub-frame timing + profiling. timer_start resets it; timer_read samples the count
  // (wraps ~every 4 ms). Bracket a routine to profile it, or drive rhythm timing.
  timer_start: { params: [], ret: "void", c: "gba_timer_start", gbaOnly: true },
  timer_read:  { params: [], ret: "int",  c: "gba_timer_read",  gbaOnly: true },

  // ---- Mode 7: affine background (rotate/scale/scroll a plane in hardware) ----
  // mode7(): show the bundled --mode7 plane on BG2 (call once in _init).
  // mode7_cam(x,y, angle, [zoom]): per frame, place the camera over the plane.
  //   x,y = world point the screen centers on; angle = turns (0..1); zoom scale.
  // mode7_off(): hide the affine layer.
  mode7:     { params: [], ret: "void", c: "gba_mode7", gbaOnly: true },
  mode7_cam: { params: [["num", false], ["num", false], ["num", false], ["num", true]], ret: "void", c: "gba_mode7_cam", gbaOnly: true },
  mode7_off: { params: [], ret: "void", c: "gba_mode7_off", gbaOnly: true },

  // ---- windows: hardware rectangular clipping regions (free in the PPU) ----
  // window(x0,y0,x1,y1): SPOTLIGHT — show everything inside the box, hide outside
  //   (iris/reveal/peek). The one-call verb; covers most uses.
  // window_inside(x0,y0,x1,y1, layers): show only `layers` inside the box. `layers`
  //   is a bitmask: 1=BG0 2=BG1 4=BG2 8=text 16=sprites; 31 = all. Build with +.
  // window_outside(layers): what shows OUTSIDE the box (default none = hidden).
  //   Pass 31 to keep the full scene outside and use the box only to override a region.
  // window_off(): disable windowing.
  window:         { params: [["coord", false], ["coord", false], ["coord", false], ["coord", false]], ret: "void", c: "gba_window", gbaOnly: true },
  window_inside:  { params: [["coord", false], ["coord", false], ["coord", false], ["coord", false], ["int", false]], ret: "void", c: "gba_window_inside", gbaOnly: true },
  window_outside: { params: [["int", false]], ret: "void", c: "gba_window_outside", gbaOnly: true },
  // window_obj(layers): OBJ window — sprites flagged spr_window() become a shaped
  //   mask; `layers` (same bitmask) shows through the sprite silhouette (torch/keyhole).
  window_obj:     { params: [["int", false]], ret: "void", c: "gba_window_obj", gbaOnly: true },
  window_off:     { params: [], ret: "void", c: "gba_window_off", gbaOnly: true },

  // ---- animation helpers (frame-range cycling, timed off the frame clock) ----
  // anim(slot, first, last, fps): current frame of a LOOPING cycle first..last at
  //   `fps` animation-frames/sec. slot = a small per-actor id (0..31). Feed the
  //   result to spr()/spr8()/sprf(): spr(anim(0,1,4,8), x, y).
  // anim_once(slot, first, last, fps): play once then HOLD on last; anim_done(slot)
  //   goes true at the end. For explosions / one-shots.
  // anim_pingpong(...): bounce first..last..first.
  // anim_reset(slot): restart. anim_done(slot): 1 if a once-anim finished.
  anim:          { params: [["int", false], ["int", false], ["int", false], ["num", false]], ret: "int", c: "gba_anim", gbaOnly: true },
  anim_once:     { params: [["int", false], ["int", false], ["int", false], ["num", false]], ret: "int", c: "gba_anim_once", gbaOnly: true },
  anim_pingpong: { params: [["int", false], ["int", false], ["int", false], ["num", false]], ret: "int", c: "gba_anim_pingpong", gbaOnly: true },
  anim_reset:    { params: [["int", false]], ret: "void", c: "gba_anim_reset", gbaOnly: true },
  anim_done:     { params: [["int", false]], ret: "int", c: "gba_anim_done", gbaOnly: true },
  // PICO-8 tilemap: map(cx,cy, sx,sy, cw,ch) draws a cw x ch block of the cart's
  // __map__ (imported as a byte array) starting at cell (cx,cy) to screen pixel
  // (sx,sy), one 8x8 sheet sprite per non-zero tile. Software spr()-loop, the
  // same as PICO-8 (neither machine has tilemap hardware). All six args are
  // optional in PICO-8 (default 0,0,0,0,128,32-ish); we require none.
  map:      { params: [["int", true], ["int", true], ["coord", true], ["coord", true], ["int", true], ["int", true]], ret: "void", special: "map" },
  mget:     { params: [["int", false], ["int", false]], ret: "int", special: "mget" },
  // PICO-8 pget(x,y): read a framebuffer pixel (raw GameTank color byte).
  pget:     { params: [["coord", false], ["coord", false]], ret: "int", c: "gt_p8_pget" },
  // run()/reset() restart the cart from power-on: a full crt0 reset that reruns
  // copydata (restores every top-level initializer), zeroes BSS, and re-enters
  // main() - not just the game's _init(), which would leave top-level state and
  // the runtime stale. gt_p8_run() jumps to the reset entry (never returns).
  run:      { params: [], ret: "void", c: "gt_p8_run" },
  reset:    { params: [], ret: "void", c: "gt_p8_run" },
  // PICO-8 sspr(sx,sy,sw,sh, dx,dy, [dw,dh], [flip_x,flip_y]): scaled sheet blit.
  // dw/dh default to sw/sh (unscaled). Software nearest-neighbor, rounded to an
  // integer scale and cached in GRAM (see gt_p8_sspr). flips pack into one arg.
  sspr:     { params: [["int", false], ["int", false], ["int", false], ["int", false],
                       ["coord", false], ["coord", false], ["int", true], ["int", true],
                       ["flip", true], ["flip", true]], ret: "void", special: "sspr" },

  // ---- input ---------------------------------------------------------------
  btn:      { params: [["int", false], ["int", true]], ret: "bool", c: "gt_p8_btn" },
  btnp:     { params: [["int", false], ["int", true]], ret: "bool", c: "gt_p8_btnp" },

  // ---- sound (gt_music.c) --------------------------------------------------
  // sfx(n, [ch]) - fire built-in effect n (0-7); ch omitted = auto channel.
  // music(n, [loop]) - start built-in tune n; music(-1) stops (PICO-8).
  // `audio` pulls in gt_audio_init()+gt_music.o at build time.
  sfx:   { params: [["int", false], ["int", true]], ret: "void", c: "gt_sfx", audio: true },
  // sfx_ex(n, [vol], [pan], [pitch]): per-shot volume 0..255, pan 0..255 (128=center),
  // pitch 16.16 (1.0=normal). sfx_volume(0..1024): master effect volume. (GBA/maxmod.)
  sfx_ex:     { params: [["int", false], ["int", true], ["int", true], ["num", true]], ret: "void", c: "gba_sfx_ex", gbaOnly: true },
  sfx_volume: { params: [["int", false]], ret: "void", c: "gba_sfx_volume", gbaOnly: true },
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

  // PICO-8 bitwise FUNCTION forms - exact aliases of the operators gtlua already
  // has (a & b, a | b, ...). Carts use both spellings interchangeably. Emitted
  // as the operator, so zero runtime cost. band/bor/bxor/bnot on the raw bits;
  // shl/shr shift (shr = arithmetic >>, lshr = logical >>>).
  band:  { params: [["num", false], ["num", false]], ret: "same", c: null, special: "bitop", op: "&" },
  bor:   { params: [["num", false], ["num", false]], ret: "same", c: null, special: "bitop", op: "|" },
  bxor:  { params: [["num", false], ["num", false]], ret: "same", c: null, special: "bitop", op: "^^" },
  bnot:  { params: [["num", false]], ret: "same", c: null, special: "bitop", op: "~" },
  shl:   { params: [["num", false], ["num", false]], ret: "same", c: null, special: "bitop", op: "<<" },
  shr:   { params: [["num", false], ["num", false]], ret: "same", c: null, special: "bitop", op: ">>" },
  lshr:  { params: [["num", false], ["num", false]], ret: "same", c: null, special: "bitop", op: ">>>" },
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
  // benchmark/test cycle marker: writes GT_MARK_ADDR so the GT_PROFILE core
  // build can bracket measured regions. No effect on normal carts.
  mark: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_mark" },
  ticks:  { kind: "fn", params: [], ret: "int", c: "(int)gt_ticks", isValue: true },
  border: { kind: "fn", params: [["color", false]], ret: "void", c: "gt_p8_border" },
  // frame clear queued after the page flip - its pixel time hides inside the
  // fps30 second vsync wait. Call once (usually _init); pass -1 to disable.
  autocls: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_autocls_set" },
  note:    { kind: "fn", params: [["int", false], ["int", false], ["int", true]], ret: "void", c: "gt_note", audio: true },
  noteoff: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_noteoff", audio: true },
  // parallax starfield: the whole field moves/draws in one tight C loop each,
  // instead of ~1000 cycles of cc65 call overhead per star from the game loop.
  parallax_init: { kind: "fn", params: [["int", false], ["color", true], ["color", true], ["color", true]], ret: "void", c: "gt_parallax_init" },
  parallax_move: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_parallax_move" },
  parallax_draw: { kind: "fn", params: [], ret: "void", c: "gt_parallax_draw" },
  // ambient flake field (snow/motes/slow clouds): SDK-owned state, CPU-mode
  // pokes - ~60 cycles per flake vs ~350 for the Lua-loop + rectfill shape
  drift_init: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_drift_init" },
  drift_draw: { kind: "fn", params: [["int", false], ["int", false]], ret: "void", c: "gt_drift_draw" },
  // layered range draw: (first, count, camdx8, camdy8) - clouds behind the
  // map and snow in front share one engine
  drift_draw_range: { kind: "fn", params: [["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_drift_draw_range" },
  // manual slot setup for the non-snow layer: (i, x, y, w, h, spd8, col)
  drift_set: { kind: "fn", params: [["int", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_drift_set" },
  // follower chain (hair/tails): eases 5 segments toward (x,y), draws p8
  // round dots r=2,2,1,1,1 in the given color - all in asm (gt_flakes.s)
  drift_mode: { kind: "fn", params: [["int", false], ["int", false]], ret: "void", c: "gt_drift_mode" },
  chain_step_draw: { kind: "fn", params: [["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_chain_step_draw" },
  // the 4-piece 128x128 canvas window blit (scrolling composed maps)
  // flakes draw through CPU pokes (1x1 fields, frame-tail only)
  drift_draw_range_cpu: { kind: "fn", params: [["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_drift_draw_range_cpu" },
  canvas_view: { kind: "fn", params: [["int", false], ["int", false], ["int", true], ["int", true]], ret: "void", c: "gt_canvas_view" },
  // visible-window tile scan in asm: draws every flag&1 tile of
  // map[j0..j1][i0..i1] (byte tiles, row-major, lvlw wide) as an 8x8 sprite
  tiles_draw: { kind: "fn", params: [["array8", false], ["array8", false], ["int", false], ["int", false], ["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_tiles_draw" },
  // one ball-table physics substep in asm: fixed x/y/vx/vy arrays (16.16,
  // engine drives the embedded 8.8 core), int active array, byte bounce
  // flags, byte pair list out (i,j 1-based, 0-terminated)
  phys_sprite: { kind: "fn", params: [["int", false], ["int", false], ["int", false]], ret: "void", c: "gt_phys_sprite" },
  phys_bounds: { kind: "fn", params: [["int", false], ["int", false], ["int", false], ["int", false], ["num", false]], ret: "void", c: "gt_phys_bounds" },
  phys_step: { kind: "fn", params: [["array", false], ["array", false], ["array", false], ["array", false], ["array", false], ["array8", false], ["array8", false], ["int", false]], ret: "void", c: "gt_phys_step" },
  // drag pass on the same fixed arrays: v -= (v>>6)+(v>>8) per active ball
  phys_drag: { kind: "fn", params: [["array", false], ["array", false], ["array", false], ["int", false]], ret: "void", c: "gt_phys_drag" },
  // one 16x16 sprite per nonzero cell byte at (int(x)-8, int(y)-7)
  phys_draw: { kind: "fn", params: [["array", false], ["array", false], ["array8", false], ["int", false]], ret: "void", c: "gt_phys_draw" },
  // HUD meter bar: bg strip + value fill + highlight + deficit, staged in
  // one asm call (px, py, v, m, c, c2, bg; v/m 0..100; bg >= 16 skips)
  dbar_style: { kind: "fn", params: [["int", false], ["int", false], ["int", false], ["color", false]], ret: "void", c: "gt_dbar_style" },
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
  pool_decay: { kind: "fn", params: [["array", false], ["array8", false], ["array8", false], ["int", false], ["int", false]], ret: "int", c: "gt_pool_decay" },
  pool_anim: { kind: "fn", params: [["pool", false], ["str", false], ["str", false], ["str", false], ["int", true]], ret: "void", c: "gt_pool_anim", special: "poolanim" },
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
  track_dims: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_track_dims" },
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
  gflush: { kind: "fn", params: [], ret: "void", c: "gt_gflush" },
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
