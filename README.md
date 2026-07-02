# GameTank Lua SDK

Write [GameTank](https://gametank.zone/) games in Lua. This SDK compiles a
statically-typed Lua subset to C, builds it with cc65 against a bundled
GameTank runtime, and produces a flat 32 KB `.gtr` cartridge that runs in the
[emulator](https://github.com/clydeshaffer/GameTankEmulator), on
[gametank.zone](https://gametank.zone/), and on real hardware via
[GTFO](https://github.com/clydeshaffer/gtfo).

There is no interpreter and no VM on the cartridge — your Lua becomes native
65C02 machine code.

```lua
local x = 60
local y = 60

function update()
  if gt.btn(gt.LEFT) then x -= 2 end
  if gt.btn(gt.RIGHT) then x += 2 end
  if gt.btn(gt.UP) then y -= 2 end
  if gt.btn(gt.DOWN) then y += 2 end

  gt.cls(32)
  gt.box(x, y, 8, 8, 92)
end
```

## Requirements

- [Node.js](https://nodejs.org/) 18+ (runs the compiler)
- the cc65 toolchain — either on your `PATH`, or build it into the repo with:

```sh
scripts/install_tools.sh
```

## Quickstart

```sh
node bin/gtlua.js build examples/pad-square/main.lua
```

That produces `examples/pad-square/main.gtr` (~60 ms). Run it in the
GameTank emulator, or flash it to a cartridge.

`node bin/gtlua.js c <file.lua>` prints the generated C if you want to see
what your code becomes.

## Program structure

Every game defines `function update()` — the runtime calls it once per frame,
then ends the frame for you (drains the blitter, waits for vblank, flips the
double buffer). Define `function init()` for one-time setup. Top-level
`local`s are your game state; initialize them with constants.

Input is read for you before each `update()` — no polling boilerplate.

## The `gt` API (v0.1)

| Call | Does |
|---|---|
| `gt.cls(color)` | clear the full 128×128 screen |
| `gt.box(x, y, w, h, color)` | filled rectangle (blitter, clipped at edges) |
| `gt.btn(mask)` / `gt.btn2(mask)` | button held this frame (player 1 / 2) → boolean |
| `gt.btnp(mask)` / `gt.btnp2(mask)` | button newly pressed this frame → boolean |
| `gt.ticks()` | frames since boot (16-bit, wraps) |

Button masks: `gt.UP` `gt.DOWN` `gt.LEFT` `gt.RIGHT` `gt.A` `gt.B` `gt.C`
`gt.START`.

## The language

gtlua is Lua 5.4 surface syntax over a statically-compiled core, plus PICO-8's
compound assignment (`+=` `-=` `*=` `//=`). v0.1 supports 16-bit integers,
`if/elseif/else`, `while`, `repeat/until`, numeric `for`, functions with
parameters and returns, and booleans. See [SPEC.md](SPEC.md) for the full
reference, including the deliberate walls:

- **No general division.** `//` and `%` need a constant power-of-two on the
  right (the 6502 has no divide hardware). The error tells you what to do.
- **Conditions are boolean.** `if x then` on a number is a compile error —
  Lua calls 0 true, C calls it false, so gtlua requires `if x ~= 0 then`.
- No tables, strings, closures, coroutines, metatables, or floats — tables
  (as structs/arrays), fixed-point numbers, sprites, and sound are the
  roadmap, in that order.

Everything unsupported fails at compile time with a message that says what to
write instead. If you hit a silent wrong behavior, that's a bug — report it.

## Examples

- [`examples/pad-square`](examples/pad-square/main.lua) — move a square with
  the d-pad; A cycles color, B/C resize.

## Repo layout

- `compiler/` — the Lua→C compiler (plain JS ESM)
- `sdk/` — the C runtime the generated code links against (GameTank register
  protocols, interrupt handlers, cc65 startup/linker files)
- `bin/gtlua.js` — the CLI
- `test/` — compiler tests (`npm test`)

## License

MIT. The `sdk/` hardware files are adapted from
[clydeshaffer/gametank_sdk](https://github.com/clydeshaffer/gametank_sdk)
(MIT) — see [PROVENANCE.md](PROVENANCE.md).
