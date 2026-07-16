# GBA Lua Cheat Sheet - for PICO-8 users

**PICO-8-flavored Lua that compiles to native ARM** for the Game Boy Advance. No
interpreter, no VM - your Lua becomes machine code. Familiar verbs
(`spr`/`btn`/`_init`/`_update`/`_draw`, 16.16 numbers, the dialect), on hardware
with a lot more room: **128 hardware sprites, affine (rotate/scale) sprites, four
scrolling tile layers, Mode 7, windows, blend/fade, a real save chip, and module
music.** Measured against PICO-8 v0.2.7.

Build: `node bin/gbalua.js build --target gba main.lua --sheet gfx.png -o game.gba`

> **New to PICO-8?** This page maps the GBA SDK *against* PICO-8. If you don't
> already know PICO-8, read [`CHEATSHEET.md`](CHEATSHEET.md) - the full reference
> with no PICO-8 assumed.

**Status legend**

| Badge | Meaning |
|---|---|
| ✅ **exact** | works, PICO-8 semantics |
| 🟡 **partial** | works with documented limits |
| 🔷 **differs** | works but different by hardware |
| ❌ **n/a** | no VM to emulate / intentionally cut |
| ➕ **GBA extra** | beyond PICO-8, uses GBA hardware |

Names are **global and unprefixed**, exactly like PICO-8. There is no `gba.*`
escape-hatch namespace - the extras are first-class verbs.

---

## Two things that differ from PICO-8 up front

1. **The screen is 240×160**, not 128×128. Coordinates and sprite layouts do
   **not** transfer 1:1 - you have ~2.7× the pixels. Center is `(120, 80)`.
2. **Two draw modes.** Immediate `pset`/`rect`/`circ`/`line`/`print` draw to a
   bitmap (Mode 4); using tile-layer verbs (`map_show`, `tileset`, `mode7`) puts
   you in tile mode (Mode 0) with four hardware layers + 128 sprites. Sprites,
   sound, and every color effect compose over both. Tile mode is the real
   scrolling-game path; bitmap is the quick-draw path.

---

## Colors

Colors are PICO-8-style indices `0-15` in draw calls, mapped to a 15-bit BGR555
palette. **Unlike the GameTank fork, `pal()` and `spr_col()` DO work at runtime**
- the GBA has hardware palette RAM, so palette swaps, cycling, and day/night are
cheap and real (see the extras section). `pal(i, r, g, b)` sets BG palette entry
`i` to an 8-bit RGB; `spr_col(i, r, g, b)` sets an OBJ palette entry.

---

## Controller → `btn()` index

```
        [2]↑                4 = A            6 = L (shoulder)
    [←]0    1[→]            5 = B            7 = R (shoulder)
        [3]↓                8 = START        9 = SELECT
```

`btn(i,[pl])` held · `btnp(i,[pl])` just-pressed with PICO-8 auto-repeat. The GBA
is a 1-player machine - the `pl` argument is accepted for API parity but ignored.
The d-pad indices match PICO-8 (0=LEFT 1=RIGHT 2=UP 3=DOWN); the GBA adds L, R,
START, and SELECT at 6-9.

---

## Program structure

| Call | | Notes |
|---|:--:|---|
| `_init()` | ✅ | runs once at startup |
| `_update()` | ✅ | logic @ 30 fps |
| `_update60()` | ✅ | logic @ 60 fps - the GBA holds this easily |
| `_draw()` | ✅ | 1× per visible frame |

Same fixed-timestep model as PICO-8 (no `dt`; move by a constant per frame). The
GBA's ARM CPU has plenty of headroom, so **`_update60()` is a fine default** -
unlike a slower console.

## Dialect & syntax

| Feature | | Notes |
|---|:--:|---|
| `a \ b` | ✅ | floored integer divide |
| `//` | ✅ | a line comment |
| `a != b` | ✅ | alias of `~=` |
| `if (c) stmt else stmt` | ✅ | one-line if / while, parens required |
| `+= -= *= \= %=` | ✅ | LHS evaluated once |
| `x,y = 64,32` | ✅ | multiple assignment (swap-safe) |
| `for i=1,10,2` | ✅ | fractional & negative steps ok |
| `[[ long string ]]` | ✅ | multi-line string |

## Number model

Full **16.16 fixed point**, PICO-8 edge cases and all.

| | | Notes |
|---|:--:|---|
| range | ✅ | −32768.0 … 32767.99998 |
| overflow | ✅ | wraps (two's complement) |
| `a / 0` | ✅ | saturates |
| `sin(.25) == -1` | ✅ | turns-based, screen-inverted |
| `sgn(0) == 1` · `flr` toward −∞ | ✅ | |
| `>>` / `>>>` | ✅ | arithmetic / logical shift |

The compiler keeps values that stay integral in fast 32-bit ints - an
optimization, never a semantic change.

## Graphics & draw (bitmap mode)

| Call | | Notes |
|---|:--:|---|
| `cls([c])` | ✅ | clears the bitmap |
| `rectfill / rect(x0,y0,x1,y1,c)` | ✅ | inclusive corners (P8 gotcha kept) |
| `circfill / circ(x,y,r,c)` | ✅ | |
| `line(x0,y0,x1,y1,c)` | ✅ | |
| `pset(x,y,[c])` | ✅ | set a pixel |
| `pget(x,y)` | ✅ | read a bitmap pixel |
| `sset(x,y,c)` | ✅ | paint a pixel into the sprite sheet |
| `clip(x,y,w,h)` | ✅ | bound draws to a rect; `clip()` resets (cls resets too) |
| `camera([x,y])` | ✅ | sticky draw offset |
| `color(c)` | ✅ | |
| `sspr(...)` | 🟡 | unscaled rect blit; scaled = compile error |
| `fillp`, `tline` | ❌ | not implemented |

## Sprites

| Call | | Notes |
|---|:--:|---|
| `spr(n,x,y,[w,h],[fx,fy])` | ✅🔷 | a **hardware OBJ** (128 max), not a blit; flips free |
| `spr8(t,x,y,[flip])` | ➕ | 8×8 sprite from a raw tile index |
| `spr_pal(bank)` · `spr_prio(p)` | ➕ | palette bank / priority vs BG layers |
| `sprr(n,x,y,angle,scale)` | ➕ | **rotate + scale** (affine) sprite |
| `sprr2(n,x,y,angle,sx,sy)` | ➕ | affine with non-uniform x/y scale (squash/stretch) |

The GBA composites sprites in hardware, so there's a **128-sprite-per-frame**
budget instead of PICO-8's per-blit CPU cost. `sprr`/`sprr2` are the headline
GBA feature PICO-8 has no equivalent for.

## Input

| Call | | Notes |
|---|:--:|---|
| `btn(i,[pl])` | ✅➕ | held; i = 0-9 (adds L/R/START/SELECT) |
| `btnp(i,[pl])` | ✅➕ | just-pressed, P8 auto-repeat |

## Math

| Call | | Notes |
|---|:--:|---|
| `flr ceil abs sgn sqrt(x)` | ✅ | |
| `min max(x,y)` · `mid(x,y,z)` | ✅ | |
| `sin cos(x)` · `atan2(dx,dy)` | ✅ | turns-based |
| `rnd(x)` · `srand(x)` | ✅ | `flr(rnd(n))` exact |
| `t()` · `time()` | ✅ | fixed seconds |
| bitwise `& \| ^^ << >>` | ✅ | as operators |

## Tables & entities

| Call | | Notes |
|---|:--:|---|
| `ps = pool(16)` | 🟡 | capacity-bounded (no unbounded growth / GC) |
| `add(ps,{x=1,y=2})` · `del(ps,e)` | ✅ | |
| `for e in all(ps) do` | ✅ | insertion order |
| `array(n)` / `array8(n)` | 🟡➕ | fixed 16.16 / byte arrays - **1-indexed** (`a[1]` first) |
| `{x=1, y=2}` (struct) | ✅ | tables are structs: fixed named fields |
| `{1,2,3}` / `{[k]=v}` | ❌ | array / map tables - one clear error, no cascade |

**Tables are structs, not arrays or maps** - a fixed set of named fields. Use
`array(n)`/`array8(n)` for indexed numeric data and a `pool` of structs for
entities. **Cut:** nil / `x or default`, closures, metatables, coroutines. Named
functions + a `kind` field + `if/elseif` state machines instead; the compiler
errors loudly with the fix.

## Audio

| Call | | Notes |
|---|:--:|---|
| `music(n,[loop])` | ✅🔷 | plays a **module** (maxmod) by index; `music(-1)` stops |
| `sfx(n,[ch])` | ✅ | sampled one-shot effect |
| `sfx_ex(n,vol,pan,pitch)` | ➕ | per-shot volume (0-1024), pan (0-255), pitch (16.16×) |
| `sfx_volume(v)` | ➕ | master SFX level |

Music is a streamed module, not FM or raw PICO-8 SFX bytes. The default soundbank
(`assets/soundbank.bin`) ships a chiptune as module 0; regenerate it from
`assets/make_music_xm.mjs` + `assets/build_soundbank.mjs` for your own tunes.

## Strings & print

| Call | | Notes |
|---|:--:|---|
| `print(str,x,y,[c])` | ✅ | positioned text |
| `print(val,x,y,[c])` | ✅ | numbers print directly |
| `s = "hello"` | ✅ | string literals (short and `[[ long ]]`) |
| `s .. s2` | ❌ | **no runtime string concat** - print label and value separately |
| `sub tostr tonum chr ord split` | ❌ | no runtime string building |

To show a label with a number, print them as two calls
(`print("hi",8,8,7) print(score,40,8,7)`), not `"hi"..score`.

## Map / tiles

| Call | | Notes |
|---|:--:|---|
| `map(cx,cy,sx,sy,cw,ch)` | ✅ | software tilemap draw off the `--map` data |
| `mget(x,y)` | ✅ | read a map cell |
| `map_show(layer)` | ➕ | show the bundled tilemap on a **hardware** BG layer |
| `tileset` / `tilemap` | ➕ | load a hardware layer's tiles / map |
| `layer_show` / `layer_pri` / `layer_scroll` | ➕ | control the 4 hardware BG layers |
| `parallax(layer,factor)` · `camera(x,y)` | ➕ | free hardware scrolling + parallax |
| `tget` / `tset` | ➕ | read/modify a hardware tile at runtime |

The GBA has **real tilemap hardware** - four layers that scroll for free, unlike
PICO-8's single software map. `map()` is the PICO-8-compatible software path;
`map_show` + `layer_*` is the hardware path (the real scrolling-game route).

## Cartridge data / save

| Call | | Notes |
|---|:--:|---|
| `save(slot, array8, n)` | ✅➕ | write `n` bytes to **battery SRAM** (16 slots × 1 KB) |
| `load(slot, array8, n)` | ✅➕ | restore; returns bytes read (0 = slot never written) |

Real persistence, on real save hardware: `if load(0, st, 8) > 0 then ...restored
end`. Keep your state in an `array8` and save/load it.

## Memory / low-level - n/a by design

| Call | | Notes |
|---|:--:|---|
| `peek / poke(addr,[v])` | ❌ | PICO-8's flat-memory pokes |
| `memcpy memset cstore` · `stat(x)` · `menuitem` | ❌ | no VM to poke |

---

## What the GBA adds beyond PICO-8

| Verb(s) | Notes |
|---|---|
| `sprr` / `sprr2` | **rotate + scale sprites** (affine) - the signature GBA sprite feature |
| `mode7()` / `mode7_cam(x,y,angle,[zoom])` / `mode7_off()` | an **affine plane** on BG2 (F-Zero ground, spinning maps, zooming menus) |
| `blend(layer,alpha)` / `fade(amount,[white])` / `blend_off()` | the PPU **blend unit** - free alpha and brightness fades (glass, ghosts, level wipes, hit flashes) |
| `window(x0,y0,x1,y1)` / `window_inside` / `window_outside` / `window_obj` / `window_off` | hardware **clipping windows** (spotlight/iris/reveal, HUD panels, sprite-shaped masks) |
| `mosaic(n)` / `mosaic2(bh,bv)` | hardware **pixelate** (dissolve, heat-shimmer, hit-flash) |
| `pal(i,r,g,b)` / `spr_col(i,r,g,b)` | **runtime palette** - swap, cycle, day/night (BGR555) |
| `hgradient(table)` | per-scanline **backdrop gradient** via the HBlank IRQ (sky gradients, underwater bands) |
| `backdrop(color)` · `screen_off()` / `screen_on()` | the void behind all layers · instant force-blank |
| `anim(slot,first,last,fps)` / `anim_once` / `anim_pingpong` / `anim_reset` / `anim_done` | frame-range animation off the frame clock |
| `timer_start()` / `timer_read()` | a free-running hardware timer (Timer 3, ~16 kHz) for sub-frame timing / profiling |
| `abg_setup(...)` / `abg_cam(...)` / `abg_off()` | a second **rotate/scale BG** of your own tiles (not the Mode-7 plane) |
| `mode15()` / `rgb15(r,g,b)` / `cls15` / `pset15` / `flip15` | a **16-bit true-color** bitmap (160×128 BGR555) - plasmas, gradients |
| `dma(dst,src,n)` / `dma_fill(dst,value,n)` | hardware **DMA3** block copy/fill of arrays |

These exist because native ARM code has no cycle governor and the GBA's PPU does
compositing, affine transforms, blending, and scrolling in hardware. The
constraint moves from PICO-8's 8192-token cap to **ROM size** (which is generous)
and the 128-sprite / 4-layer hardware budgets.

---

## The things to unlearn

1. **The screen is 240×160**, not 128×128 - coordinates don't transfer.
2. `pal()` / `spr_col()` **do** work here (real palette hardware), unlike some
   fantasy-console ports.
3. `spr()` is a **hardware sprite** (128 budget), not a per-blit CPU cost.
4. **No runtime string concat** - `"score "..n` doesn't compile; print separately.
5. Conditions must be boolean - `if (n)` on a number is an error (PICO-8 calls 0
   truthy, we won't guess).
6. No nil, so `x = x or default` is gone; tables are capacity-bounded structs;
   no closures / metatables / coroutines.
7. `music()` plays a **module** (maxmod) by index, not FM or raw PICO-8 bytes.

---

## Hello, GBA

```lua
local angle = 0
local radius = 60

function _update60()
  angle += 0.008
  if (btn(0)) radius -= 1
  if (btn(1)) radius += 1
  radius = mid(10, radius, 78)
end

function _draw()
  cls(1)
  circfill(120, 80, 12, 9)                            -- center of a 240x160 screen
  circfill(120 + flr(cos(angle) * radius),
           80 + flr(sin(angle) * radius), 6, 8)
end
```

`node bin/gbalua.js build --target gba main.lua -o game.gba` → runs in mGBA and on
real hardware.

---

*Status reflects the shipped implementation, cross-checked against the compiler
builtins and the SDK runtime. PICO-8 is by Lexaloffle Games; the Game Boy Advance
is Nintendo hardware. This SDK is an independent homebrew toolchain.*
