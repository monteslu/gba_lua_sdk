import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { compile } from "../compiler/index.js";

const REPO = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

const UPDATE = "function update()\nend\n";

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

// ---- things that must compile ------------------------------------------------

test("pad-square example compiles", () => {
  const src = readFileSync(path.join(REPO, "examples/pad-square/main.lua"), "utf8");
  const r = compile(src, "main.lua");
  assert.equal(r.ok, true, JSON.stringify(r.diagnostics, null, 2));
  assert.match(r.c, /void main\(void\)/);
  assert.match(r.c, /gt_update_inputs\(\);/);
});

test("module locals become exported C ints", () => {
  const c = cOf("local score = 10\n" + UPDATE);
  assert.match(c, /^int gtl_score = 10;$/m);
});

test("compound assignment lowers to C compound assignment", () => {
  const c = cOf("local x = 0\nfunction update()\n  x += 3\n  x *= 2\nend\n");
  assert.match(c, /gtl_x \+= 3;/);
  assert.match(c, /gtl_x \*= 2;/);
});

test("floor division by power of two lowers to a shift", () => {
  const c = cOf("local x = 64\nfunction update()\n  x = x // 8\nend\n");
  assert.match(c, /gtl_x >> 3/);
});

test("modulo by power of two lowers to a mask", () => {
  const c = cOf("local x = 64\nfunction update()\n  x = x % 16\nend\n");
  assert.match(c, /gtl_x & 15/);
});

test("numeric for evaluates the limit once", () => {
  const c = cOf("local n = 5\nfunction update()\n  for i = 1, n do\n    n += 1\n  end\nend\n");
  assert.match(c, /int L_lim0 = gtl_n;/);
  assert.match(c, /gtl_i <= L_lim0/);
});

test("gt constants and functions map to the runtime", () => {
  const c = cOf("function update()\n  if gt.btn(gt.LEFT) then\n    gt.cls(0)\n  end\nend\n");
  assert.match(c, /gt_btn\(GT_LEFT\)/);
  assert.match(c, /gt_cls\(0\)/);
});

test("mid-block local opens a nested C89 block", () => {
  const c = cOf("function update()\n  gt.cls(0)\n  local t = 3\n  gt.box(t, t, 4, 4, 7)\nend\n");
  // declaration must not follow a statement at the same block level
  assert.match(c, /\{ int gtl_t = 3;/);
});

// ---- the walls: every cut feature refuses loudly ------------------------------

const CASES = [
  ["update is required", "local x = 1\n", /must define 'function update\(\)'/],
  ["fractional literals", "local x = 1.5\n" + UPDATE, /fixed point.*not supported yet|fractional/i],
  ["general division", UPDATE + "local y = 1\nfunction f()\n  y = y / 2\nend\n", /no divide hardware/],
  ["floor div by non-power-of-two", UPDATE + "local y = 9\nfunction f()\n  y = y // 3\nend\n", /power-of-two/],
  ["tables", "local t = { x = 1 }\n" + UPDATE, /table constructors are not supported yet/],
  ["nil", UPDATE + "local z = nil\n", /nil is not supported/],
  ["strings", UPDATE + 'local s = "hi"\n', /strings are not supported yet/],
  ["anonymous functions", "local f = function() end\n" + UPDATE, /anonymous functions are not supported/],
  ["nested functions", "function update()\n  function inner() end\nend\n", /cannot be defined inside functions|no closures/],
  ["int condition", "local x = 1\nfunction update()\n  if x then\n    x = 0\n  end\nend\n", /conditions must be boolean/],
  ["undeclared assignment", "function update()\n  y = 1\nend\n", /not declared.*no implicit globals/],
  ["calling update yourself", "function update()\n  update()\nend\n", /called by the runtime/],
  ["multiple assignment", "local a, b = 1, 2\n" + UPDATE, /multiple assignment is not supported/],
  ["goto", UPDATE + "function f()\n  goto top\nend\n", /goto is not supported/],
  ["method definitions", "function gt.foo() end\n" + UPDATE, /method definitions/],
  ["exponent", UPDATE + "local p = 2\nfunction f()\n  p = p ^ 2\nend\n", /exponent/],
  ["bool where number expected", UPDATE + "local q = 0\nfunction f()\n  q = true + 1\nend\n", /boolean used where a number/],
  ["non-constant top-level init", "local r = gt.ticks()\n" + UPDATE, /constant expression/],
];

for (const [name, src, re] of CASES) {
  test(`diagnostic: ${name}`, () => {
    const errs = errorsOf(src);
    assert.ok(errs.some((m) => re.test(m)),
      `expected an error matching ${re}\ngot:\n  ${errs.join("\n  ") || "(none)"}`);
  });
}
