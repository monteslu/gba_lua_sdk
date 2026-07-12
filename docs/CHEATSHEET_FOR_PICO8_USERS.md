# gt-lua Cheat Sheet - for PICO-8 users

**PICO-8-flavored Lua that compiles to native 65C02** for the GameTank. No
interpreter, no VM - your Lua becomes machine code. The GameTank's 128×128
screen is the same size as PICO-8's, so coordinates and sprite sheets transfer
1:1. Measured against PICO-8 v0.2.7.

Build: `gtlua build main.lua --sheet gfx.gtg -o game.gtr`

> **New to PICO-8?** This page maps gt-lua *against* PICO-8. If you don't already
> know PICO-8, read the standalone [`CHEATSHEET.md`](CHEATSHEET.md) instead - it's
> the full gt-lua reference with no PICO-8 assumed.

**Status legend**

| Badge | Meaning |
|---|---|
| ✅ **exact** | works, PICO-8 semantics |
| 🟡 **partial** | works with documented limits |
| 🔷 **differs** | works but different by hardware |
| 🔵 **planned** | on the roadmap (`PICO8.md`), not yet built |
| ❌ **n/a** | no VM to emulate / deferred indefinitely |
| ➕ **gt extra** | GameTank-only, beyond PICO-8 |

Names are **global and unprefixed**, exactly like PICO-8. The `gt.*` namespace
is GameTank-only extras.

---

## The 16 PICO-8 colors → GameTank byte

Colors are raw GameTank bytes `0`–`255`. A **static 0–15 literal** in a draw
call (`cls(1)`) is treated as a PICO-8 index and baked to its GameTank byte at
COMPILE time (no runtime palette). `gt.rgb(r,g,b)` / `gt.rgb(byte)` reach the
full palette - **P8 devs get more colors, not fewer.**

⚠️ A color your game **computes at runtime** (a variable, `frame%2 and 7 or 8`,
a table value) is used as a **raw byte**, NOT re-mapped from 0–15 - so a ported
palette-cycle or flash effect renders wrong colors. Fix by computing a GameTank
byte or using `gt.rgb`. (No PICO-8 palette layer at runtime; see PALETTE.md.)

| # | name | GT byte | RGB | | # | name | GT byte | RGB |
|--:|------|--:|------|---|--:|------|--:|------|
| 0 | black | 0 | `#1a1a1a` | | 8 | red | 91 | `#a64a5e` |
| 1 | dark-blue | 169 | `#1f334a` | | 9 | orange | 62 | `#d69b4b` |
| 2 | dark-purple | 90 | `#8e3348` | | 10 | yellow | 31 | `#b9c541` |
| 3 | dark-green | 219 | `#17725d` | | 11 | green | 254 | `#70b94f` |
| 4 | brown | 51 | `#805924` | | 12 | blue | 190 | `#70a8f4` |
| 5 | dark-grey | 3 | `#5d5d5d` | | 13 | lavender | 140 | `#75719b` |
| 6 | light-grey | 6 | `#a1a1a1` | | 14 | pink | 94 | `#ea8ca2` |
| 7 | white | 7 | `#b9b9b9` | | 15 | peach | 47 | `#cbb79f` |

*(Colors are the GameTank's own palette bytes - the RGB shown is what the
console actually displays, not PICO-8's originals. The RGB is the CAPTURE
palette, GameTank's hardware-accurate default. It's muted vs PICO-8: no pure
white/black, softer primaries. Full rationale + per-color notes:
[docs/PALETTE.md](PALETTE.md).)*

---

## Controller → `btn()` index

```
        [2]↑                O = 4  🅾️ → GameTank A
    [←]0    1[→]            X = 5  ❎ → GameTank B
        [3]↓                C = 6  → GameTank C  (extra button - P8 has no 6!)
                            START = 7
```

`btn(i,[pl])` held · `btnp(i,[pl])` just-pressed with P8 auto-repeat (15 frames,
then every 4). Two pads via the `pl` argument. Glyphs `⬅️ ➡️ ⬆️ ⬇️ 🅾️ ❎` lex as
constants 0–5 in source.

---

## Program structure

| Call | | Notes |
|---|:--:|---|
| `_init()` | ✅ | runs once at startup |
| `_update60()` | ✅ | logic @ 60 fps (per vsync) |
| `_update()` | ✅ | logic @ 30 fps (every 2nd vsync) |
| `_draw()` | ✅ | 1× per visible frame |

No cartridge loop / `goto` tweetcart form - `_draw()` **is** the loop.

## Dialect & syntax

| Feature | | Notes |
|---|:--:|---|
| `a \ b` | 🟡 | floored int divide `flr(a/b)` - **power-of-two divisor** for now |
| `//` | ✅ | a line comment, like PICO-8 |
| `a != b` | ✅ | alias of `~=` |
| `if (c) stmt else stmt` | ✅ | one-line if / while, parens required |
| `+= -= *= \= %=` | ✅ | LHS evaluated **once** (P8 does it twice) |
| `x,y = 64,32` | ✅ | multiple assignment / return |
| `for i=1,10,2` | ✅ | fractional & negative steps ok |
| `sfx"3"  print"hi"` | ✅ | paren-less string calls |
| `🅾️ ❎ ⬅️ ➡️ ⬆️ ⬇️` | ✅ | glyphs → constants 0–5 |

## Number model

Full **16.16 fixed point**, PICO-8 edge cases and all - it maps to the 6502 for
free (Lexaloffle designed it for exactly this class of machine).

| | | Notes |
|---|:--:|---|
| range | ✅ | −32768.0 … 32767.99999 |
| overflow | ✅ | wraps (two's complement) |
| `a / 0` | ✅ | saturates ±0x7fff.ffff |
| `sin(.25) == -1` | ✅ | turns-based, screen-inverted |
| `sgn(0) == 1` | ✅ | `flr` toward −∞ |
| `>>` / `>>>` | ✅ | arithmetic / logical shift |

**gt speed knob:** `--num8` builds switch to 8.8 fixed (±127.99) - cuts the
32-bit math tax hard on physics-heavy carts.

## Graphics & draw

| Call | | Notes |
|---|:--:|---|
| `cls([c])` | ✅ | blitter full-screen fill |
| `spr(n,x,y,[w,h],[fx,fy])` | ✅ | 8×8 cell 0–255; flips are hardware |
| `rectfill / rect(x0,y0,x1,y1,c)` | ✅ | inclusive corners (P8 gotcha kept) |
| `circfill / circ(x,y,r,c)` | ✅ | blitter row-run fills |
| `line(x0,y0,x1,y1,c)` | ✅ | CPU Bresenham |
| `pset / pget(x,y,[c])` | ✅ | |
| `sset(x,y,c)` | ✅ | write a sheet pixel (bake sprites) |
| `camera([x,y])` | ✅ | sticky draw offset |
| `color(c)` | ✅ | |
| `sspr(...)` | 🟡 | unscaled rect blit works; **scaled = compile error** |
| `clip(x,y,w,h)` | 🔵 | screen-edge only today; software-clip v0.3+ |
| `fillp`, `tline` | ❌ | deferred indefinitely |

## Palette & transparency - the largest real gap

| Call | | Notes |
|---|:--:|---|
| `pal(...)` | ❌ | **removed** - colors are raw GameTank bytes, there is no runtime remap table |
| `palt(0,on)` | 🟡 | color-0 transparency toggle |
| `palt(c,true)`, c≠0 | 🔷 | compile error with a fix-it |

GameTank framebuffer bytes **are** colors - no CLUT between GRAM and screen, and
no PICO-8 palette layer. `pal()` (index remap / per-draw sprite recolor) does not
exist. To recolor: pre-author the recolored sheet cells (the standard GameTank
idiom - Celeste's blue-hair frames are baked at asset time), or draw with a
different `gt.rgb` byte. The full-screen `pal(t,1)` fade idiom needs a `gt.*`
redraw-tinted path.

## Input

| Call | | Notes |
|---|:--:|---|
| `btn(i,[pl])` | ✅➕ | held; i = 0–7 (6 = GameTank C is a bonus button) |
| `btnp(i,[pl])` | ✅➕ | just-pressed, P8 auto-repeat |

## Math

| Call | | Notes |
|---|:--:|---|
| `flr ceil abs sgn sqrt(x)` | ✅ | |
| `min max(x,y)` · `mid(x,y,z)` | ✅ | |
| `sin cos(x)` · `atan2(dx,dy)` | ✅ | 256-entry ROM turn table |
| `rnd(x)` · `srand(x)` | ✅ | 16-bit xorshift; `flr(rnd(n))` exact |
| `t()` · `time()` | ✅ | frames÷60 as fixed seconds |
| bitwise `& \| ^^ << >>` … | ✅ | as operators (band/bor/… names → ops) |

## Tables & entities

| Call | | Notes |
|---|:--:|---|
| `ps = pool(16)` | 🟡 | capacity-bounded (no unbounded growth / GC) |
| `add(ps,{x=1,y=2})` | ✅ | traps past capacity in debug builds |
| `del(ps,e)` | ✅ | delete-while-iterating ok |
| `for e in all(ps) do` | ✅ | insertion order |
| `array(n)` / `array8(n)` | 🟡➕ | fixed / byte-wide arrays |

**Cut (compiled subset):** nil / `x or default`, closures, metatables/OOP,
coroutines. Use named functions + a `kind` field + `if/elseif` state machines -
the compiler errors loudly with the fix.

## Audio

| Call | | Notes |
|---|:--:|---|
| `sfx(n,[ch])` | 🟡 | built-in bank 0–7, or your imported cart |
| `music(n,[fade])` | 🟡 | built-in 0–1; `music(-1)` stops |
| `sfx_bank / music_bank(data)` | 🟡➕ | register converted PICO-8 `__sfx__`/`__music__` |

Zero-authoring built-ins: `sfx(0)`=jump, 1=pickup, 2=shoot, 3=explode, 4=blip,
5=powerup, 6=hurt, 7=select. Rendered on the ACP's 4-op FM voices (a second
65C02). Import a cart's own tracker bytes with **`bin/p8sfx.mjs`** →
`sfx_bank()`.

## Strings & print

| Call | | Notes |
|---|:--:|---|
| `print(str,[x,y],[c])` | ✅ | returns right-edge x (4×6 font) |
| `?expr` | ✅ | print shorthand |
| `s = "hello"` | ✅ | string literals |
| `s .. s2` | 🔵 | runtime concat - v0.5 |
| `sub tostr tonum chr ord split` | 🔵 | v0.5 |

Bake dynamic text into byte buffers and draw with `gt.print_buf` for HUDs (the
fast path); no runtime string building yet.

## Map / tiles

| Call | | Notes |
|---|:--:|---|
| `map(tx,ty,sx,sy,tw,th,[lyr])` | 🔵 | v0.4 |
| `mget / mset(x,y,[v])` | 🔵 | v0.4 |
| `fget / fset(n,[f],[v])` | 🔵 | tile flags - v0.4 |

**gt has it a different way today:** `gt.bg_compose` pre-paints a tilemap into a
spare GRAM page once, then `gt.bg_draw` blits the whole page per frame - the
shipped tilemap path. Ports drive scrolling worlds with `gt.chunks_draw` asm
engines.

## Cartridge data / save

| Call | | Notes |
|---|:--:|---|
| `cartdata("id")` | 🔵 | v0.4 |
| `dget / dset(i,[v])` | 🔵 | 0..63 persistent slots - v0.4 |

The GameTank SAVE bank hardware exists for exactly this; the API layer is
planned, not yet wired.

## Memory / low-level - n/a by design

| Call | | Notes |
|---|:--:|---|
| `peek / poke(addr,[v])` | ❌ | P8's flat-memory pokes |
| `memcpy memset cstore` | ❌ | |
| `stat(x)` · `menuitem` | ❌ | |

PICO-8's memory map (`0x6000` screen, `0x5f00` draw state…) **doesn't exist** -
there's no VM to poke. Real GameTank hardware registers are reached through
`gt.*` helpers and raw-color bytes, not a P8-compatible address space.

---

## What `gt.*` adds beyond PICO-8

| Call | Notes |
|---|---|
| `gt.rgb(r,g,b)` / `gt.rgb(byte)` | the full 256-color GameTank palette |
| `gt.border(c)` | overscan border color |
| `gt.bg_compose` / `gt.bg_draw` | cache a static layer in GRAM, 1 blit/frame |
| `gt.print_buf(buf,off,x,y,c)` | fast HUD text from byte buffers |
| `gt.pool_move` / `pool_anim` / `pool_sprs` / `pool_edraw` | bulk entity update/draw in one asm walk |
| `gt.balls_step` / `balls_draw` / `balls_drag` | physics engine (collision pairs, integrate) |
| `gt.starfield_*` / `gt.circf` / `gt.chunks_draw` | staged-blit asm draw engines |
| `hexdata("…")` | compile-time byte blob → ROM |

These exist because native code has no cycle governor: you get the whole
3.5 MHz. The constraint moves from PICO-8's 8192-token cap to **ROM/RAM size** -
and to the blitter, which these engines feed efficiently.

---

## The 6 things to unlearn

1. Colors are raw GameTank bytes. A static 0–15 literal is baked from the PICO-8
   palette at build time; a **runtime-computed** color is a raw byte (a computed
   0–15 index renders wrong). No `pal()`, no runtime palette.
2. `palt` is color-0 only.
3. Conditions must be boolean - `if (n)` on a number is an error (P8 calls 0
   truthy, we won't guess).
4. No nil, so `x = x or default` is gone; tables are capacity-bounded; no
   closures / metatables / coroutines.
5. No token/cycle cap - games get all 3.5 MHz; the limit is ROM/RAM size.
6. `sfx/music` play a native FM bank by index (or your converted cart), not raw
   PICO-8 SFX bytes.

---

## Hello, GameTank

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

`gtlua build main.lua --sheet gfx.gtg -o game.gtr` → runs in the emulator, on
gametank.zone, and on real hardware via GTFO.

---

*Status reflects the shipped implementation, cross-checked against the compiler
builtins and the SDK runtime. The roadmap targets full Tier-0/1 PICO-8 parity
where the hardware allows, and fails loudly (with a fix-it) where it can't.
PICO-8 is by Lexaloffle Games; the GameTank is Clyde Shaffer's open 8-bit
console.*
