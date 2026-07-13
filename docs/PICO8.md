# PICO-8 familiarity - the gtlua north star

**Goal:** a PICO-8 developer should be able to port a cart to the GameTank in an
afternoon without relearning how to think. Not a PICO-8 runtime - a compiled
dialect + API that keeps PICO-8's muscle memory wherever the hardware and the
no-interpreter model allow, and fails loudly with a fix-it wherever they don't.

**Why this is worth chasing** (research 2026-07-02, sources at bottom):

- **The resolution is identical.** PICO-8 is 128×128; the GameTank framebuffer
  is 128×128. Coordinates, sprite sheets (one GRAM page = one 128×128 sheet =
  256 8×8 cells), and game feel transfer 1:1. No other real console offers this.
- **Nobody has built a PICO-8-to-native path.** Every "PICO-8 on hardware"
  project is an interpreter (fake-08, zepto8, pemsa, yocto-8 on RP2040) or a
  hand-port (ccleste, Celeste-Classic-GBA). Interpreters visibly struggle on
  weak silicon - that tax is exactly what compiling to 65C02 removes.
- **The essential surface is small and known.** Celeste Classic's C port
  (ccleste) needed 14 API calls: `music, spr, btn, sfx, pal, pal_reset,
  circfill, print, rectfill, line, mget, camera, fget, map` + init/update/draw.
  That list is our compatibility anchor.
- PICO-8's number model (16.16 fixed point, wrap on overflow) is *already* what
  a 65C02 wants - Lexaloffle designed for exactly this class of machine.

---

## 1. Decisions - dialect (syntax & semantics)

### Adopt verbatim (breaking changes to v0.1 marked ⚠)

| Feature | PICO-8 semantics we adopt |
|---|---|
| ⚠ `\` integer division | `a\b == flr(a/b)` (floored). **`//` becomes a comment** (PICO-8 treats it as one; P8 devs paste code full of `//` comments). v0.1's `//`-as-division is removed. `\` requires a constant power-of-two divisor until the general-divide routine lands with fixed-point. |
| `!=` | exact alias of `~=` |
| One-line `if`/`while` shorthand | `if (cond) stmt [else stmt]`, `while (cond) stmt` - parens required, newline ends the body, no `elseif`. The single most common P8 idiom (`if (btn(0)) x-=1`). Implement as grammar, not a text preprocessor - sane subset only. |
| Compound assignment | full set as operators land: `+= -= *= \= %= ..=` (have `+= -= *=` ⚠ `//=`→`\=`). Evaluate the LHS **once** (documented improvement over P8's evaluate-twice text expansion). |
| Number literals | hex `0x11.4` fractions and binary `0b101.1` when fixed-point lands; no exponent notation |
| `?` print shorthand | `?expr,...` = `print(expr,...)` - when `print` exists |
| Button glyphs | accept `⬅️ ➡️ ⬆️ ⬇️ 🅾️ ❎` in source as constants 0–5 (carts are full of them) |

### Adopt as THE number model (v0.2, replaces "integers only")

PICO-8's 16.16 fixed point, edge cases and all - its manual is now our numeric
spec:

- range −32768.0 … 32767.99999 (0x7fff.ffff); **wrap** on overflow (two's
  complement, natural on hardware)
- division by zero **saturates** to ±0x7fff.ffff; `abs(-32768)` saturates
- `sgn(0) == 1`; `flr` toward −∞; `x\1` ≡ `flr(x)`; `x%1` = fraction, floored
  modulo (sign of divisor)
- `>>` arithmetic, `>>>` logical shift; shifts move the binary point
- **turns-based trig with screen-space inversion**: `sin(0.25) == -1`,
  `cos(0)==1`, `atan2(dx,dy)` matching. Implemented as a 256-entry ROM table -
  turns are *cheaper* than radians on a 6502, the convention costs nothing.
- `rnd(x)` uniform in [0,x) (16-bit xorshift/LFSR), `srand(x)`, `flr(rnd(n))`
  idiom exact; `t()`/`time()` = frames÷60 as a fixed-point second count
- printing rounds to 4 decimals, integers print bare

Under the hood the compiler still infers narrow u8/i16 types where values
provably stay integral (the 6502 needs that for speed) - inference is an
optimization, never a semantic change.

### Keep from stock-Lua-via-PICO-8 (already planned, priority confirmed)

Multiple assignment/returns (`x,y = 64,32`), numeric `for` with fractional and
negative steps (exact 16.16 step accumulation), floored `%`, paren-less calls
(`sfx"3"`, `print"hi"` - trivial grammar, heavily used).

### Stays cut (compiled subset) - with the P8-dev-facing story

| P8 feature | Status | The error message points to |
|---|---|---|
| `x = x or default` (nil idiom) | cut - no nil | declare with an initial value; `and/or` value-selection on non-bools is rejected |
| closures / `function` values in tables | cut | named functions + `e.kind` tag fields (the *other* common P8 pattern) |
| metatables / OOP `__index` | cut | structs (tables with fixed fields) cover the common case |
| coroutines | cut | state-machine field + `if/elseif` (the compiled idiom for cutscenes) |
| `goto` (tweetcart loop) | cut | `_draw()` is the loop; not needed outside golf |
| unbounded `add()` growth | **capacity-bounded tables** (below) | declare capacity |
| GC | none - and nothing to collect | (invisible: idiomatic P8 preallocates anyway) |

### The dynamic-tables bridge: capacity-bounded sequences (v0.3)

The idiom that must not break (it's in every cart):

```lua
enemies = {}                          -- gtlua: needs a capacity annotation
add(enemies, {x=64, y=0, spd=2})
for e in all(enemies) do
  e.y += e.spd
  if (e.y > 127) del(enemies, e)      -- delete-while-iterating: supported
end
foreach(enemies, draw_enemy)
```

gtlua compiles this as a fixed-capacity array of structs + a live count:
`enemies = {} --[[cap 16]]` (or `enemies: {enemy[16]}` annotation). `add`
past capacity is a loud runtime trap in debug builds. `all()` iterates in
insertion order and tolerates `del` of the current element (P8-documented
behavior). `add/del/deli/count/#` all supported. This one feature carries
most of "it feels like Lua."

---

## 2. Decisions - API (the P8 names become the primary API)

Global functions, no `gt.` prefix, PICO-8 signatures exactly. The `gt.*`
namespace remains for GameTank-specific extras (`gt.sheet(n)` GRAM page
select, `gt.border(c)`, raw-color forms, hardware pokes). Ranked by the
research tiers:

### Tier 0 (v0.2–v0.3) - every cart uses these

| P8 call | GameTank implementation | Fidelity |
|---|---|---|
| `_init` / `_update` / `_update60` / `_draw` | ⚠ replaces v0.1 `init/update`. `_update`+`_draw` = 30 fps (every 2nd vsync) - **the default**; `_update60` = 60 fps (per vsync) for light carts. Fixed timestep, no `dt`. On real 6502, 30 is what most games hold; too-heavy `_update60` carts run in slow motion. | exact |
| `cls([c])` | full-screen blitter fill, default 0 | exact |
| `btn(i,[pl])` / `btnp(i,[pl])` | ⚠ replaces mask API. Indices 0–5 (0=⬅️ 1=➡️ 2=⬆️ 3=⬇️ 4=🅾️ 5=❎); **6=GT C** (extra button!), 7=START. 🅾️→GT A, ❎→GT B. `btnp` with P8 auto-repeat (15 frames, then every 4; pokeable off). Two pads via `pl`. | exact + extra button |
| `spr(n,x,y,[w,h],[flip_x,flip_y])` | n = 8×8 cell 0–255 on the current GRAM sheet (16/row); w,h in cells; flips are **hardware** (blitter bit-7 X/Y mirror); color 0 transparent unless `palt(0,false)` | exact |
| `rectfill(x0,y0,x1,y1,[c])` / `rect(...)` | corner coords, inclusive (the P8 gotcha, kept) - fill = 1 blit; outline = 4 | exact |
| `print(str,[x,y],[c])` | v0.4 with strings; literal-only strings can land earlier for HUDs; returns right-edge x | near-exact (4×6 font) |
| `sfx(n,[ch])` / `music(n,[loop])` | **shipped.** n indexes a BUILT-IN effect (0–7: jump/pickup/shoot/explode/blip/powerup/hurt/select) or tune (0–1) played on the ACP's 4-op FM voices - zero authoring, a kid writes `sfx(0)`. `ch` omitted = auto channel; `music(-1)` stops. Per-frame sequencer ported from the upstream tracker. (Custom P8-tracker-byte import is a later asset-pipeline task.) | same shape, built-in bank not P8 SFX bytes |
| `rnd`, `flr`, `add/del/all/foreach` | as above | exact |

### Tier 1 (v0.3–v0.4) - any game with a world

`camera([x,y])` (runtime offset applied to all draw calls - cheap, sticky, P8
draw-state semantics) · `circfill/circ` (blitter row-run fills from a quarter-
circle ROM table) · `line` (Bresenham CPU pset; fine for the occasional laser)
· `pset/pget` · `map(tx,ty,sx,sy,tw,th,[layers])`, `mget/mset`, `fget/fset`
(tile flags; map data in ROM, `mset` backed by a bounded RAM patch table -
capacity documented) · `mid/min/max/sgn/abs/sqrt/sin/cos/atan2` · `time()/t()`
· `pal/palt` - **see the honest-divergences section** · `cartdata/dget/dset`
(the GameTank SAVE bank exists for exactly this).

### Tier 2+ (later/maybe)

`sspr` unscaled works day one (arbitrary-rect blit); **scaled `sspr` is a
compile error at first** (the blitter can't stretch; software scaling later).
`clip()` - hardware X/Y clip exists at screen edges but not arbitrary rects;
software-clip rectfill/spr later. `fillp`, `tline`, control codes, custom
fonts: deferred indefinitely (fake-08 shipped without them and ran "many
carts").

### Colors: raw GameTank bytes, PICO-8 literals baked at build time

A color is a raw GameTank byte 0–255. For PICO-8 familiarity, a **static 0–15
literal** in a draw call is treated as a PICO-8 index and baked to its GameTank
byte at COMPILE time (nearest-match table computed against the emulator's CAPTURE
palette, hand-tuned once, frozen; 0 = black = transparent-for-sprites, same as
P8). `gt.rgb(byte)` / `gt.rgb(r,g,b)` reach the full 256-color palette - P8 devs
get *more* colors, not fewer. There is no runtime PICO-8 palette layer and no
`pal()`: a color computed at runtime is a raw byte (a computed 0–15 index renders
wrong - the documented dynamic-color caveat).

---

## 3. Honest divergences (documented up front, never silent)

1. **No runtime palette / `pal()`, and runtime-computed colors are raw bytes.**
   Colors are GameTank bytes; a static 0–15 literal bakes at build time, but a
   color a game *computes* at runtime (palette cycle, damage flash, a table
   value holding a 0–15 index) is used as a raw byte and renders wrong. Recolor
   by pre-authoring sheet cells or drawing with `gt.rgb`. This is the largest
   real gap - the deliberate trade for a PICO-8-bloat-free native runtime.
2. **`palt` is color-0-only.** Hardware transparency = color 0 on/off per
   blit. `palt(c,true)` for c≠0 → compile error pointing at re-authoring the
   sprite with 0 as transparent.
3. **Conditions must be boolean** (`if (n)` on a number → error with fix-it).
   Deliberate: P8 calls 0 truthy, C calls it falsy; we refuse to guess.
4. **No nil**, so `x = x or default` doesn't exist; tables are
   capacity-bounded; no closures/metatables/coroutines (see cut table).
5. `_update` CPU model differs (real silicon, no token/cycle governor -
   games get the whole 3.5 MHz and no 8192-token cap; the constraint moves
   to ROM/RAM size).
6. `sfx()/music()` play a GameTank-native BUILT-IN bank (indices 0–7 sfx,
   0–1 songs) rendered on the ACP's FM voices - not P8 SFX bytes. A kid
   triggers them by index with no data to author; importing a P8 cart's own
   tracker data is a later converter task. See §sound below.

---

## 4. Sequencing (revises SPEC.md's roadmap)

- **v0.2 - the dialect release:** `\` + `//`-comment ⚠, `!=`, one-line
  if/while, glyph constants, `_init/_update/_update60/_draw` ⚠, index-based
  `btn/btnp` + repeat ⚠, 16.16 fixed point with P8 edge semantics, the math
  library (`flr ceil abs sgn sqrt min max mid sin cos atan2 rnd srand t`),
  multiple assignment, `camera`, `rect/rectfill`, `pset`, `circfill`, `line`.
- **v0.3 - the world release:** structs + capacity tables +
  `add/del/deli/all/foreach/count`, `spr/sspr(unscaled)` + GRAM sheets +
  sprite asset pipeline, `pal/palt` (as scoped above), `fget/fset`.
- **v0.4 - map + sound:** `map/mget/mset`, `sfx/music` on the ACP +
  converter, `cartdata/dget/dset`.
- **v0.5 - text:** strings, `print`, `?`, the 4×6 font.

The three ⚠ breaking changes land together in v0.2 while the SDK has zero
external users - after that, P8 alignment is frozen and documented.

---

## Sources

PICO-8 manual (lexaloffle.com/dl/docs/pico-8_manual.html) + changelog + wiki;
pico8parse grammar notes; Celeste Classic / evercore / newleste source
analysis; ccleste (github.com/lemon32767/ccleste) minimal-API evidence;
fake-08 / zepto8 / tac08 / pemsa / picolove / yocto-8 compatibility notes;
pico2gba+pico4gba (interpreter-on-GBA, not a compiler); tweetcart idiom
studies (demobasics.pixienop.net, sizecoding.org). Full research reports in
the project notes.
