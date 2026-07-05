// gtlua builtin functions — the PICO-8 global API surface (v0.2 slice) plus
// the gt.* GameTank extras.
//
// Param kinds:
//   coord — pixel coordinate/radius: C int; fixed args are floored (>>16)
//   num   — 16.16 number: C long; int args are promoted (<<16)
//   int   — small integer (button index, player): C int; fixed args floored
//   color — PICO-8 color 0-15 or gt.rgb() raw; optional -> -1 sentinel
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

  // ---- input ---------------------------------------------------------------
  btn:      { params: [["int", false], ["int", true]], ret: "bool", c: "gt_p8_btn" },
  btnp:     { params: [["int", false], ["int", true]], ret: "bool", c: "gt_p8_btnp" },

  // ---- sound (gt_music.c) --------------------------------------------------
  // sfx(n, [ch]) — fire built-in effect n (0-7); ch omitted = auto channel.
  // music(n, [loop]) — start built-in tune n; music(-1) stops (PICO-8).
  // `audio` pulls in gt_audio_init()+gt_music.o at build time.
  sfx:   { params: [["int", false], ["int", true]], ret: "void", c: "gt_sfx", audio: true },
  // `loop` is a truthy flag (default on): music(0) loops, music(0,false) plays once.
  music: { params: [["int", false], ["flip", true]], ret: "void", c: "gt_music", audio: true },

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
  // gt.rgb(byte) — raw GameTank palette byte 0-255 (the full ~200-color space,
  // beyond the 16 PICO-8 indices). gt.rgb(r,g,b) — pick by RGB (0-255 each,
  // constant); resolved to the nearest hardware color at compile time.
  rgb:    { kind: "fn", params: [["int", false]], ret: "int", special: "rgb" },
  ticks:  { kind: "fn", params: [], ret: "int", c: "(int)gt_ticks", isValue: true },
  border: { kind: "fn", params: [["color", false]], ret: "void", c: "gt_p8_border" },
  // frame clear queued after the page flip — its pixel time hides inside the
  // fps30 second vsync wait. Call once (usually _init); pass -1 to disable.
  autocls: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_autocls_set" },
  note:    { kind: "fn", params: [["int", false], ["int", false], ["int", true]], ret: "void", c: "gt_note", audio: true },
  noteoff: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_noteoff", audio: true },
  // parallax starfield: the whole field moves/draws in one tight C loop each,
  // instead of ~1000 cycles of cc65 call overhead per star from the game loop.
  starfield_init: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_starfield_init" },
  starfield_move: { kind: "fn", params: [["int", false]], ret: "void", c: "gt_starfield_move" },
  starfield_draw: { kind: "fn", params: [], ret: "void", c: "gt_starfield_draw" },
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
  // canvas to the screen — camera-adjusted + colorkey like spr(), ONE blit no
  // matter how many tiles it covers.
  bg_clear: { kind: "fn", params: [], ret: "void", c: "gt_bg_clear" },
  bg_tile: { kind: "fn", params: [["int", false], ["int", false], ["int", false]],
    ret: "void", c: "gt_bg_tile" },
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
