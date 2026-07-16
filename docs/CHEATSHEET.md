# GBA Lua Cheat Sheet

**Write games in Lua for the Game Boy Advance.** You write a PICO-8-flavored
Lua; the SDK compiles it to native ARM and produces a `.gba` ROM you can play in
[mGBA](https://mgba.io/) or flash to a cartridge. No interpreter runs on the
device - your Lua *is* the machine code.

The screen is **240×160**. You fill in three functions, and the GBA hardware does
the heavy lifting (128 sprites, four scrolling layers, rotate/scale, blending).

```
node bin/gtlua.js build --target gba main.lua --sheet gfx.png -o game.gba
```

---

## Program structure - the 3 functions

```lua
function _init()   end   -- runs ONCE at startup
function _update() end   -- your game logic (30 fps).  _update60() for 60 fps.
function _draw()   end   -- your drawing, once per frame
```

The GBA calls `_update()` then `_draw()` over and over. To move something, add a
little to its position each update - there are no clocks, just "how much per
update." The GBA's CPU has plenty of headroom, so `_update60()` (60 fps) is a
fine default.

```lua
local x = 0
function _update60()
  x += 1
  if x > 239 then x = 0 end
end
function _draw()
  cls(1)                       -- clear to dark blue
  circfill(x, 80, 5, 8)        -- a red dot sliding across
end
```

---

## The screen: two ways to draw

The 240×160 screen has two drawing paths - one hardware mode bit picks between
them. Sprites, sound, and all color effects compose over both.

- **Bitmap mode** - immediate `pset`/`rect`/`circ`/`line`/`print` to a
  framebuffer. Simple; single-buffered. Using any of these puts you here.
- **Tile mode** - four hardware layers that scroll for free + 128 sprites. Using
  `map_show`/`tileset`/`mode7` puts you here. This is the real scrolling-game
  path.

Colors are indices `0-15` (`0` black, `1` dark-blue, `8` red, `10` yellow, `12`
blue, `14` pink). Runtime `pal(i,r,g,b)` / `spr_col(i,r,g,b)` reach the full
15-bit BGR555 palette.

---

## Bitmap drawing

| Call | What |
|---|---|
| `cls([c])` | clear the screen to color `c` |
| `pset(x,y,[c])` | set one pixel |
| `rect(x0,y0,x1,y1,[c])` / `rectfill(...)` | outline / filled rectangle (inclusive corners) |
| `circ(x,y,r,[c])` / `circfill(...)` | outline / filled circle |
| `line(x0,y0,x1,y1,[c])` | a line |
| `color(c)` | set the default draw color |
| `camera([x,y])` | sticky draw offset for subsequent calls |
| `clip(x,y,w,h)` | bound all draws to a rectangle; `clip()` (no args) resets — `cls()` resets too |
| `pget(x,y)` | read a bitmap pixel (color 0..255) |
| `sset(x,y,[c])` | paint a pixel into the loaded sprite sheet at runtime |
| `sspr(sx,sy,sw,sh,dx,dy,[dw,dh],[fx,fy])` | sheet blit (scaled = compile error today) |
| `print(str_or_val,x,y,[c])` | draw text or a number at (x,y) |

There is **no runtime string concatenation** - to show a label with a value,
print them separately: `print("score",8,8,7) print(n,48,8,7)`.

---

## Sprites (hardware OBJ)

The GBA composites up to **128 hardware sprites** per frame - each `spr()` is a
hardware object, not a CPU blit.

| Call | What |
|---|---|
| `spr(n,x,y,[w,h],[fx,fy])` | draw sprite tile `n`; `w,h` in 8px cells; flips are free |
| `spr8(t,x,y,[flip])` | 8×8 sprite from a raw tile index |
| `spr_pal(bank)` | palette bank (0-15) for subsequent `spr()` this frame |
| `spr_prio(p)` | priority vs BG layers (0 front .. 3 back) |
| `sprr(n,x,y,angle,scale)` | **rotate + scale** sprite (`angle` in turns 0..1, `scale` 16.16) |
| `sprr2(n,x,y,angle,sx,sy)` | affine with independent x/y scale (squash/stretch) |

`sprr` / `sprr2` are the GBA's affine hardware - free rotation and scaling with no
per-pixel cost.

**Sprite modifiers** (apply to the next `spr()` this frame):

| Call | What |
|---|---|
| `spr_blend()` / `spr_blend_off()` | make the next sprite an alpha-blend target / back to opaque |
| `spr_window()` | make the next sprite a shaped OBJ-window mask (pair with `window_obj`) |
| `spr_mosaic(on)` | apply the `mosaic()` grid to the next sprite |

---

## Tile layers (hardware backgrounds)

Four hardware BG layers that scroll for free - the real path for scrolling games.

| Call | What |
|---|---|
| `map_show([layer])` | show the bundled `--map` tilemap on a layer |
| `tileset(layer,tiles,ntiles,pal)` | load a layer's tileset + palette |
| `tilemap(layer,map,cols,rows)` | set a layer's tilemap |
| `layer_show(layer,on)` | enable / disable a layer |
| `layer_pri(layer,prio)` | layer priority (0 front .. 3 back) |
| `layer_scroll(layer,x,y)` | scroll one layer directly (HUD / parallax) |
| `camera(x,y)` | scroll all layers by the camera |
| `parallax(layer,factor)` | per-layer follow factor (16.16) for parallax |
| `mget(col,row)` / `tget(layer,col,row)` | read a map cell |
| `tset(layer,col,row,tile)` | modify a tile at runtime |

Also `map(cx,cy,sx,sy,cw,ch)` draws the `--map` data the PICO-8 software way (a
`spr`-loop), for when you want PICO-8-compatible map drawing over the bitmap.

---

## Mode 7 (affine plane)

Turn BG2 into a flat plane you fly a camera over - F-Zero ground, spinning maps,
zooming menus. Data comes from `--mode7 plane.png` (8bpp, square power-of-two).

| Call | What |
|---|---|
| `mode7()` | show the bundled affine plane (call once in `_init`) |
| `mode7_cam(x,y,angle,[zoom])` | per-frame camera: world point centered, `angle` turns, `zoom` 16.16 |
| `mode7_off()` | hide the affine layer |

---

## Second affine BG (your own rotate/scale layer)

Like Mode 7, but with the game's **own** tiles + map instead of the bundled plane
- a spinning logo, a rotating menu, or a second scaled world.

| Call | What |
|---|---|
| `abg_setup(tiles,ntiles,map,msize,[pal])` | `tiles` = array8 of 8bpp pixels (64 bytes/tile), `map` = array8 of `msize*msize` tile indices, `msize` = 16/32/64/128, `pal` = array of BGR555 colors (see `rgb15`) |
| `abg_cam(x,y,angle,[zoom])` | per-frame camera (same as `mode7_cam`) |
| `abg_off()` | hide it |

---

## 16-bit bitmap (true color)

A 160×128 direct-color (BGR555) framebuffer for plasmas, gradients, and photo
blits - beyond the 16-color indexed path. Switch with `mode15()` (once), then use
these instead of the 8bpp `cls`/`pset`.

| Call | What |
|---|---|
| `mode15()` | switch to the 16-bit bitmap (call once in `_init`) |
| `rgb15(r,g,b)` | build a color from 0..255 components |
| `cls15(color)` / `pset15(x,y,color)` | clear / plot a 16-bit pixel |
| `fillrect15(x,y,w,h,color)` | fill a 16-bit rectangle (fast block fill) |
| `flip15()` | present (currently single-buffered, so drawing shows immediately) |

---

## DMA (fast bulk moves)

Hardware DMA3 block copy/fill - far faster than a Lua loop for big buffers.

| Call | What |
|---|---|
| `dma(dst,src,n)` | copy `n` 32-bit words `src`→`dst` (both gba-lua arrays) |
| `dma_fill(dst,value,n)` | fill `n` words of `dst` with `value` |

For an `array` (16.16) `n` = element count; for `array8` pass a word count (bytes/4).

---

## Windows (hardware clipping)

Rectangular regions where you choose which layers are visible - free in the PPU.
`layers` is a bitmask: `1`=BG0 `2`=BG1 `4`=BG2 `8`=text `16`=sprites (`31` = all).

| Call | What |
|---|---|
| `window(x0,y0,x1,y1)` | spotlight: show everything inside the box, hide outside (iris/reveal) |
| `window_inside(x0,y0,x1,y1,layers)` | show only `layers` inside the box |
| `window_outside(layers)` | what shows outside the window(s) (default none) |
| `window_obj(layers)` | OBJ window: `spr_window()` sprites mask `layers` through their silhouette |
| `window_off()` | disable windowing |

---

## Color effects (the PPU blend/mosaic unit - free)

Layer ids: `0-2` tile BGs, `3` text/HUD, `4` sprites. Amounts are `0.0..1.0` in
16.16 fixed.

| Call | What |
|---|---|
| `blend(layer,alpha)` | draw `layer` at `alpha` opacity over the scene (glass, ghosts, dimmed UI) |
| `fade(amount,[white])` | darken (or whiten if `white`) the whole screen - wipes, hit flashes |
| `blend_off()` | clear all blend/fade effects |
| `mosaic(n)` / `mosaic2(bh,bv)` | hardware pixelate (0=off..15) - dissolve, heat shimmer |
| `backdrop(color)` | the color behind all layers |
| `screen_off()` / `screen_on()` | force-blank / un-blank instantly (hide a mid-frame rebuild) |

---

## Palette & raster

| Call | What |
|---|---|
| `pal(i,r,g,b)` | set BG palette color `i` (0-255) to an 8-bit RGB - swaps, cycling, day/night |
| `spr_col(i,r,g,b)` | set an OBJ (sprite) palette color |
| `hgradient(table)` | per-scanline **backdrop gradient** - `table` = 160 BGR555 colors via HBlank IRQ; `hgradient(0)` off |

---

## Animation helpers

Turn a first..last frame range + an fps into "which frame now." `slot` is a
per-actor id (0-31); feed the result to `spr()`/`spr8()`.

| Call | What |
|---|---|
| `anim(slot,first,last,fps)` | looping cycle |
| `anim_once(slot,first,last,fps)` | play once, hold last; `anim_done(slot)` goes true |
| `anim_pingpong(slot,first,last,fps)` | bounce first..last..first |
| `anim_reset(slot)` | restart a slot |

---

## Input

| Call | What |
|---|---|
| `btn(i,[pl])` | is button `i` held? |
| `btnp(i,[pl])` | just-pressed (with PICO-8 auto-repeat) |

Indices: `0`=LEFT `1`=RIGHT `2`=UP `3`=DOWN `4`=A `5`=B `6`=L `7`=R `8`=START
`9`=SELECT. The GBA is 1-player; `pl` is accepted but ignored.

---

## Math

| Call | What |
|---|---|
| `flr ceil abs sgn(x)` | rounding / sign (`flr` toward −∞, `sgn(0)==1`) |
| `min max(x,y)` · `mid(x,y,z)` | min / max / median |
| `sqrt(x)` | square root |
| `sin(x) cos(x)` | turns-based (0..1), PICO-8 screen-inverted sin |
| `atan2(dx,dy)` | angle in turns |
| `rnd([x])` · `srand(x)` | random; `flr(rnd(n))` is exact |
| `t()` / `time()` | elapsed time in fixed seconds |
| `band bor bxor bnot shl shr lshr` | bit ops (also `& \| ^^ ~ << >> >>>`) |

Numbers are **16.16 fixed point**: range ±32767, overflow wraps, `/0` saturates.

---

## Data

| Call | What |
|---|---|
| `array(n,[v])` | fixed array of `n` 16.16 numbers, **1-indexed** (`a[1]` is first) |
| `array8(n,[v])` | fixed array of `n` bytes (0-255) - half the RAM, faster |
| `pool(n)` | a capacity-bounded pool of structs, for entities |
| `add(pool,{...})` / `del(pool,e)` | add / remove (delete-while-iterating ok) |

Tables are **structs** - fixed named fields (`{x=1,y=2}`). No `{1,2,3}` array
tables, no `{[k]=v}` maps, no nil, no closures/metatables/coroutines; each is one
clear compile error with the fix.

---

## Save (battery SRAM)

| Call | What |
|---|---|
| `save(slot,array8,n)` | write `n` bytes of an array8 to SRAM slot (0-15, 1 KB each) |
| `load(slot,array8,n)` | restore up to `n` bytes; returns count read (0 = never saved) |

```lua
local st = array8(8)
function _init()
  if load(0, st, 8) > 0 then hi = st[1] + st[2]*256 else hi = 0 end
end
-- ...later...
st[1] = hi % 256; st[2] = (hi \ 256) % 256; save(0, st, 8)
```

---

## Timer

| Call | What |
|---|---|
| `timer_start()` | reset + run a free hardware timer (Timer 3, ~16 kHz) |
| `timer_read()` | sample the count - sub-frame timing / profiling |
| `realframes()` | a STEADY 60 Hz frame count (ticks in a VCOUNT IRQ) |
| `realsecs()` | elapsed real seconds (16.16) |

Bracket a routine to profile it: `timer_start()` ... `local ticks = timer_read()`.

`t()`/`time()` advance once per game loop, so a heavy scene (whose `_draw` misses
vblanks) makes them drift. `realframes()`/`realsecs()` tick at a true 60 Hz in an
interrupt regardless - use them to pace things by wall-clock (auto-advance a demo,
timeouts).

---

## Sound

| Call | What |
|---|---|
| `music(n,[loop])` | start module `n` (maxmod); loops by default, `music(-1)` stops |
| `sfx(n,[ch])` | play sampled effect `n` |
| `sfx_ex(n,vol,pan,pitch)` | per-shot volume (0-1024), pan (0-255, 128 center), pitch (16.16×) |
| `sfx_volume(v)` | master SFX volume (0-1024) |

Music is a streamed module. The default soundbank (`assets/soundbank.bin`) ships
a chiptune as module 0; regenerate it from `assets/make_music_xm.mjs` +
`assets/build_soundbank.mjs` for your own.

```lua
function _init() music(0) end
function _update60()
  if btnp(4) then sfx(0) end
end
```

---

## Assets & building

```sh
node bin/gtlua.js build --target gba main.lua \
  --sheet sprites.png   \  # sprite art (PNG -> tiles)
  --map level.png       \  # a tilemap
  --mode7 plane.png     \  # an affine plane
  -o game.gba              # output ROM (use an absolute path)
```

`node bin/gtlua.js c main.lua` prints the generated C for debugging.

---

## Not-Lua walls (loud, never silent)

Conditions must be boolean (`if x ~= 0 then`, not `if x then`). No nil, closures,
metatables, coroutines, string concatenation, `{1,2,3}`/`{[k]=v}` tables, or
`goto`. Every unsupported feature is a compile-time error that names what to write
instead.
