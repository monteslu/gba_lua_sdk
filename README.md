# GameTank Lua SDK

Make games for the [**GameTank**](https://gametank.zone/) - Clyde Shaffer's open
8-bit console (65C02 CPU, hardware blitter, a 128×128 screen) - by writing Lua
instead of 6502 assembly or C.

Write games in a **PICO-8-flavored Lua** dialect. The SDK compiles it to C,
builds it with cc65 against a bundled GameTank runtime, and produces a `.gtr`
cartridge (a flat 32 KB EEPROM, or a 2 MB FLASH2M banked cart for bigger games -
chosen automatically) that runs in the
[emulator](https://github.com/clydeshaffer/GameTankEmulator), on
[gametank.zone](https://gametank.zone/), and on real hardware via
[GTFO](https://github.com/clydeshaffer/gtfo).

No interpreter, no VM: your Lua becomes native 65C02 machine code. The
screen is the same 128×128 as PICO-8's, and the API is PICO-8-shaped
(`spr`/`btn`/`_init`/`_update`/`_draw`, Lua syntax), so if you know PICO-8 you'll
feel at home - but gt-lua is its own thing targeting real GameTank hardware, not
a PICO-8 clone. If you don't know PICO-8, you don't need to.

```lua
local angle = 0
local radius = 40

function _update60()
  angle += 0.008
  if (btn(0)) radius -= 1
  if (btn(1)) radius += 1
  radius = mid(8, radius, 58)
end

function _draw()
  cls(1)
  circfill(64, 64, 10, 9)
  circfill(64 + flr(cos(angle) * radius),
           64 + flr(sin(angle) * radius), 5, 8)
end
```

## Requirements

- [Node.js](https://nodejs.org/) 18+ (runs the compiler)
- the cc65 toolchain - either on your `PATH`, or built into the repo with
  `scripts/install_tools.sh`

## Quickstart

This is a **clone-and-build SDK** (like the official GameTank C SDK) - not an
npm package. Clone it, write your game as a `.lua` file, and build:

```sh
git clone https://github.com/monteslu/gametank_lua_sdk && cd gametank_lua_sdk
scripts/install_tools.sh                 # builds cc65 into tools/ (once)

# build one of the examples to confirm your setup:
node bin/gtlua.js build examples/orbit/main.lua
# -> examples/orbit/main.gtr, in under 100 ms
```

Run the `.gtr` in the [emulator](https://github.com/clydeshaffer/GameTankEmulator),
on [gametank.zone](https://gametank.zone/), or flash it to a cartridge.

### Start your own game

Copy an example as a starting point and build your `main.lua`:

```sh
cp -r examples/orbit mygame
node bin/gtlua.js build mygame/main.lua -o mygame/game.gtr
# --sheet mygame/gfx.gtg     add a sprite sheet (see docs/GRAPHICS.md)
# --frames mygame/gfx.gsi    add a frame table for sprf (docs/SPRITES.md)
# --num8                     8.8 number mode, faster math (docs/performance.md)
```

`node bin/gtlua.js c <file.lua>` prints the generated C (for debugging).

### Visual Studio Code

The repo ships VS Code tasks for one-key build & run. Open the folder in VS
Code, open any `.lua`, and:

- **Ctrl+Shift+B** (Cmd+Shift+B on macOS) runs **gtlua: Build** on the open file,
  producing `<name>.gtr` next to it.
- **gtlua: Build & Run** (from *Terminal → Run Task…*) builds, then launches the
  ROM in a detected emulator.

The **Run** task finds an emulator the same way the `run_emulator` scripts do:
the `GAMETANK_EMULATOR` env var first, then `gte` or `GameTankEmulator` on your
`PATH`. Point `GAMETANK_EMULATOR` at your
[GameTankEmulator](https://github.com/clydeshaffer/GameTankEmulator) build if
it isn't on `PATH`.

## The PICO-8 contract

Define `_update60()` (60 fps) or `_update()` (30 fps), plus `_draw()`, and
optionally `_init()`. The runtime latches inputs before each update and ends
the frame after `_draw()` (blitter drain, vblank, page flip).

**Numbers are PICO-8 numbers**: 16.16 fixed point, −32768 to 32767.99998,
wrap on overflow, division by zero saturates. `sin`/`cos`/`atan2` use turns
(0..1) with PICO-8's screen-space-inverted sin. Under the hood the compiler
infers which values stay integral and keeps them in fast 16-bit ints - an
optimization, never a semantic change.

**The dialect** keeps PICO-8's syntax: `+=`-style compound assignment,
one-line `if (cond) stmt` / `while (cond) stmt`, `!=`, `\` floor division,
`//` comments, hex/binary literals with fractions (`0x11.4`, `0b101.1`),
button glyphs (`⬅️➡️⬆️⬇️🅾️❎`), and multiple assignment (`x, y = 64, 32`).

**Have a PICO-8 cart to bring over?** [docs/PORTING.md](docs/PORTING.md) is the
step-by-step walkthrough (import the art with `gtlua gfx import`, the sound with
`p8sfx`, and what changes because the GameTank is different hardware); the
per-function compatibility map is
[docs/CHEATSHEET_FOR_PICO8_USERS.md](docs/CHEATSHEET_FOR_PICO8_USERS.md).

## API (v0.2)

| | |
|---|---|
| lifecycle | `_init` `_update` `_update60` `_draw` |
| graphics | `cls` `camera` `color` `pset` `rect` `rectfill` `circ` `circfill` `line` `sset` `spr(n,x,y,[w,h],[flip_x,flip_y])` - flips are free (hardware blitter mirror) |
| sprites | 8×8-grid `spr(n)` off a `.gtg` sheet (`--sheet`, [docs/GRAPHICS.md](docs/GRAPHICS.md)); `sprf(frame,x,y,[fx],[fy])` for arbitrary-size / animated frames off a `.gsi` table ([docs/SPRITES.md](docs/SPRITES.md)) |
| input | `btn(i,[pl])` `btnp(i,[pl])` - indices 0-3 d-pad, 4=🅾️(GT A), 5=❎(GT B), **6=GT C**, 7=START; `btnp` has PICO-8 auto-repeat |
| math | `flr` `ceil` `abs` `sgn` `sqrt` `min` `max` `mid` `sin` `cos` `atan2` `rnd` `srand` `t`/`time` |
| data | `array(n,[v])` - 16-bit elements · `array8(n,[v])` - byte elements 0-255, half the RAM and ~2× faster in counting loops |
| sound | `sfx(n,[ch])` `music(n,[loop])` (built-in FM effects/tunes - see below); `song(data,[loop])` plays a native `.gtm2` FM song ([docs/MUSIC.md](docs/MUSIC.md)); low-level `gt.note`/`gt.noteoff` |
| gametank extras | `gt.rgb(b)` - raw palette byte (the GameTank has 256 colors), `gt.border(c)`, `gt.ticks()`, `gt.starfield_*`, `gt.bg_compose`/`gt.bg_draw` (see below) |

Colors are raw GameTank bytes `0`–`255`. For PICO-8 familiarity, a **static
0–15 color literal** in a draw call (`cls(1)`, `rectfill(...,8)`) is baked to its
GameTank byte at compile time (zero runtime cost). `gt.rgb()` reaches the full
256-color palette: `gt.rgb(255,128,0)` picks the nearest hardware color to that
RGB, or `gt.rgb(byte)` takes a raw byte. Use it anywhere a color is expected:
`rectfill(x,y,w,h, gt.rgb(255,128,0))`. A color **computed at runtime** is used
as a raw byte, not re-mapped from 0–15 (see [docs/PALETTE.md](docs/PALETTE.md));
there is no runtime `pal()`.

### Fast backgrounds: `gt.bg_compose` / `gt.bg_draw`

Drawing a tilemap with a per-tile `spr()` loop costs one blit per visible
tile, and on the GameTank a blit is ~1200 cycles of setup *regardless of
size* - a screenful of tiles blows the ~50-blit/frame budget for 30fps. The
GameTank has 512 KB of sprite RAM (32 pages of 128×128) and the SDK normally
uses only one (the sheet), so you can pre-render a static background into a
spare page **once** and blit the whole thing as a single cheap blit each frame:

```lua
local map = array(16*16)          -- your tile indices (0 = empty)
function _init()
  -- ... fill map from your level data ...
  gt.bg_compose(map, 16, 0, 0, 16, 16)  -- (map, cols, cx, cy, cw, ch) -> bg page
end
function _draw()
  gt.bg_draw()                    -- one big blit of the composed page
  -- then draw your moving sprites on top with spr()
end
```

`gt.bg_compose` reads tiles from the loaded `--sheet` (cell N is at sheet cell
`(N%16, N//16)`), clears the page to color 0, and paints the `cw×ch` window
starting at map cell `(cx,cy)`; tile 0 is left empty. It's a one-time cost of
up to a second or so of CPU time (the canvas clear alone is 64 KB of writes) -
call it at level load, not every frame, and expect the screen to sit black
until `_init` returns.

The bg page is a **256×256 canvas** (`cw`/`ch` up to 32 cells), so a level
bigger than one screen composes once and **scrolls for free**: `gt.bg_draw(sx,
sy)` blits a 128×128 window at source offset `(sx,sy)` (0–128 in each axis),
seamlessly across the internal page boundaries - pass your camera position to
scroll. Moving/animated tiles still want `spr()` on top.

### Sound: `sfx` / `music`

The GameTank has a second 65C02 audio coprocessor (a 4-channel, 4-operator FM
synth). PICO-8 style, you trigger sound by index - no tracker files to author:

```lua
function _init()
  music(0)              -- start built-in tune 0, looping
end
function _update60()
  if btnp(4) then sfx(0) end     -- 🅾️ -> jump sound
  if btnp(5) then sfx(3) end     -- ❎ -> explosion
end
```

Built-in **effects** (`sfx(n,[ch])`, n = 0–7): `0` jump · `1` pickup · `2`
shoot · `3` explode · `4` blip · `5` powerup · `6` hurt · `7` select. Omit
`ch` to auto-assign one of the 4 channels, or pass `0–3` to pin it. Built-in
**tunes** (`music(n,[loop])`, n = 0–1): loops by default; `music(-1)` stops,
`music(n,false)` plays once. A per-frame sequencer (ported from the upstream
GameTank tracker) advances envelopes + steps the song automatically - it costs
almost nothing when nothing is playing. For a single raw tone, the low-level
`gt.note(ch,note,vol)` / `gt.noteoff(ch)` primitives are still there.

Shipped since: native `.gtg` sprite sheets + `.gsi`/`sprf` frame tables, native
`.gtm2` FM songs, a `gtlua gfx` converter, and a PICO-8 art/sound importer.
Coming next (see [docs/PICO8.md](docs/PICO8.md) for the full roadmap): `map`/
`mget`/`fget` tile APIs, `print`-time string building, and `cartdata` saves.

## Not-Lua walls (loud, never silent)

Conditions must be boolean (`if x ~= 0 then`, not `if x then` - Lua calls 0
truthy, C doesn't, gtlua refuses to guess). No `nil`, closures, metatables,
coroutines, or `goto`. Every unsupported feature is a compile-time error
that says what to write instead.

## Repo layout

`compiler/` Lua→C compiler (plain JS ESM) · `sdk/` the C/asm runtime
(register protocols, fixed-point core, math tables, interrupt handlers,
cc65 startup/linker files) · `bin/gtlua.js` CLI · `tools/` cc65 (built by
`scripts/install_tools.sh`) · `examples/` · `test/` (`node --test`).

## Docs

| doc | what |
|---|---|
| [docs/CHEATSHEET.md](docs/CHEATSHEET.md) | the full gt-lua API reference |
| [docs/CHEATSHEET_FOR_PICO8_USERS.md](docs/CHEATSHEET_FOR_PICO8_USERS.md) | per-function PICO-8 compatibility map |
| [docs/PORTING.md](docs/PORTING.md) | bringing a PICO-8 cart over, step by step |
| [docs/GRAPHICS.md](docs/GRAPHICS.md) | the `.gtg` sprite-sheet format + `gtlua gfx` converter |
| [docs/SPRITES.md](docs/SPRITES.md) | frame tables (`.gsi`) + `sprf` |
| [docs/MUSIC.md](docs/MUSIC.md) · [docs/sfx.md](docs/sfx.md) | native `.gtm2` FM songs · PICO-8 sfx import |
| [docs/PALETTE.md](docs/PALETTE.md) | the GameTank color palette |
| [docs/performance.md](docs/performance.md) | making it fast (`--num8`, blit budget, the `gt.*` engines) |
| [docs/SPEC.md](docs/SPEC.md) · [docs/PICO8.md](docs/PICO8.md) | language spec · design doc + roadmap |
| [PROVENANCE.md](PROVENANCE.md) | attribution (Clyde Shaffer's GameTank SDK) |

The `examples/` in this repo are small, self-contained gt-lua programs (orbit,
mathcheck, pad-square, audio) - the quickest way to see the API in use. Full
games built with gt-lua live in their own repos (each a derivative work under
its own license): Combo Pool, newleste, Cherry Bomb, and more.

## Making it fast

The GameTank is ~1000× slower than the machine PICO-8 runs on, so a naive port
can drop to single-digit fps. **[docs/performance.md](docs/performance.md)** is
the field guide: the two things that dominate a frame (blit count and
fixed-point math), the ~19,000-cycle fixed-point `%` / `/` footgun and how to
dodge it, per-primitive blit budgets, and how to profile a slow cart by
bisection. Read it before optimizing - measure, don't guess.

## License

MIT. `sdk/` hardware files adapted from
[clydeshaffer/gametank_sdk](https://github.com/clydeshaffer/gametank_sdk) (MIT).
