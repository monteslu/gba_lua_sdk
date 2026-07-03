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

for (const ex of ["pad-square", "orbit", "mathcheck"]) {
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
  assert.match(c, /gt_p8_btn\(0, 0\)/);
  assert.match(c, /} else \{/);
});

test("one-line while shorthand", () => {
  const c = cOf("local x = 10\nfunction _update60()\n  while (x > 0) x -= 1\nend\nfunction _draw()\nend\n");
  assert.match(c, /while \(\(gtl_x > 0\)\)/);
});

test("button glyphs lex as indices", () => {
  const c = cOf("local x = 0\nfunction _update60()\n  if (btnp(🅾️)) x += 1\n  if (btnp(❎)) x -= 1\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_p8_btnp\(4, 0\)/);
  assert.match(c, /gt_p8_btnp\(5, 0\)/);
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

test("/ always produces fixed; general / uses gt_fdiv", () => {
  const c = cOf("local a = 3\nlocal b = 2\nlocal r = 0.0\nfunction _update60()\n  r = a / b\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_fdiv\(/);
});

test("/ by power-of-two constant becomes a shift", () => {
  const c = cOf("local a = 3.5\nlocal r = 0.0\nfunction _update60()\n  r = a / 4\nend\nfunction _draw()\nend\n");
  assert.match(c, /gtl_a >> 2/);
  assert.doesNotMatch(c, /gt_fdiv/);
});

test("fixed multiply goes through gt_fmul; int multiply stays native", () => {
  const c = cOf("local f = 1.5\nlocal i = 3\nlocal r = 0.0\nlocal s = 0\nfunction _update60()\n  r = f * f\n  s = i * i\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_fmul\(gtl_f, gtl_f\)/);
  assert.match(c, /\(gtl_i \* gtl_i\)/);
});

test("% by power of two masks; general int % is floored", () => {
  const c = cOf("local a = 9\nlocal b = 4\nlocal r = 0\nfunction _update60()\n  r = a % 8\n  r = a % b\nend\nfunction _draw()\nend\n");
  assert.match(c, /gtl_a & 7/);
  assert.match(c, /gt_ifmod\(gtl_a, gtl_b\)/);
});

test("polymorphic min/mid pick int or fixed variants", () => {
  const c = cOf("local i = 1\nlocal f = 0.5\nlocal r = 0\nlocal q = 0.0\nfunction _update60()\n  r = min(i, 3)\n  q = mid(0, f, 1)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gt_mini\(gtl_i, 3\)/);
  assert.match(c, /gt_midf\(0L, gtl_f, 65536L\)/);
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

test("add() grows the high-water mark when it appends a new top slot", () => {
  const c = cOf(POOL);
  assert.match(c, /for \(L_s\d+ = 0; L_s\d+ < gtl_ps_hi; \+\+L_s\d+\)/);
  assert.match(c, /if \(L_s\d+ >= gtl_ps_hi\) gtl_ps_hi = L_s\d+ \+ 1;/);
  // capacity is still the hard ceiling on placement
  assert.match(c, /if \(L_s\d+ < 8\)/);
});

test("del() snaps the high-water mark to 0 the moment the pool empties", () => {
  const c = cOf(POOL);
  assert.match(c, /--gtl_ps_n == 0 \? \(gtl_ps_hi = 0\) : 0/);
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
