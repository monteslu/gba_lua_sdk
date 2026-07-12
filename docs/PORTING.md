# Porting a PICO-8 game to gt-lua

PICO-8 is a wonderful place to make a game, and its ergonomics are exactly why
gt-lua feels the way it does - same Lua-flavored syntax, same `_init`/`_update`/
`_draw` shape, the same 128×128 screen. If you have a PICO-8 cart, a lot of it
comes across with little change.

gt-lua is **familiar, not a PICO-8 emulator**. It compiles your Lua to native
65C02 that runs on real GameTank hardware - there's no VM underneath. So porting
is a translation, not a drop-in: most of your logic and draw code moves over
directly, and a few things change because the GameTank is a different (and in
some ways more capable) machine. This doc is the practical walkthrough.

For the exact per-function compatibility, keep
[`CHEATSHEET_FOR_PICO8_USERS.md`](CHEATSHEET_FOR_PICO8_USERS.md) open alongside
this - it badges every PICO-8 call as exact / partial / differs / n/a.

## The short version

1. **Copy your cart's Lua** into `main.lua`.
2. **Import the art**: `gtlua gfx import cart.p8 -o gfx.gtg`.
3. **Import the audio** (optional): `node bin/p8sfx.mjs cart.p8` → paste the
   `hexdata` into your source, register it with `sfx_bank()`.
4. **Build**: `gtlua build main.lua --sheet gfx.gtg -o game.gtr`.
5. **Fix what the compiler flags.** It fails loudly, with a fix-it, on the Lua
   features that don't compile (see below) - work through those.

Most of the effort is step 5, and it's usually mechanical.

## 1. The code

Your game loop is already the right shape: `_init`, `_update`/`_update60`, and
`_draw` all work as in PICO-8, and `_draw` **is** the loop (no cartridge/tweetcart
form). Coordinates, `spr`, `rectfill`, `circfill`, `print`, `btn`/`btnp`, `sin`/
`cos`/`atan2`, `rnd`, the 16.16 number model - all carry over with PICO-8
semantics.

What the compiler will make you change (it errors with a fix-it, so you won't
miss any):

- **No `nil`.** `x = x or default` and truthy-nil patterns are gone. Give
  variables real values; use a `kind`/`state` field instead of nil-checks.
- **Conditions must be boolean.** `if (n)` on a number is an error - PICO-8 treats
  `0` as truthy and gt-lua won't guess. Write `if (n != 0)`.
- **No closures, metatables/OOP, or coroutines.** Use named functions, a `kind`
  field, and `if/elseif` state machines. (This is the biggest rewrite for
  OOP-heavy carts.)
- **Tables are capacity-bounded.** `pool(n)` / `add` / `del` / `all` replace
  unbounded tables - no GC on a 3.5 MHz 6502. Pick a max count per entity type.
- **No runtime string building yet.** `..`, `sub`, `tostr` are on the roadmap;
  for HUDs, bake text into byte buffers and draw with `gt.print_buf`.
- **No `peek`/`poke`/memory map.** PICO-8's `0x6000` screen and draw-state pokes
  don't exist - there's no VM to poke. Real hardware is reached through `gt.*`
  helpers.

Everything the compiler *doesn't* flag compiles as-is. When in doubt, build and
read the errors - they point at the line and suggest the fix.

## 2. The art - PICO-8 sheet → native `.gtg`

`gtlua gfx import` pulls a cart's 128×128 sprite sheet straight into a GameTank
`.gtg` sheet:

```
gtlua gfx import cart.p8 -o gfx.gtg      # from a .p8 text cart
gtlua gfx import sheet.png -o gfx.gtg    # or from an exported PNG
```

PICO-8's 16 colors are converted to the nearest GameTank bytes at import, so your
art looks close to the original. Your `spr(n)` cell numbers keep working unchanged
- the 8×8 grid is the same. See [`GRAPHICS.md`](GRAPHICS.md) for the format and
the converter.

**Draw-call colors** convert too: a static `0–15` color literal (`cls(1)`,
`rectfill(...,8)`) is baked to its GameTank byte at build time, so it looks right
with no change. But a color your code **computes at runtime** (a variable, a
palette-cycle, a flash) is used as a raw byte and will be the wrong color - fix
those by computing a GameTank byte or using `gt.rgb`. There is no runtime PICO-8
palette or `pal()`. See [`PALETTE.md`](PALETTE.md).

**Then you have room to grow.** Once it's a `.gtg`, you're on the GameTank's real
graphics: the full **256-color** palette (reach it with `gt.rgb`), a sheet up to
**256×256**, and **frame tables** (`.gsi` + `sprf`) for arbitrary-size sprites and
animation frames anywhere in the sheet - see [`SPRITES.md`](SPRITES.md). None of
that is required to port; it's there when you want it.

> **Colors look a little different.** The GameTank's palette is its own - muted
> vs PICO-8, no pure white/black, softer primaries. That's the hardware, not a
> bug; it's the CAPTURE palette the console actually displays. Per-color mapping
> and rationale are in [`PALETTE.md`](PALETTE.md). If a specific color matters,
> pick a closer GameTank color with `gt.rgb`.

## 3. The audio - PICO-8 SFX/music → FM

This is the biggest *hardware* difference, and worth understanding up front.
PICO-8 has a per-note synth with waveforms and effects; the GameTank has a
dedicated audio coprocessor running a **4-op FM synth** (a second 65C02). They're
different instruments, so audio is a **re-interpretation**, not a byte-for-byte
copy - a fit, not a clone.

Two paths:

- **Import your cart's tracker data**: `node bin/p8sfx.mjs cart.p8` converts the
  `__sfx__`/`__music__` sections to an FM bank (`hexdata` blob) - pitch and timing
  are preserved; each effect maps to the closest built-in FM instrument; slides/
  vibrato are dropped in v1. Paste the blob and register it with `sfx_bank()` /
  `music_bank()`, then call `sfx(n)` / `music(n)` as usual. See [`sfx.md`](sfx.md).
- **Use the zero-authoring built-ins**: `sfx(0)`=jump, 1=pickup, 2=shoot,
  3=explode, 4=blip, 5=powerup, 6=hurt, 7=select, rendered on the FM voices - a
  quick way to get game feel without importing anything.

Because it's a different synth, expect to tune: the imported version is a starting
point, and hand-picking instruments per effect usually sounds better than the
automatic mapping. For music-forward games, **authoring natively** for the FM synth
is the better fit - write songs in the console's own `.gtm2` format (from MIDI, or
by hand) and play them with `song()`. See [`MUSIC.md`](MUSIC.md).

## 4. Build and run

```
gtlua build main.lua --sheet gfx.gtg -o game.gtr
```

For physics-heavy carts, add **`--num8`** to build with the 8.8 fixed-point model
(±127.99) - it cuts the 32-bit math cost hard. Only do this if your values fit
the smaller range.

The result runs in the emulator, on gametank.zone, and on real hardware via GTFO.
There's no token or CPU-cycle cap - you get the whole 3.5 MHz - so the constraint
moves from PICO-8's 8192-token budget to **ROM/RAM size** and to keeping the
blitter fed. The `gt.*` engines (`bg_compose`/`bg_draw`, `chunks_draw`, the
`pool_*` and `balls_*` walks) exist to feed it efficiently for tilemaps, particle
systems, and bulk entities.

## What won't come across directly (be honest with yourself)

Some PICO-8 carts lean on things that don't have a 1:1 GameTank equivalent. None
are dealbreakers, but plan for them:

| PICO-8 feature | On GameTank |
|---|---|
| OOP / metatables / closures | rewrite as `kind`-field state machines + named functions |
| `pal()` remap / palette-cycle / flash tints | no runtime palette; pre-author recolored sheet cells, or draw with `gt.rgb` bytes |
| runtime-computed 0–15 colors | used as raw bytes (wrong color) - compute a GameTank byte instead |
| Runtime string building (`..`, `sub`) | bake byte buffers today; string ops are on the roadmap |
| `map`/`mget`/`mset` tilemap API | use `gt.bg_compose`/`gt.bg_draw` (shipped) or `gt.chunks_draw` |
| `cartdata`/`dget`/`dset` saves | the SAVE hardware exists; the API layer is planned |
| Heavy unbounded-table allocation | capacity-bounded `pool`s (no GC) |

The compiler catches the code-level ones for you. The art and audio ones are
choices you make while porting. When something genuinely can't map, gt-lua errors
with a pointer rather than silently doing the wrong thing.

---

PICO-8 is the reason this all feels approachable - it set the ergonomics and the
API shape, and we're grateful for it. gt-lua takes that familiarity onto real
8-bit hardware, with a bigger palette, an FM synth, and native code speed to grow
into once the port is running.
