# gtlua language specification — v0.1

gtlua is a statically-compiled subset of Lua 5.4 for the GameTank. It keeps
Lua's surface syntax over a fixed, integer-only semantic core that lowers to
C and compiles through cc65 to native 65C02 code. The design rule: **where
the subset has a wall, fail loudly at compile time with a message that says
what to write instead.** Silent divergence from either Lua or C behavior is
a bug in the compiler.

## Program structure

A program is one `.lua` file (modules/`require` land in a later release)
containing, at top level, only:

- `local name = <constant expression>` — module state, 16-bit integer
- `function name(params...) ... end` — function definitions

`function update()` is required; the runtime calls it every frame. `function
init()` is optional; it runs once at boot, after hardware init. The runtime
owns the frame: inputs are latched before `update()`, and after `update()`
returns the blitter is drained, vblank awaited, and the double buffer
flipped. There is no `gt.show()` to forget.

Top-level statements other than declarations are errors (put them in
`init()`), and top-level initializers must be compile-time constants.

## Types

v0.1 has two types, checked statically:

- **integer** — 16-bit signed (`int` in the generated C). All numeric
  literals (decimal or `0x` hex) are integers. Fractional literals are a
  compile error (16.16 fixed point is the planned `number` type, not yet
  implemented).
- **boolean** — `true` / `false`, the type of comparisons and `gt.btn*()`.

There is no `nil`, no implicit conversion in either direction between
integers and booleans, and no dynamic typing.

**Conditions must be boolean.** `if n then` where `n` is an integer is an
error. Rationale: Lua treats `0` as truthy and C as falsy; rather than pick
a side silently, gtlua requires the explicit comparison (`n ~= 0`).

## Statements

`local x = e` · assignment `x = e` · compound `x += e`, `x -= e`, `x *= e`,
`x //= k`, `x %= k` · `if / elseif / else / end` · `while cond do ... end` ·
`repeat ... until cond` · numeric `for i = a, b [, step] do ... end` ·
`break` · `return [e]` · function calls.

Numeric `for`: the limit is evaluated once (Lua semantics); `step` must be a
nonzero constant. The loop variable is a fresh local.

Variables must be declared with `local` before assignment — there are no
implicit globals. Function-local `local`s follow Lua scoping.

## Expressions

- Arithmetic: `+ - *` on integers. Overflow wraps at 16 bits (hardware
  semantics).
- `//` and `%`: the right operand must be a **constant power of two**; they
  lower to an arithmetic shift / mask, which match Lua's floor-division and
  modulo semantics for all signed operands. Anything else is an error — the
  6502 has no divide instruction, and gtlua refuses to hide a ~100-cycle
  routine behind one character. (`/` and `^` are always errors.)
- Comparisons: `== ~= < <= > >=` → boolean. `==`/`~=` also compare booleans.
- Logic: `and or not` on booleans only (the Lua `x or default` value idiom
  is not in the subset).
- Calls: user functions and the `gt.*` API. Functions are not values (no
  closures); recursion is currently permitted but will trap at compile time
  in a later release once the static call-graph allocator lands — avoid it.

## Cut features and their diagnostics

Every cut feature has a specific compile-time diagnostic (tested verbatim in
`test/compiler.test.js`): tables (→ structs/arrays roadmap), strings,
closures / anonymous / nested functions, coroutines, metatables, varargs,
multiple assignment/return, `goto`, method definitions and calls, `nil`,
fractional literals, `#`, `..`, generic `for ... in`.

## The gt module

See README for the v0.1 surface. `gt.*` names are resolved at compile time —
`gt` is not a table, and unknown members are compile errors. Two hardware
protocols are deliberately unreachable from the language: the blitter
busy/IRQ drain discipline and the DMA/bank register mirror dance. They live
inside the runtime (`sdk/gt_api.c`).

## Generated code contract (for debugging)

- Module variables become non-static C ints named `gtl_<name>` — they appear
  in the linker map and `build/<name>.lbl`, so tests and debuggers can
  assert game state by reading RAM.
- User functions become `static` C functions `gtl_<name>`.
- The generated C is committed to readability: fully parenthesized
  expressions, one Lua statement per C statement, and Lua block structure
  preserved.

## Roadmap (in order)

1. Tables as compile-time structs and fixed-size typed arrays
2. 16.16 fixed-point `number` (hand-written asm mul/div, 8.8 fast paths)
3. Sprites + GRAM loading (`gt.load_sprite`, `gt.draw_sprite`, art pipeline)
4. Sound (audio coprocessor firmware upload, `gt.note_on`, songs)
5. Strings + text rendering
6. `require` modules; later, multi-bank 2 MB cartridges
