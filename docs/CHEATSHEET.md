# gt-lua Cheat Sheet

**Write games in Lua for the [GameTank](https://gametank.zone)** - Clyde
Shaffer's little 8-bit console. You write regular Lua; it gets turned into a real
`.gtr` game cartridge you can play in the browser or on the actual hardware.

It's a small screen (128×128), a sheet of little 8×8 pictures (sprites), and
three functions you fill in. This one page is the whole language - if you've
played with something like PICO-8 before, you already get it.

```
gtlua build main.lua --sheet gfx.gtg -o game.gtr
```

Runs in the emulator, on gametank.zone, and on real hardware via a GTFO cart.

---

## Program structure - the 3 functions

Every game fills in these three functions:

```lua
function _init()
  -- runs ONCE when the game starts
end

function _update()
  -- your game logic; runs 30 times a second
end

function _draw()
  -- your drawing; runs once per frame
end
```

That's the whole loop - the GameTank calls `_update()` then `_draw()` over and
over for you. To move something, add a little to its position each `_update()`.
Here's a dot that slides across the screen and wraps around:

```lua
local x = 0

function _update()
  x += 1              -- move right 1 pixel each update (bigger = faster)
  if x > 127 then
    x = 0             -- wrap back to the left edge
  end
end

function _draw()
  cls(1)              -- clear to dark blue
  circfill(x, 64, 5, 8)  -- a red dot at (x, 64)
end
```

You never deal with clocks or timers - just "how much per update," and you tune
that number until it feels right.

> **Want it smoother?** Name your update `_update60` instead and the GameTank
> calls it 60 times a second. But 30 is the safe default: it's the speed the
> GameTank can keep up with once your game is doing a lot. If a busy game uses
> `_update60` and can't keep up, it runs in **slow motion** - so only reach for
> 60 on small, simple games.

---

## Controllers

```
        [2] ↑                       button → index
   [←] 0     1 [→]            LEFT 0   RIGHT 1   UP 2   DOWN 3
        [3] ↓                    A 4       B 5      C 6   START 7
       (A)4  5(B)  6(C)
```

The GameTank pad has **three** face buttons - A(4), B(5), and **C(6)**, plus
START(7). Two players via the optional second argument.

| Call | Returns | Notes |
|---|---|---|
| `btn(i, [pl])`  | bool | held this frame. `pl` = 0 or 1 (default 0) |
| `btnp(i, [pl])` | bool | *just* pressed, with auto-repeat (15 frames, then every 4) |

The glyphs `⬅️ ➡️ ⬆️ ⬇️ 🅾️ ❎` are literal constants `0`–`5` in source, so
`if (btn(⬅️))` reads nicely.

---

## Colors

A color is a raw GameTank byte `0`–`255`. For familiarity, a **static 0–15
literal** in a draw call is treated as a PICO-8 index and baked to its GameTank
byte at **compile time** (the table below); `gt.rgb` reaches every color the GameTank has. A color **computed at runtime** is a raw byte, not re-mapped from 0–15
(a computed index renders wrong) - there is no runtime palette or `pal()`.

| # | name | byte | | # | name | byte |
|--:|------|-----:|-|--:|------|-----:|
| 0 | black       | 0   | | 8  | red      | 91  |
| 1 | dark-blue   | 169 | | 9  | orange   | 62  |
| 2 | dark-purple | 90  | | 10 | yellow   | 31  |
| 3 | dark-green  | 219 | | 11 | green    | 254 |
| 4 | brown       | 51  | | 12 | blue     | 190 |
| 5 | dark-grey   | 3   | | 13 | lavender | 140 |
| 6 | light-grey  | 6   | | 14 | pink     | 94  |
| 7 | white       | 7   | | 15 | peach    | 47  |

```lua
color(8)                 -- set the current pen to red
gt.rgb(255, 40, 0)       -- a raw RGB color (nearest hardware byte)
gt.rgb(91)               -- a raw palette byte directly
gt.border(1)             -- overscan border color
```

> **Color 0 is transparent** for sprites (the colorkey). The framebuffer bytes
> *are* colors - there's no lookup table between memory and the screen.

---

## Drawing

```
   (0,0) ┌─────────────┐          coordinates are 0..127
         │             │          rect/rectfill corners are INCLUSIVE
         │      +       │  ← camera() shifts every draw call
         │             │
         └─────────────┘ (127,127)
```

| Call | Draws |
|---|---|
| `cls([c])` | clear screen (blitter fill), default color 0 |
| `spr(n, x, y, [w, h], [fx, fy])` | sheet cell `n` (0-255); `w×h` cells; `fx/fy` = hardware flip |
| `rect(x0,y0,x1,y1,c)` / `rectfill(...)` | box outline / filled - **corners inclusive** |
| `circ(x,y,r,c)` / `circfill(...)` | circle outline / filled |
| `line(x0,y0,x1,y1,c)` | line (CPU Bresenham) |
| `pset(x,y,[c])` / `pget(x,y)` | one pixel |
| `sset(x,y,c)` | write a pixel into the **sprite sheet** (bake sprites at runtime) |
| `camera([x,y])` | sticky draw offset added to everything (no args = reset) |
| `color(c)` | set the default pen color |

```lua
spr(1, x, y)                 -- one 8×8 cell
spr(64, x, y, 2, 2)          -- a 16×16 sprite (4 cells)
spr(1, x, y, 1, 1, true)     -- flipped horizontally
```

**Palette / transparency.** Framebuffer bytes *are* colors - there is no CLUT
and no `pal()` (it's removed). To recolor a sprite, pre-author the recolored
cells in the sheet (the standard GameTank idiom), or draw with a different
`gt.rgb` byte. Transparency is color-0 only. The compiler tells you (with a
fix-it) if you reach for the parts that aren't here.

---

## Numbers - 16.16 fixed point

Everything is signed **16.16 fixed point** (a whole part and a 16-bit
fraction). This is *not* a limitation - it's the natural number format for a
6502, and it comes with clean, predictable edge cases.

```
 range      -32768.0 … 32767.99998
 overflow   wraps (two's complement)
 a / 0      saturates to ±32767.99998
 flr        rounds toward -∞    sgn(0) == 1
```

Literals: `1`, `0.5`, `-3.25`, `0x1a`, binary via bit ops. Write decimals
freely - `angle += 0.008` is exact.

> **Speed knob:** build with `--num8` to use **8.8 fixed** (range ±127.99).
> Half the math work - a big win on physics-heavy carts that don't need the
> range.

---

## Math

```lua
flr(x)  ceil(x)  abs(x)  sgn(x)  sqrt(x)
min(a,b)  max(a,b)  mid(a,b,c)          -- mid = clamp middle value
sin(a)  cos(a)  atan2(dx,dy)            -- TURNS, not radians (see below)
rnd(n)  srand(seed)                     -- 16-bit xorshift
t()  time()                            -- seconds since boot (frames ÷ 60)
```

Trig is **turns-based and screen-oriented** (y grows downward), from a 256-entry
ROM table:

```
              0.75 (up)
                │
   0.5 ─────────┼───────── 0.0 / 1.0   (one full turn = 1.0)
      (left)    │      (right)
              0.25 (down)          sin(0.25) == 1   cos(0) == 1
```

```lua
local a = atan2(tx - x, ty - y)     -- angle toward a target, in turns
x += cos(a) * speed
y += sin(a) * speed
local r = flr(rnd(6))               -- integer 0..5, exact
```

Bitwise ops are operators: `& | ^^ << >> >>>` (`>>` arithmetic, `>>>` logical).

---

## Control flow & syntax sugar

```lua
if (btn(0)) x -= 1                    -- one-line if, parens REQUIRED
if (a > b) x = 1 else x = 2           -- one-line if/else
while (n > 0) n -= 1                  -- one-line while

x += 1   y -= 2   hp *= 2   n %= 8    -- LHS evaluated once
a, b = b, a                          -- multiple assignment / swap
x, y = spawn()                       -- multiple return

for i = 1, 10 do ... end             -- fractional & negative steps ok
for i = 10, 1, -1 do ... end

a != b        -- same as a ~= b
a \ b         -- floored int divide flr(a/b) - use a power-of-two divisor
sfx"3"  print"hi"                    -- paren-less string calls
// a line comment                    -- (as well as Lua's --)
```

---

## Tables, pools & arrays

There's no garbage collector, so containers are **capacity-bounded** and
allocated up front.

```lua
ps = pool(16)                        -- fixed-capacity entity pool
add(ps, {x = 10, y = 20, kind = 1})  -- traps if full (in debug builds)
del(ps, e)                           -- safe to delete while iterating
for e in all(ps) do e.x += 1 end     -- iterate in insertion order

grid  = array(64)                    -- 64 fixed-point cells
bytes = array8(256)                  -- 256 byte-wide cells (0..255)
```

**Not in the language** (the compiler errors loudly with the fix): `nil` and
`x = x or default`, closures, metatables / OOP, coroutines. The idiom is
**named functions + a `kind` field + `if/elseif` state machines**.

Fields must be booleans in conditions: `if (e.dead)` needs `e.dead` to be
`true`/`false`, not a number - `if (n)` on a number is an error on purpose.

---

## Text & print

```lua
print(str, [x, y], [c])   -- 4×6 font; returns the right-edge x
?expr                     -- print shorthand
```

Runtime string *building* (`..`, `sub`, `tostr`, `tonum`, `split`) isn't wired
yet. For live HUDs, bake digits into a byte buffer and blit it fast:

```lua
gt.print_buf(buf, off, x, y, c)      -- fast HUD text from a byte buffer
```

---

## Audio

```lua
sfx(n, [ch])         -- play sound n on channel ch
music(n, [fade])     -- play song n; music(-1) stops
```

`music(n)` plays **your project's song n** when the build carries songs
(`--songs a.gtm2,b.gtm2`, or the web IDE's tracker songs - song 0 is the first
tab). Without project songs it falls back to the built-in demo tunes (0-1).

Eight zero-authoring built-in SFX are ready immediately:

```
0 jump   1 pickup   2 shoot   3 explode
4 blip   5 powerup  6 hurt    7 select
```

Bring your own tracker data (converted with `bin/p8sfx.mjs`) and register it:

```lua
gt.sfx_bank(mydata)      -- register imported SFX bytes
gt.music_bank(mydata)    -- register imported song bytes
```

Or drive the FM voices directly (a second 65C02, the ACP):

```lua
gt.note(ch, note, vol)   -- start a note on a channel
gt.noteoff(ch)           -- release it
```

---

## Sprite sheet & the blitter

The sheet is one 128×128 image of 8×8 cells, indexed `0`–`255` (16 across,
16 down). Pass `--sheet gfx.gtg` at build time (make one with `gtlua gfx import`;
see [GRAPHICS.md](GRAPHICS.md)). For arbitrary-size / animated sprites and the
full 256×256 sheet, use frame tables - [SPRITES.md](SPRITES.md).

```
 sheet cell layout            a blit costs ~the same setup
 ┌──┬──┬──┬── … 16 ──┐        REGARDLESS of size - so ONE big
 │ 0│ 1│ 2│           │       blit beats many tiny ones.
 ├──┼──┼──┼── …       │       That's why the gt.* engines below
 │16│17│…             │       batch work into wide blits.
 └──┴──┴── …          ┘
```

The **blitter** is a hardware rectangle/sprite copier. `cls`, `spr`,
`rect/circ fill`, and every `gt.*` draw engine feed it. It can only write to the
framebuffer, so static backgrounds are pre-painted into spare video RAM once
(`gt.bg_*`) and blitted back whole each frame.

---

## `gt.*` - GameTank power tools

Because native code has no cycle governor, these asm engines do bulk work the
blitter can chew through fast.

**Palette & screen**

| Call | Does |
|---|---|
| `gt.rgb(r,g,b)` / `gt.rgb(byte)` | pick any color the GameTank can show |
| `gt.border(c)` | overscan border color |
| `gt.autocls(c)` | clear to color `c` automatically each frame (free - happens while the screen is between frames) |

**Cached backgrounds & tilemaps** (paint once, blit per frame)

| Call | Does |
|---|---|
| `gt.bg_clear()` | clear the offscreen 256×256 canvas |
| `gt.bg_tile(t, px, py)` | stamp one sheet tile into the canvas |
| `gt.bg_compose(map, cols, cx, cy, cw, ch)` | CPU-paint a tilemap into the canvas |
| `gt.bg_draw([sx], [sy])` | blit the (scrolled) canvas → screen, 1 blit/frame |
| `gt.bg_coln(cells, px, py, n)` | paint one tile column into the canvas |
| `gt.gspr(gx, gy, w, h, x, y)` | blit a rect *from* the canvas (a "cut" sprite) |
| `gt.tiles_draw(map, flags, w, i0, i1, j0, j1)` | asm tile-window scan → blits |
| `gt.canvas_view(dx, dy, opaque, h)` | window blit from the composed canvas |

**Entity pools** (update/draw a whole table in one asm walk)

| Call | Does |
|---|---|
| `gt.pool_move(ps, mode)` | integrate positions for the pool |
| `gt.pool_anim(ps, frame, spd, maxf)` | advance animation frames |
| `gt.pool_sprs(ps, cells, ox, oy)` | draw the pool as sprites |
| `gt.pool_edraw(ps, ani, type, flash, desc, nudge)` | rich pool draw (flash/shake) |
| `gt.hit_scan(a, …, b, …, pairs)` | broad-phase collision → contact pairs |
| `gt.cost_decay(act, lm, cost, n)` | per-entity lifetime/cost decay |

**Physics & particles**

| Call | Does |
|---|---|
| `gt.balls_bounds(x0,y0,x1,y1,vymin)` | set the walls balls bounce in (default: the whole screen); `vymin` = how fast a falling ball must move to bounce off the floor (0 = always) |
| `gt.balls_step(x,y,vx,vy,act,flags,pairs,n)` | integrate + wall-bounce + collision pairs |
| `gt.balls_drag(vx,vy,act,n)` | apply drag |
| `gt.balls_draw(x,y,cells,n)` | draw the ball table |
| `gt.parts_step(ps)` | step a particle pool |
| `gt.trail_stamp(act,x,y,tx,ty,sprs,n,upd)` | stamp motion trails |

**Staged-blit visual FX**

| Call | Does |
|---|---|
| `gt.starfield_init(n)` / `gt.starfield_move(mode)` / `gt.starfield_draw()` | parallax starfield |
| `gt.flakes_init(n)` / `gt.flakes_set(...)` / `gt.flakes_draw(dx,dy)` | drifting flakes/snow |
| `gt.chunks_draw(grid, lut, lut2, props, stride, cx0,cy0,cx1,cy1)` | 24×24-chunk world renderer |
| `gt.dbar(...)` | fast segmented bar (HUD meters) |

**Utilities**

| Call | Does |
|---|---|
| `gt.print_buf(buf, off, x, y, c)` | fast HUD text from a byte buffer |
| `gt.ticks()` | frame counter |

`hexdata("…")` (global, unprefixed) turns a compile-time hex string into ROM
bytes - handy for baking level or lookup data straight into the cartridge.

---

## Things worth knowing up front

1. **Framebuffer bytes are colors.** No CLUT, so `pal` can't recolor sprites
   already on screen, and sprite transparency is **color 0 only**.
2. **Conditions must be boolean.** `if (n)` on a number is an error - the
   language never guesses whether `0` is true.
3. **No `nil`, no `x or default`.** Containers are capacity-bounded; no
   closures / metatables / coroutines. Use `kind` fields + state machines.
4. **No cycle or token cap.** You get all 3.58 MHz - the only limit is ROM/RAM
   size. Feed the blitter with the `gt.*` engines and it flies.
5. **Trig is turns-based** (0..1 per revolution) and **screen-oriented**
   (y down), so `sin(0.25) == 1`.
6. **`sfx`/`music` play a native FM bank** by index (or your converted data),
   not raw sample bytes.

---

## Hello, GameTank

```lua
local angle  = 0
local radius = 40

function _update()
  angle += 0.016
  if (btn(0)) radius -= 1
  if (btn(1)) radius += 1
  radius = mid(8, radius, 58)
end

function _draw()
  cls(1)
  circfill(64, 64, 10, 9)                       -- the sun
  circfill(64 + flr(cos(angle) * radius),        -- an orbiting planet
           64 + flr(sin(angle) * radius), 5, 8)
end
```

```
gtlua build main.lua --sheet gfx.gtg -o game.gtr
```

---

## The machine at a glance (reference)

```
 ┌──────────────────────────────────────────────────┐
 │  CPU      65C02 @ 3.58 MHz    (native, no VM)      │
 │  Screen   128 × 128 px,  hundreds of colors        │
 │  Sprites  one 128×128 sheet of 8×8 cells (0-255)   │
 │  Sound    4-op FM on a second 65C02 (the ACP)      │
 │  Input    2 controllers, 6 buttons + START each    │
 │  Numbers  16.16 fixed point  (or 8.8 with --num8)  │
 │  Blitter  hardware rectangle / sprite copier        │
 │  Limit    ROM / RAM size - there is NO cycle cap    │
 └──────────────────────────────────────────────────┘
```

Two namespaces:

- **Global, unprefixed** - the core language (`spr`, `btn`, `circfill`, `rnd`…).
- **`gt.*`** - GameTank-only extras and fast asm draw engines (`gt.rgb`,
  `gt.bg_draw`, `gt.pool_move`…).

---


*Coming from PICO-8? There's a side-by-side mapping in
[`CHEATSHEET_FOR_PICO8_USERS.md`](CHEATSHEET_FOR_PICO8_USERS.md). This page is
the standalone reference for the shipped gt-lua implementation, cross-checked
against the compiler builtins and the SDK runtime.*
