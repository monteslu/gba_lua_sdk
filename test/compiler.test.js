import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { compile } from "../compiler/index.js";

const REPO = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

const LOOP = "function _update60()\nend\nfunction _draw()\nend\n";

function errorsOf(src) {
  return compile(src, "t.lua").diagnostics
    .filter((d) => d.severity === "error")
    .map((d) => d.message);
}

function cOf(src) {
  const r = compile(src, "t.lua");
  assert.equal(r.ok, true, JSON.stringify(r.diagnostics, null, 2));
  return r.c;
}

// ---- examples ------------------------------------------------------------------

for (const ex of ["pad-square", "orbit", "mathcheck", "audio"]) {
  test(`example ${ex} compiles`, () => {
    const src = readFileSync(path.join(REPO, `examples/${ex}/main.lua`), "utf8");
    const r = compile(src, "main.lua");
    assert.equal(r.ok, true, JSON.stringify(r.diagnostics, null, 2));
    assert.match(r.c, /void main\(void\)/);
  });
}

// ---- PICO-8 dialect --------------------------------------------------------------

test("// is a comment, backslash is floor division", () => {
  const c = cOf("local x = 8 // like this\nfunction _update60()\n  x = x \\ 2\nend\n" + "function _draw()\nend\n");
  assert.match(c, /gtl_x >> 1/);
});

test("!= is ~=", () => {
  const c = cOf("local x = 1\nfunction _update60()\n  if x != 2 then\n    x = 2\n  end\nend\nfunction _draw()\nend\n");
  assert.match(c, /gtl_x != 2/);
});

test("one-line if shorthand", () => {
  const c = cOf("local x = 0\nfunction _update60()\n  if (btn(0)) x -= 1\n  if (btn(1)) x += 1 else x = 0\nend\nfunction _draw()\nend\n");
  // constant-button btn() emits an inline zp pad-word bit test, not a call
  assert.match(c, /gt_pad0 & 512u/);
  assert.match(c, /} else \{/);
});

test("one-line while shorthand", () => {
  const c = cOf("local x = 10\nfunction _update60()\n  while (x > 0) x -= 1\nend\nfunction _draw()\nend\n");
  assert.match(c, /while \(\(gtl_x > 0\)\)/);
});

test("spr without flip: 5 args, no flip packing", () => {
  const c = cOf("function _update60()\nend\nfunction _draw()\n  spr(1, 10, 20)\nend\n");
  // zp-fastcall staging: n,x,y in a0..a2, w/h default to 1, flips default to 0
  assert.match(c, /gt_a0 = 1/);
  assert.match(c, /gt_a5 = 0 \| \(0 << 1\)/);   // both flips off
  assert.match(c, /gt_p8_spr_z\(\)/);
});

test("spr with flip_x/flip_y packs into gt_a5", () => {
  const c = cOf("function _update60()\nend\nfunction _draw()\n  spr(1, 10, 20, 1, 1, true, false)\nend\n");
  // flip_x -> bit0, flip_y -> bit1 of gt_a5
  assert.match(c, /gt_a5 = \(\(1\) \? 1 : 0\) \| \(\(\(0\) \? 1 : 0\) << 1\)/);
});

test("print bakes its color index to the GameTank byte (like every draw call)", () => {
  // regression: print used to pass the raw 0-15 index, so resolve_color (which
  // expects an already-baked byte) rendered every non-white print color wrong.
  const c = cOf('function _draw()\n  print("hi", 20, 20, 14)\nend\n');
  assert.match(c, /gt_p8_print\("hi", 20, 20, 94\)/);   // 14 (pink) -> 0x5E = 94
  // no color arg -> -1 (use draw_color), unchanged
  const c2 = cOf('function _draw()\n  print("x", 1, 1)\nend\n');
  assert.match(c2, /gt_p8_print\("x", 1, 1, -1\)/);
});

test("button glyphs lex as indices", () => {
  const c = cOf("local x = 0\nfunction _update60()\n  if (btnp(🅾️)) x += 1\n  if (btnp(❎)) x -= 1\nend\nfunction _draw()\nend\n");
  // 🅾️=index 4 (mask 16), ❎=index 5 (mask 4096) on the newpress word
  assert.match(c, /gt_rpt0 & 16u/);
  assert.match(c, /gt_rpt0 & 4096u/);
});

test("array8 declares byte elements and reads back as ints", () => {
  const c = cOf("local a = array8(16)\nlocal r = 0\nfunction _update60()\n  a[1] = 200\n  r = a[1] + 100\nend\nfunction _draw()\nend\n");
  assert.match(c, /unsigned char gtl_a\[16\];/);
  assert.match(c, /gtl_r = \(gtl_a\[0\] \+ 100\)/);   // a[1] folds to [0] at compile time
});

test("array8 rejects fixed stores loudly", () => {
  const errs = errorsOf("local a = array8(4)\nfunction _update60()\n  a[1] += 0.5\nend\nfunction _draw()\nend\n");
  assert.ok(errs.some((m) => /array8 elements are bytes/.test(m)), errs.join("\n"));
});

test("array8 cannot be passed where the runtime wants int pairs", () => {
  const errs = errorsOf("local a = array8(4)\nfunction _init()\n  gt.bg_compose(a, 2, 0, 0, 2, 2)\nend\nfunction _update60()\nend\nfunction _draw()\nend\n");
  assert.ok(errs.some((m) => /must be a 16-bit array/.test(m)), errs.join("\n"));
});

test("gt.rgb(r,g,b) resolves to a raw palette byte at compile time", () => {
  const c = cOf("function _update60()\nend\nfunction _draw()\n  rectfill(0,0,9,9, gt.rgb(255,128,0))\nend\n");
  // constant RGB -> a plain 0x00-0xff byte literal, no runtime lookup, no 0x100 flag
  assert.match(c, /0x[0-9a-f]{1,2}\b/);
  assert.doesNotMatch(c, /nearestColorByte|gt_rgb|0x1[0-9a-f][0-9a-f]/);
});

test("gt.rgb(byte) passes a raw byte through (no 0x100 flag)", () => {
  const c = cOf("function _update60()\nend\nfunction _draw()\n  rectfill(0,0,9,9, gt.rgb(0x2f))\nend\n");
  assert.match(c, /47 & 0xFF/);
  assert.doesNotMatch(c, /0x100/);
});

test("a static 0-15 color literal bakes to its GameTank byte", () => {
  // cls(1) is PICO-8 dark-blue; P8_PALETTE[1] = 0xA9 = 169. No runtime index.
  const c = cOf("function _update60()\nend\nfunction _draw()\n  cls(1)\nend\n");
  assert.match(c, /gt_p8_cls\(169\)/);
});

test("gt.rgb(r,g,b) with a non-constant is a loud error", () => {
  const errs = errorsOf("local q = 5\nfunction _update60()\nend\nfunction _draw()\n  rectfill(0,0,9,9, gt.rgb(q,0,0))\nend\n");
  assert.ok(errs.some((m) => /gt\.rgb\(r, g, b\) needs constant/.test(m)), errs.join("\n"));
});

test("multiple assignment evaluates RHS first (swap works)", () => {
  const c = cOf("local a, b = 1, 2\nfunction _update60()\n  a, b = b, a\nend\nfunction _draw()\nend\n");
  assert.match(c, /int L_t0 = gtl_b;/);
  assert.match(c, /gtl_a = L_t0;/);
});

// ---- number model ----------------------------------------------------------------

test("fractional literals make a variable fixed (long)", () => {
  const c = cOf("local v = 1.5\nlocal n = 3\n" + LOOP);
  assert.match(c, /^long gtl_v = 98304L;/m);
  assert.match(c, /^int gtl_n = 3;$/m);
});

test("kind inference widens through assignment", () => {
  const c = cOf("local v = 1\nfunction _update60()\n  v += 0.5\nend\nfunction _draw()\nend\n");
  assert.match(c, /^long gtl_v = 65536L;/m);
});

test("/ always produces fixed; general / uses the fixed-divide runtime", () => {
  const c = cOf("local a = 3\nlocal b = 2\nlocal r = 0.0\nfunction _update60()\n  r = a / b\nend\nfunction _draw()\nend\n");
  // non-nested operands -> zp fastcall entry (fa/fb stores + argless call)
  assert.match(c, /fa = .*, fb = .*, gt_fdiv_zp\(\)/);
});

test("nested fixed divide falls back to the cdecl gt_fdiv (zp slots would collide)", () => {
  const c = cOf("local a = 3.5\nlocal b = 2.5\nlocal c2 = 5.5\nlocal r = 0.0\nfunction _update60()\n  r = a / (b / c2)\nend\nfunction _draw()\nend\n");
  // outer op is cdecl (its rhs nests a divide); inner op is the zp fastcall
  assert.match(c, /gt_fdiv\(gtl_a, \(fa = gtl_b, fb = gtl_c2, gt_fdiv_zp\(\)\)\)/);
});

test("/ by power-of-two constant becomes a shift", () => {
  const c = cOf("local a = 3.5\nlocal r = 0.0\nfunction _update60()\n  r = a / 4\nend\nfunction _draw()\nend\n");
  assert.match(c, /gtl_a >> 2/);
  assert.doesNotMatch(c, /gt_fdiv/);
});

test("a fixed multiply whose operand transitively touches fa/fb stays cdecl", () => {
  // sqrt/atan2/rnd and %/\\ all reach gt_fmul/gt_fdiv internally, which write
  // fa/fb - so the zp fastcall's staged fa would be clobbered before the call.
  // These MUST emit the cdecl gt_fmul (args marshalled at call time), never zp.
  const c = cOf("local a = 0.5\nlocal b = 2.5\nlocal c2 = 0.75\nlocal r = 0.0\n" +
    "function _update60()\n  r = a * sqrt(b)\n  r = a * (b % c2)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_fmul\(gtl_a, gt_fsqrt\(gtl_b\)\)/);      // NOT (fa=.., gt_fmul_zp())
  assert.match(c, /gt_fmul\(gtl_a, gt_ffmod\(gtl_b, gtl_c2\)\)/);
  // and the staged form must NOT wrap either of those runtime calls
  assert.doesNotMatch(c, /fa = gtl_a, fb = gt_f(sqrt|fmod)/);
});

test("fixed multiply goes through the zp fastcall; int multiply stays native", () => {
  const c = cOf("local f = 1.5\nlocal i = 3\nlocal r = 0.0\nlocal s = 0\nfunction _update60()\n  r = f * f\n  s = i * i\nend\nfunction _draw()\nend\n");
  // fixed*fixed, non-nested -> fa/fb stores + argless gt_fmul_zp()
  assert.match(c, /fa = gtl_f, fb = gtl_f, gt_fmul_zp\(\)/);
  assert.match(c, /\(gtl_i \* gtl_i\)/);
});

test("% by power of two masks; general int % is floored", () => {
  const c = cOf("local a = 9\nlocal b = 4\nlocal r = 0\nfunction _update60()\n  r = a % 8\n  r = a % b\nend\nfunction _draw()\nend\n");
  assert.match(c, /gtl_a & 7/);
  assert.match(c, /gt_ifmod\(gtl_a, gtl_b\)/);
});

test("polymorphic min/mid pick int or fixed variants", () => {
  const c = cOf("local i = 1\nlocal f = 0.5\nlocal r = 0\nlocal q = 0.0\nfunction _update60()\n  r = min(i, 3)\n  q = mid(0, f, 1)\nend\nfunction _draw()\nend\n");
  // int min of pure args inlines as a ternary (no cdecl call in hot loops).
  // a literal RHS keeps the direct compare; the ternary picks A/B unchanged.
  assert.match(c, /\(gtl_i < 3\) \? \(gtl_i\) : \(3\)/);
  assert.doesNotMatch(c, /gt_mini/);
  // fixed variants still go through the runtime (long ternaries would bloat)
  assert.match(c, /gt_midf\(0L, gtl_f, 65536L\)/);
});

test("num8 var-vs-var min/max routes the ternary condition through subtract-vs-zero", () => {
  // under num8, max(a,b)/min(a,b) of two fixed VARIABLES must not stack the
  // condition through cc65's ~127-cyc tosicmp; the inline ternary compares
  // (a-b) REL 0 just like binop() does. A literal operand keeps the direct form.
  const c = compile(
    "local a = 0.0\nlocal b = 0.0\nlocal r = 0.0\n" +
      "function _update60()\n  r = max(a, b)\n  r = min(a, b)\nend\nfunction _draw()\nend\n",
    "t.lua", { num8: true },
  ).c;
  assert.match(c, /\(\(gtl_a - \(gtl_b\)\) > 0\) \? \(gtl_a\) : \(gtl_b\)/);
  assert.match(c, /\(\(gtl_a - \(gtl_b\)\) < 0\) \? \(gtl_a\) : \(gtl_b\)/);
});

test("min/mid with impure args still call the runtime (no double evaluation)", () => {
  const c = cOf("local r = 0\nfunction gimme()\n  r += 1\n  return r\nend\nfunction _update60()\n  r = min(gimme(), 3)\n  r = mid(gimme(), 0, 7)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_mini\(gtl_gimme\(\), 3\)/);
  assert.match(c, /gt_midi\(gtl_gimme\(\), 0, 7\)/);
});

test("flr of fixed floors via shift; ceil adds the fraction", () => {
  const c = cOf("local f = 2.5\nlocal r = 0\nfunction _update60()\n  r = flr(f)\n  r = ceil(f)\nend\nfunction _draw()\nend\n");
  assert.match(c, /\(int\)\(gtl_f >> 16\)/);
  assert.match(c, /0xFFFFL\) >> 16\)/);
});

// ---- pools -------------------------------------------------------------------------

const POOL = "local ps = pool(8)\nlocal total = 0\n" +
  "function _update60()\n add(ps,{x=1,y=2})\n for p in all(ps) do\n  total+=p.x\n  del(ps,p)\n end\nend\n" +
  "function _draw()\nend\n";

test("pool declares a high-water mark alongside used/n", () => {
  const c = cOf(POOL);
  assert.match(c, /unsigned char gtl_ps_hi;/);
});

test("pool iteration scans [0.._hi), not the full capacity", () => {
  const c = cOf(POOL);
  // the forall loop bounds on _hi (the watermark), never the literal size 8
  assert.match(c, /for \(L_p\d+ = 0; L_p\d+ < gtl_ps_hi; \+\+L_p\d+\)/);
  assert.doesNotMatch(c, /for \(L_p\d+ = 0; L_p\d+ < 8;/);
});

test("add() allocates O(1): free-chain pop, else the watermark slot", () => {
  const c = cOf(POOL);
  // pop the +1-encoded free chain (links ride the first field array) ...
  assert.match(c, /if \(gtl_ps_free\) \{ L_s\d+ = \(unsigned char\)\(gtl_ps_free - 1\);/);
  // ... else append at the watermark, growing it
  assert.match(c, /else L_s\d+ = gtl_ps_hi;/);
  assert.match(c, /if \(L_s\d+ >= gtl_ps_hi\) gtl_ps_hi = L_s\d+ \+ 1;/);
  // capacity is still the hard ceiling on placement
  assert.match(c, /if \(L_s\d+ < 8\)/);
});

test("del() pushes the free chain and snaps hi + chain on empty", () => {
  const c = cOf(POOL);
  // freed slot joins the chain through its first field's storage
  assert.match(c, /gtl_ps_free = \(unsigned char\)\(\w+ \+ 1\)/);
  // pool emptying resets both the watermark and the chain
  assert.match(c, /--gtl_ps_n == 0 \? \(gtl_ps_hi = 0, gtl_ps_free = 0\) : 0/);
});

// ---- gt.* extras -------------------------------------------------------------------

test("gt.starfield_* map to the SDK batch primitives", () => {
  const c = cOf(
    "function _update()\n gt.starfield_move(1)\nend\n" +
    "function _draw()\n gt.starfield_draw()\nend\n" +
    "function _init()\n gt.starfield_init(100)\nend\n");
  assert.match(c, /gt_starfield_init\(100, -1, -1, -1\)/);
  assert.match(c, /gt_starfield_move\(1\)/);
  assert.match(c, /gt_starfield_draw\(\)/);
});

// ---- sound: sfx() / music() --------------------------------------------------------

test("sfx(n) emits gt_sfx with an auto-channel sentinel and pulls in audio init", () => {
  const c = cOf("function _update60()\n  if (btnp(4)) sfx(0)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_sfx\(0, -1\)/);          // omitted channel -> -1 (auto)
  assert.match(c, /gt_audio_init\(\);/);        // sfx implies the ACP is up
  assert.match(c, /gt_music_init\(\);/);        // and the tracker is installed
});

test("sfx(n, ch) passes the explicit channel", () => {
  const c = cOf("function _update60()\n  sfx(5, 2)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_sfx\(5, 2\)/);
});

test("music(n) loops by default; music(-1) still routes to gt_music (stop)", () => {
  const c = cOf("function _init()\n  music(0)\nend\n" +
                "function _update60()\n  if (btnp(2)) music(-1)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_music\(0, 1\)/);          // default loop = 1
  assert.match(c, /gt_music\(\(-1\), 1\)/);     // stop sentinel (n<0) handled at runtime
});

test("music(n, false) passes an explicit non-loop flag", () => {
  const c = cOf("function _init()\n  music(0, false)\nend\n" + LOOP);
  // loop is a truthy flag: false -> 0
  assert.match(c, /gt_music\(0, \(\(0\) \? 1 : 0\)\)/);
});

test("a game with neither sfx nor music links no audio/tracker init", () => {
  const c = cOf(LOOP);
  assert.doesNotMatch(c, /gt_audio_init/);
  assert.doesNotMatch(c, /gt_music_init/);
});

test("gt.note (the low-level primitive) still works and does NOT pull in the tracker", () => {
  const c = cOf("function _update60()\n  gt.note(0, 60, 100)\n  gt.noteoff(0)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_note\(0, 60, 100\)/);
  assert.match(c, /gt_noteoff\(0\)/);
  assert.match(c, /gt_audio_init\(\);/);        // note needs the ACP
  assert.doesNotMatch(c, /gt_music_init/);      // but not the sfx/music sequencer
});

// ---- callbacks & harness -----------------------------------------------------------

test("_update() selects 30fps mode in the harness", () => {
  const c = cOf("function _update()\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_p8_fps30\(\);/);
});

test("_update60 harness runs at 60 (no fps30)", () => {
  const c = cOf(LOOP);
  assert.doesNotMatch(c, /gt_p8_fps30/);
});

const CASES = [
  ["callback contract required", "local x = 1\n", /_update60\(\) \(60fps\) or _update\(\)/],
  ["both _update and _update60", "function _update()\nend\nfunction _update60()\nend\n", /not both/],
  ["calling _draw yourself", "function _update60()\n  _draw()\nend\nfunction _draw()\nend\n", /called by the runtime/],
  ["tables outside add()", LOOP + "local q = 0\nfunction f()\n  q = { x = 1 }\nend\n", /only allowed inside add/],
  ["nil", LOOP + "local z = nil\n", /nil is not supported/],
  ["strings outside print", LOOP + 'local q = 0\nfunction f()\n  q = "hi"\nend\n', /only be used in print/],
  ["closures", "function _update60()\n  function inner() end\nend\nfunction _draw()\nend\n", /no closures/],
  ["int condition", "local x = 1\nfunction _update60()\n  if x then\n    x = 0\n  end\nend\nfunction _draw()\nend\n", /conditions must be boolean/],
  ["undeclared assignment", "function _update60()\n  y = 1\nend\nfunction _draw()\nend\n", /not declared.*no implicit globals/],
  ["'or' value idiom", LOOP + "local a = 1\nlocal b = 2\nfunction f()\n  a = a or b\nend\n", /needs boolean operands/],
  ["goto", LOOP + "function f()\n  goto top\nend\n", /goto is not supported/],
  ["exponent", LOOP + "local p = 2\nfunction f()\n  p = p ^ 2\nend\n", /exponent/],
  ["string concat", LOOP + "local a = 1\nfunction f()\n  a = a .. 2\nend\n", /concatenation is not supported yet/],
  ["non-constant top-level init", "local r = rnd(4)\n" + LOOP, /constant expression/],
  ["out-of-range literal", "local r = 99999\n" + LOOP, /outside the 16.16 range/],
];

for (const [name, src, re] of CASES) {
  test(`diagnostic: ${name}`, () => {
    const errs = errorsOf(src);
    assert.ok(errs.some((m) => re.test(m)),
      `expected an error matching ${re}\ngot:\n  ${errs.join("\n  ") || "(none)"}`);
  });
}
