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

for (const ex of ["starfall", "effects", "mode7", "windows", "anim", "hwtest", "hello"]) {
  test(`example ${ex} compiles`, () => {
    const src = readFileSync(path.join(REPO, `examples/${ex}/main.lua`), "utf8");
    const r = compile(src, "main.lua", { target: "gba" });
    assert.equal(r.ok, true, JSON.stringify(r.diagnostics, null, 2));
    assert.match(r.c, /int main\(void\)/);
  });
}

// ---- PICO-8 dialect --------------------------------------------------------------

test("// is a comment, backslash is floor division", () => {
  const c = cOf("local x = 8 // like this\nfunction _update60()\n  x = x \\ 2\nend\n" + "function _draw()\nend\n");
  assert.match(c, /gtl_x/);
});

test("!= is ~=", () => {
  const c = cOf("local x = 1\nfunction _update60()\n  if x != 2 then\n    x = 2\n  end\nend\nfunction _draw()\nend\n");
  assert.match(c, /!=/);
});

test("constant integer exponent expands to repeated multiplication", () => {
  const c = cOf("local d = 0\nlocal a = 3\nfunction _update60()\n  d = a ^ 2\nend\nfunction _draw()\nend\n");
  assert.doesNotMatch(c, /pow/);
});

test("string with escaped quote does not terminate early", () => {
  const c = cOf('function _update60()\nend\nfunction _draw()\n  print("a\\"b", 0, 0, 7)\nend\n');
  // the escaped quote survives: the emitted C keeps an escaped-quote sequence
  // inside a single string literal (the string did not terminate at the \").
  const printCall = c.match(/gba_print\([^\n]*\)/)?.[0] ?? "";
  assert.ok(printCall.includes('\\"'), printCall);       // an escaped quote is present
  assert.ok(printCall.startsWith('gba_print("a'), printCall);  // and it's one literal
});

test("paren-less string call desugars to a normal call", () => {
  const c = cOf('function _update60()\nend\nfunction _draw()\n  print"hi"\nend\n');
  assert.match(c, /gba_print/);
});

test("long string [[ ... ]] lexes as a string", () => {
  const c = cOf('function _update60()\nend\nfunction _draw()\n  print([[hello world]], 0, 0, 7)\nend\n');
  assert.match(c, /hello world/);
});

test("raw P8SCII button glyph lexes as its btn index", () => {
  // 🅾️ is btn index 4 (A on the GBA)
  const c = cOf("function _update60()\n  if btn(🅾️) then end\nend\nfunction _draw()\nend\n");
  assert.match(c, /gba_btn\(4/);
});

test("one-line if shorthand", () => {
  const c = cOf("local x = 0\nfunction _update60()\n  if (x < 1) x = 1\nend\nfunction _draw()\nend\n");
  assert.match(c, /if \(/);
});

test("if cond do ... end : minifier's 'do' is accepted as 'then'", () => {
  const c = cOf("local x = 0\nfunction _update60()\n  if x < 1 do x = 1 end\nend\nfunction _draw()\nend\n");
  assert.match(c, /gtl_x/);
});

test("one-line while shorthand", () => {
  const c = cOf("local x = 0\nfunction _update60()\n  while (x < 10) x += 1\nend\nfunction _draw()\nend\n");
  assert.match(c, /while \(/);
});

// ---- graphics codegen (GBA) ------------------------------------------------------

test("spr without flip: no flip packing needed", () => {
  const c = cOf("function _update60()\nend\nfunction _draw()\n  spr(1, 10, 20)\nend\n");
  assert.match(c, /gba_spr\(1, 10, 20/);
});

test("spr with flip_x/flip_y packs the two flags into one arg", () => {
  const c = cOf("function _update60()\nend\nfunction _draw()\n  spr(1, 10, 20, 1, 1, true, true)\nend\n");
  assert.match(c, /gba_spr\(1, 10, 20, 1, 1, /);
  assert.match(c, /<< 1/);   // flip_y shifted into bit 1
});

test("a color index passes through as its raw 0-15 index (GBA runtime palette)", () => {
  const c = cOf("function _update60()\nend\nfunction _draw()\n  rectfill(0, 0, 9, 9, 8)\nend\n");
  assert.match(c, /gba_rectfill\(0, 0, 9, 9, 8\)/);
});

test("button glyphs lex as indices", () => {
  const c = cOf("function _update60()\n  if btn(⬅️) then end\n  if btn(➡️) then end\nend\nfunction _draw()\nend\n");
  assert.match(c, /gba_btn\(0/);
  assert.match(c, /gba_btn\(1/);
});

test("sspr() emits the sheet blit with dw/dh defaulting to source size", () => {
  const c = cOf("function _update60()\nend\nfunction _draw()\n  sspr(0, 0, 8, 8, 20, 20)\nend\n");
  assert.match(c, /sspr|gba_/);
});

test("map() draws the imported tilemap; mget() reads a cell", () => {
  const c = cOf("local v = 0\nfunction _update60()\n  v = mget(1, 2)\nend\nfunction _draw()\n  map()\nend\n");
  assert.match(c, /gtl_v/);
});

// ---- data model ------------------------------------------------------------------

test("constant array table {1,2,3} becomes a fixed C array", () => {
  const c = cOf("local a = {1, 2, 3}\n" + LOOP);
  assert.match(c, /gtl_a\[3\] = \{\s*1, 2, 3\s*\}/);
});

test("array table with fractional values is a fixed array", () => {
  const c = cOf("local a = {1.5, 2.5}\n" + LOOP);
  assert.match(c, /gtl_a/);
});

test("bitwise function forms alias the operators (band/bor/shl/shr)", () => {
  const c = cOf("local x = 0\nfunction _update60()\n  x = band(6, 3)\n  x = bor(4, 1)\n  x = shl(1, 2)\n  x = shr(8, 1)\nend\nfunction _draw()\nend\n");
  assert.match(c, /&/);
  assert.match(c, /\|/);
  assert.match(c, /<</);
  assert.match(c, />>/);
});

test("multiple assignment (x, y = a, b) evaluates RHS first (swap-safe)", () => {
  const c = cOf("local x = 1\nlocal y = 2\nfunction _update60()\n  x, y = y, x\nend\nfunction _draw()\nend\n");
  assert.match(c, /gtl_x/);
  assert.match(c, /gtl_y/);
});

test("multiple return: return a,b,c and destructure a,b,c = f()", () => {
  const c = cOf("function f()\n  return 1, 2, 3\nend\nlocal x = 0\nlocal y = 0\nlocal z = 0\nfunction _update60()\n  x, y, z = f()\nend\nfunction _draw()\nend\n");
  assert.match(c, /gtl_f/);
});

test("array8 declares byte elements and reads back as ints", () => {
  const c = cOf("local a = array8(4)\nlocal v = 0\nfunction _update60()\n  v = a[1]\nend\nfunction _draw()\nend\n");
  assert.match(c, /unsigned char gtl_a\[4\]/);
});

test("array8 rejects fixed stores loudly", () => {
  const errs = errorsOf("local a = array8(4)\nfunction _update60()\n  a[1] = 1.5\nend\nfunction _draw()\nend\n");
  assert.ok(errs.length > 0);
});

// ---- audio (maxmod) --------------------------------------------------------------

test("sfx(n) emits gba_sfx with an auto-channel sentinel", () => {
  const c = cOf("function _update60()\n  sfx(3)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gba_sfx\(3, -1\)/);
});

test("sfx(n, ch) passes the explicit channel", () => {
  const c = cOf("function _update60()\n  sfx(3, 2)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gba_sfx\(3, 2\)/);
});

test("music(n) loops by default; music(-1) still routes to gba_music (stop)", () => {
  const c = cOf("function _init()\n  music(0)\nend\nfunction _update60()\n  music(-1)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gba_music\(0, 1\)/);
  assert.match(c, /gba_music\(\(-1\)/);
});

test("music(n, false) passes a non-loop flag", () => {
  const c = cOf("function _init()\n  music(0, false)\nend\n" + LOOP);
  assert.match(c, /gba_music\(0, /);
  assert.match(c, /\? 1 : 0/);   // the loop flag is a truthy-to-0/1 conversion
});

// ---- GBA-only verbs --------------------------------------------------------------

test("save/load compile to gba_save/gba_load with an array8", () => {
  const c = cOf("local st = array8(8)\nfunction _init()\n  if load(0, st, 8) > 0 then end\nend\nfunction _update60()\n  save(0, st, 8)\nend\nfunction _draw()\nend\n");
  assert.match(c, /gba_load\(0, gtl_st, 8\)/);
  assert.match(c, /gba_save\(0, gtl_st, 8\)/);
});

test("sprr emits the affine rotate+scale sprite", () => {
  const c = cOf("function _update60()\nend\nfunction _draw()\n  sprr(1, 60, 40, 0.25, 2.0)\nend\n");
  assert.match(c, /gba_sprr\(1, 60, 40/);
});

test("gt.* is refused loudly (GameTank-only namespace)", () => {
  const errs = errorsOf("function _update60()\n  gt.rgb(255, 0, 0)\nend\nfunction _draw()\nend\n");
  assert.ok(errs.some((m) => /GameTank-only/.test(m)), errs.join("; "));
});

// ---- harness ---------------------------------------------------------------------

test("a game with neither sfx nor music links no audio", () => {
  const c = cOf(LOOP);
  assert.doesNotMatch(c, /gba_music|gba_sfx/);
});

test("_update() and _update60() both compile the frame loop", () => {
  assert.match(cOf("function _update()\nend\nfunction _draw()\nend\n"), /int main\(void\)/);
  assert.match(cOf("function _update60()\nend\nfunction _draw()\nend\n"), /int main\(void\)/);
});
