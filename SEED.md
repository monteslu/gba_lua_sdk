# gba_lua_sdk — seed notes

**This is a work-in-progress fork of `gametank_lua_sdk` (the `gtlua` npm pkg),
being retargeted from the GameTank to the Game Boy Advance.** Started 2026-07-14.

## Origin

- Cloned from `~/code/cliemu/gametank_lua_sdk` at commit **e9a3e34** (gtlua 0.2.9,
  suite 198/198 green).
- The git remote `gtlua-upstream` points at the LOCAL gt-lua tree (not GitHub),
  so gt-lua front-end/number-model improvements can be pulled in locally, and
  there is NO risk of pushing GBA work to the GameTank repo. A real GBA `origin`
  gets added when we cut the new GitHub repo.

## What this becomes

A Lua→C→native-**ARM** SDK for the GBA that leans into GBA hardware (affine
sprites, Mode 7, hardware layers/parallax, alpha blending, maxmod music). Same
"wow-per-line-of-Lua" as gt-lua, on hardware with room to breathe. Compile to
native ARM — no interpreter on the cartridge.

## The plan lives OUTSIDE this repo

Full plan, reuse map, API surface, performance analysis, and the platform-choice
rationale: **`~/code/cliemu/internal-gbalua/PLAN.md`** (internal-only; never
ships). Read it first.

## Reuse vs. rewrite (short version — see PLAN.md for the measured detail)

- **KEEP ~as-is (import/reuse):** `compiler/{lexer,parser,check,index}.js` (the
  PICO-8-Lua front-end + int/fixed type inference — ~100% portable), the number
  model, the env-injected `compiler/build.js` SEAM (tool-name dispatch), the
  `builtins.js` TABLE SHAPE.
- **REWRITE (GameTank → GBA):** the `sdk/` runtime (new `gba_api.c` = thin
  wrappers over libtonc/maxmod, NOT hand-written engines), `compiler/build.js`
  BODY (drop the FLASH2M bank ladder — GBA is flat; a much shorter arm-gcc→.gba
  path), the `builtins.js` CONTENTS (GBA-native verbs), the toolchain deps
  (`romdev-platform-gba` instead of `romdev-toolchain-cc65` +
  `romdev-core-gametank`).
- **DELETE:** `peephole.js` (6502-only), all the `sdk/*.s` 6502 asm, the `gt.*`
  perf-engine namespace (the GBA needs no asm-escape-hatch shelf — see PLAN.md
  Performance section). Flat top-level API, no `gba.*` namespace.

## Spike 0 — DONE ✅ (2026-07-14): the pipeline is proven

Both halves of Spike 0 verified end-to-end:

**Runtime/hardware half** (`spike0/rotsprite.c`): hand-wrote the libtonc C for a
rotating+scaling 16×16 affine hardware sprite (`obj_aff_rotscale`), built it
through the LIVE romdev GBA toolchain (`build platform:gba language:c
runtime:libtonc` → ok, 0 issues), ran on mGBA. Verified via romdev inspectors:
`sprites({op:'inspect'})` shows slot 0 `affine:true, 16×16, visible`; the OAM
affine matrix `pa` changes frame-to-frame (rotation+scale live); three
screenshots (`spike0/f_a/f_b/f_c.png`) show the square visibly rotating+pulsing.
- **Bug caught by romdev, not by eyeball** — first build rendered BLANK despite a
  perfect OAM. `background({view:'renderState'})` diagnosed it instantly:
  `displayObj:false, forcedBlank:true` — I'd never written REG_DISPCNT (libtonc
  crt0 default = forced-blank ON). Fix: `REG_DISPCNT = DCNT_OBJ | DCNT_OBJ_1D`.
  This is the loud-inspector loop the whole thesis rests on, working on day one.

**Compiler half**: `import { compile } from "gtlua/compiler/index.js"` (the CLONE's
front-end) parses a PICO-8-shaped Lua game (`_update`/`_draw`/`cls`/`spr`/`+=`),
typechecks CLEAN (0 diagnostics), and returns the AST + callGraph a GBA emitter
consumes. CONFIRMED the reuse map: front-end works untouched as a library.

**What the emitter back-edge must change (from the current GameTank C emission):**
the front-end emits `gt_p8_cls(0)` + a `(gt_a0=1, gt_a1=60, ..., gt_p8_spr_z())`
zero-page fastcall + a `gt_init/gt_sheet_init/gt_endframe` harness. For GBA:
`#include <tonc.h>`, `gba_cls(...)`, a PLAIN `gba_spr(1,60,40)` call (the
zero-page fastcall idiom DISAPPEARS — ARM has no ZP), and the libtonc harness
(`irq_init`+`irq_add(II_VBLANK)` → `VBlankIntrWait`/`oam_copy` loop). Small,
bounded, exactly as PLAN.md's reuse map predicted (~40% of emit.js = the back-edge).

## Spike 1 — DONE ✅ (2026-07-14): a real gba-lua game runs from Lua source

The FULL pipeline works: Lua → emitter (GBA target) → gba_api.c runtime → romdev
toolchain → running, INPUT-DRIVEN game on mGBA.

- **Emitter GBA target** (`compiler/emit.js`): added `opts.target === "gba"`. The
  front-end (lex/parse/check) + ALL arg lowering is untouched; only the back-edge
  branches: `#include "gba_api.h"`, the zero-page fastcall ABI is SKIPPED (ARM has
  none) so every builtin is a plain `gba_*(args)` call, camera/btn ZP inlines are
  GameTank-only, and the harness is libtonc-shaped (`gba_init`/`gba_vsync`/
  `gba_endframe`). A `cName()` remap turns the shared builtins table's `gt_p8_*`/
  `gt_*` names into `gba_*` at the call site (NO forked builtins.js — single
  source). GameTank path fully intact (verified).
- **`gba-sdk/gba_api.{h,c}`**: thin libtonc wrappers. `gba_spr` = a real HARDWARE
  OAM sprite (shadow buffer flushed by `gba_endframe` via `oam_copy`); `gba_cls`,
  `gba_btn`/`gba_btnp` (latched input), procedural placeholder tiles (no asset
  pipeline yet). ~130 lines, zero asm — exactly the "thin glue not an engine" bet.
- **Proof**: `spike0/game.lua` (move a sprite with L/R) built via
  `spike0/build_game.mjs`, ran on mGBA: held RIGHT 30 frames → player sprite x
  went 20→50 (+1/frame, exactly `if btn(1) then x += 1`). `spike0/game_moved.png`
  shows both sprites. Input→btn→game-logic→OAM loop CONFIRMED end to end.

### Real sprite art (2026-07-14): NOT colored squares anymore
Switched the runtime from 8bpp solid-color placeholder tiles to **4bpp** (romdev's
GBA tile format: 4bpp linear "obj 4bpp", 32 B/tile, 16-color palette — see
`platforms/common/image-to-tiles.js`). Hand-authored a real 16×16 alien sprite
(`spike0/make_sprite.mjs` → `gba-sdk/alien_sprite.h`: green creature w/ eyes,
belly, feet). Renders correctly on mGBA (`spike0/alien.png` / `alien_zoom.png`),
including HW hflip via `spr(0,x,y,2,2,true)`. A 16×16 4bpp sprite = 4 tiles, so
`spr(n)` uses base tile `4*n`. Temp art — the PNG→tile importer (romdev
`convertImageToTiles`/`encodeArt`, 4bpp, bundled grit) replaces `make_sprite.mjs`
but MUST emit this same 4bpp format so runtime + importer agree.

## Spike 2 — DONE ✅ (2026-07-14): shapes + text + sprites, clean

Full PICO-8-shaped drawing surface working together (`spike0/hello.lua` →
`hello_win.png`): dark-blue bg, red rect, green circle, "gba-lua"/"hello gba"/
"score" text in PICO-8 colors, two alien sprites with faces — no garbage/tearing.

- **Rendering model (the core design decision):** Mode-4 8bpp paletted BITMAP
  (BG2) for immediate drawing (cls/rect/circ/line/pset/print) + hardware OBJ
  sprites composited on top. DOUBLE-BUFFERED (draw to hidden back page, flip at
  vblank). Fixed PICO-8 16-color palette in BG+OBJ palette so `cls(1)` etc. are
  the real PICO-8 colors.
- **Verbs added** (all libtonc-backed, in `gba-sdk/gba_api.c`): `cls`, `color`,
  `pset`, `rect`, `rectfill`, `circ`, `circfill` (midpoint, clipped), `line`,
  `print`/`print_int`/`print_num` (+cursor forms) via **Tonc TTE** over the
  Mode-4 surface. Emitter: gated the GameTank color-BAKE (GBA passes raw 0-15
  index — the runtime palette IS the PICO-8 palette) + routed print's special
  emission through `cName`.

### HARD-WON GBA/libtonc gotchas (each cost real time; all caught by inspectors)
1. **`vid_page` inits to the BACK page** (0x0600A000), not front. Draw with no
   flip → invisible page → black screen. (VRAM read at offset 0 showed 00.)
2. **Mode-4 sprite tiles MUST start at index 512+** — bitmap modes use the first
   512 OBJ tiles as the bitmap's 2nd page. Load sprite art at `tile_mem[5]`,
   `spr()` adds base 512. (sprites in OAM but invisible → this.)
3. **TTE holds its dst surface BY VALUE** (`TTC.dst` is a `TSurface` struct, not
   a pointer). `tte_init_bmp` COPIES `m4_surface` in. To double-buffer, repoint
   `tte_get_context()->dst.data` each frame — repointing the global `m4_surface`
   does NOTHING. (text vanished under double-buffering → this.)
4. **Single-buffer Mode-4 overruns** on a heavy frame (cls 38KB fill + shapes +
   TTE glyphs) → the beam catches a half-drawn frame (saw "hel" instead of
   "hello gba"). Double-buffer is the fix, not optional.
5. **libtonc m4_plot/m4_hline DON'T clip** — off-screen coords wrap across the
   240-wide fb and corrupt other rows. Clip in circ/circfill (SCRW/SCRH).

### Reusable gotchas found (save future time)
1. **PICO-8 btn order is 0=LEFT 1=RIGHT 2=UP 3=DOWN** (NOT U/D/L/R). First
   BTN_MASK table was wrong; RIGHT did nothing. gt-lua README §input is the
   authority (0-3 d-pad, 4=A/🅾, 5=B/❎, 6=C/L, 7=START).
2. **romdev `input({op:'set'})` must be RE-APPLIED right before the consuming
   frame step** (or use `op:'sequence'` which holds across N frames). A `set`
   done long before a step can read as "nothing pressed" — verify via the
   KEYINPUT reg / held-RAM byte, not the tool's `requested` echo.
3. **romdev build multi-file param is `includes` (headers) + `sources`**, not
   `headers`. The tool lists valid params in the error — read it.
4. **DISPCNT must enable OBJ + clear forced-blank** or a perfect OAM renders
   blank (Spike-0 bug; `background({view:'renderState'})` catches it instantly).

## Spike 3 — DONE ✅ (2026-07-14): affine sprites + fixed-point math + CLI

The HEADLINER works from Lua, plus the number model, plus a one-command build.

- **Affine sprites (`sprr`)** — `sprr(n, x, y, angle, [scale])` = a rotated+scaled
  HARDWARE sprite via `obj_aff_rotscale` + an allocated OBJ affine matrix (32
  avail). angle in PICO-8 turns, scale a fixed multiplier (default 1.0). Verified
  live: `spike0/spin.lua` → two aliens visibly rotating + one pulsing-scaling
  (`spin1.png`/`spin2.png`), `sprites({op:'inspect'})` shows `affine:true`. This
  is the GBA feature the whole SDK exists for, driven from ONE line of Lua.
  (Phase 1 = flat `sprr()`; Phase 2 mutable handles `s.angle=t()` = later, needs
  new AST/check.js work.)
- **Fixed-point math runtime** (`gba-sdk/gba_math.c` + `gba_sintab.h`): 16.16
  sin/cos/sqrt/atan2/rnd/t. Emitter now emits NATIVE C for fixed `*`/`/`/`%` on
  GBA (`(long long)a*b>>16` etc.) — the ARM hardware multiply/divide means NO
  runtime call, NO zero-page fa/fb staging (the whole gt_fmul/gt_fdiv/_zp 6502
  apparatus is gated off for isGba). The number model going faster+simpler on
  better hardware, exactly as the plan predicted.
- **CLI** (`gtlua build --target gba main.lua [-o out.gba]`): a `--target gba`
  branch in `bin/gtlua.js` → `compiler/build-gba.mjs` (Lua→C + bundles the
  gba-sdk runtime, delegates C→ROM to the live romdev arm toolchain over MCP).
  One command, working. `spike0/build_game.mjs` is the older inline version.

**Regression check:** pure-compiler suite `test/compiler.test.js` = 83/83 green —
all my emitter changes are gated on `isGba`, GameTank path untouched. (The
`api_units`/`math`/`draw` build-tests fail here only because this clone has no
`node_modules` — they build real GT ROMs needing the WASM toolchain; not a code
regression.)

**Where the SDK stands now:** a Lua game can use cls/color/pset/rect/rectfill/
circ/circfill/line/print (Mode-4 bitmap + TTE) + spr/sprr (HW sprites, incl.
affine) + btn/btnp + the full fixed-point number model (sin/cos/etc.) + the
`_init`/`_update`/`_draw` loop, built to a real `.gba` with one command and
verified on mGBA. That's a genuinely usable slice.

## Session 4 (2026-07-14): the "make real games possible" push

Reframed by monteslu: "leverage the easy PICO-8 syntax while adding ALL of the
GBA power" — not a PICO-8 clone, a real 32-bit console with a friendly hand. And
"often it's BOTH" (tiles AND sprites AND effects together, not either-or). A full
libtonc+maxmod capability map + gap analysis is in this session's notes; Tier-0
gaps = tilemaps/scroll, sound, VBlank loop (loop already done).

**DONE this session:**
- **Hardware TILE backgrounds (Mode 0)** — `gba-sdk/gba_bg.c`: 4 BG layers,
  tilesets→charblock, tilemaps→screenblocks (incl. >32-wide multi-SBB), hardware
  scroll via `gba_camera`/`gba_layer_scroll` (parallax factors), `mget`/`mset`,
  priority. VERIFIED at C level (`spike0/tiletest.c`): a 40×30 map renders +
  scrolls smoothly (REG_BG0HOFS confirmed driven; screenshots `tile1/2.png`).
  This is THE real-game path (vs the slow Mode-4 bitmap) — scrolling worlds for
  free. **Still TODO: the Lua verbs for it** (tileset/tilemap/layer/camera) — the
  runtime works, the compiler binding isn't wired yet.
- **Real asset pipeline (PNG→sprites)** — `compiler/png-tiles.mjs`: a
  self-contained PNG→GBA-4bpp converter (zlib decode + palette-from-image +
  16×16 sprite-block tile order). `gtlua build --target gba game.lua --sheet
  sprites.png` converts the PNG, generates `gba_assets.h`, bundles it; `spr(n)`
  now draws real art. VERIFIED: `spike0/sheet.lua` + `sheet.png` → crisp red
  heart + gold coin on hardware (`sheet_final.png`), incl. a spinning coin via
  `sprr`. No more hand-authored alien.
- **romdev bug found + reported** (`feedback_from_mcp_client_gba_encodeart_
  palette.md`): `encodeArt(tiles, gba)` emits a broken placeholder palette
  ("no master palette for gba"). We bypass it with our own converter; the tile
  bytes were fine, only its palette was junk.

**Rendering model clarified:** Mode-4 bitmap (pset/rect/circ + TTE text) and
Mode-0 tiles are the one real either-or (a hardware mode bit); sprites/sound/
effects work in BOTH and compose freely. A game picks its BG style.

**Tile Lua verbs + PNG tilemap — DONE (same session):**
- Lua verbs wired: `map_show(layer)`, `camera(x,y)` (hardware scroll), `layer_show`,
  `layer_pri`, `layer_scroll`, `parallax(layer,factor)`, `tget`/`tset`. All
  gbaOnly, map to gba_bg.c. (Named `tget`/`tset` not `mget`/`mset` to avoid the
  GameTank builtins' clashing 2-arg signature.)
- `--map level.png` → `pngToTilemap` (self-contained: deduped tiles + u16 map +
  palette) → `gba_map_asset.h` → `gba_map_show` loads it. PNG must be Nx8/Mx8.
- **VERIFIED the real-game shape** (`spike0/platformer.lua` + level.png +
  sheet.png): a scrolling tile LEVEL (sky/stars/brick platforms) + a hardware
  sprite player + camera-follow, ONE `gtlua build --target gba x.lua --sheet s.png
  --map level.png` command. `plat1.png`/`plat2.png` show the camera scrolling the
  hardware tilemap as the player moves. Tiles + sprites compositing together =
  the "BOTH" model working. Compiler suite 83/83, no regressions.

**Sound (maxmod) — DONE (2026-07-15).** `gba-sdk/gba_sound.c`: `music(n,[loop])`,
`music(-1)` stop, `sfx(n)`, module + sample playback via maxmod. Ships romdev's
bundled chiptune soundbank (`assets/soundbank.bin`, MOD_CHIPTUNE=0) so `music(0)`
works out of the box; build auto-links maxmod + embeds the soundbank ONLY when the
game calls music/sfx (detected in the emitted C → `GBA_HAVE_SOUND` via the
generated `gba_config.h`, so both TUs see it). VERIFIED: `spike0/music.lua` +
tiles-with-sound both run — Direct Sound both FIFOs active, timer clocking, no
crash, video intact (`music_final.png`).
  - **HARD-WON:** maxmod's `mmVBlank` (installed AS the vblank IRQ handler, before
    mmInitDefault) RACED the Mode-4 double-buffer `vid_flip` → black screen with
    sound on. FIX: Mode-4 bitmap is now SINGLE-BUFFERED (draw to the front page,
    no flip). Tile games (the real-game path) were never affected. Also: don't
    call gba_sound_init TWICE (I did; mmInitDefault twice → undefined-instruction
    crash, caught by cpu({op:'read'}) showing mode:"undefined").
  - Custom audio = bring your own soundbank.bin (built offline by mmutil, not
    bundled). Only the chiptune ships by default.

**Session 5 (2026-07-15): richer sprites + a REAL GAME (STARFALL shmup).**
- **Richer sprites** (gba_api.c): `spr(n,x,y,w,h,flip)` now picks square/wide/tall
  shape + size (8/16/32/64) from w,h; `spr8(t,x,y,[flip])` = 8x8 sprite from a raw
  tile (bullets/pickups); `spr_pal(bank)` + `spr_prio(p)` = per-sprite palbank +
  BG-priority (stateful, reset each frame). Emitter: native integer `\` (gba) +
  `gba_run()` (SoftReset restart) added.
- **STARFALL** (`examples/starfall/main.lua`): a complete shmup — player ship,
  12-enemy formation, bullets (spr8), bullet↔enemy collision, score/lives, win
  (clear all) / lose (enemy reaches you) states, `run()` restart. Tiles (scrolling
  starfield) + hardware sprites all composited. **VERIFIED PLAYABLE:** fires
  bullets, kills enemies, cleared all 12 → reached WIN state, stable 391 frames,
  no crash (inspectors: sprites/cpu/oam). This is a REAL game, not a demo.
- The game surfaced real gaps the tech demos couldn't (the point of building it):
  array-size-must-be-a-literal, top-level-const-init, `gt_ifdiv`/`gba_run`
  missing — all fixed with the loud compiler errors pointing right at them.

## Session 6 (2026-07-15): fix the two known bugs (1 fixed, 1 deep)

**TILED HUD TEXT — FIXED ✅.** Root cause was a **VRAM layout collision**: the text
glyph charblock (was CBB3, 0x0C000-0x10000) OVERLAPPED the map screenblocks
(SBB 28-31 at 0x0E000-0x10000). Clearing the glyph charblock wiped the game's
tilemaps → black screen; unwritten glyph tiles showed as garbage. FIX: text
glyphs → CBB2 (0x08000, clear of both game tiles CBB0 and the screenblocks); text
map → SBB 31 (BG3); text layer priority 0 (frontmost), game tile layers bumped to
priority 1+ so text draws ON TOP. `gba_text.c` uses `tte_init_chr4c` (sys8 font).
VERIFIED: "HELLO" + STARFALL's "score" HUD render cleanly over the tile bg
(`txtF.png`, `examples/starfall/hud.png`). Text works in tile mode now.

**SOUND-UNDER-LOAD CRASH — DEEP, NOT YET FIXED.** Exhaustively isolated (many
build/run/cpu-inspect cycles). Findings:
- Canonical romdev `maxmod_demo.c` runs 200f stable → maxmod itself is fine.
- Minimal sound game (no drawing) + sound: STABLE.
- Tiles + sprites + sound (no text): STABLE (200f+).
- **HEAVY sprites (13/frame) + sound, NO text: STABLE (400f).**
- **ANY `print` (TTE) called PER-FRAME + sound → CRASH** (wild branch to
  0x08000000, mode→"undefined", ~100-400f, variable). Print ONCE in _init +
  sound = stable. So it's TTE-per-frame + maxmod SPECIFICALLY.
- Ruled OUT: printf/newlib stack (hand-rolled itoa, still crashes); IRQ nesting
  (REG_IME guard around tte_write, still crashes); the per-frame text-clear
  (removed, still crashes); tile-tile-cursor overflow (constant string, still
  crashes); the dirty-text CACHE (skips writes when unchanged) — BUT bg3b.lua
  (static text printed every frame, cache→zero writes) + sound STILL CRASHES,
  while bg3.lua (print once) is stable. So the crash correlates with CALLING
  gba_print every frame even when it writes nothing — points at something subtle
  (stack/timing) NOT the TTE write itself. Genuinely deep; needs more tooling
  (map the exact fault PC, or trace maxmod's IRQ vs the per-frame call).
- Current STARFALL: sound ENABLED + dirty-text cache, but STILL crashes (~400f)
  because it prints every frame. Options to ship: (a) print HUD only on-change
  from Lua (not every frame), (b) sprite-based HUD (no TTE), (c) ship sound OFF
  again until root-caused. LEANING (a)/(b) — a game needs both sound AND a HUD.

**KNOWN BUGS the game exposed (honest — these gate "good games", fix next):**
1. **Sound crashes the full game UNDER LOAD.** maxmod (music+sfx) works in simple
   demos (music.lua) but the full shmup + sound → intermittent wild-branch crash
   to 0x08000000 (undefined-instr, mode flips to "undefined") after tens of
   frames. Isolated conclusively: full game WITHOUT sound = 120+ frames stable;
   WITH sound = crashes. STARFALL ships with sound COMMENTED OUT for now. Likely
   a maxmod integration issue (mmFrame/mmVBlank timing or effect-channel churn
   under a busy frame) — NOT the game logic. THE #1 fix.
2. **Tiled-mode text doesn't render.** `print` in tile mode (Mode 0) now routes to
   a tiled TTE on BG3 (gba_text.c) instead of corrupting tile VRAM (that WAS
   fixed — no more corruption/crash from print). But the chr4c text layer shows
   nothing yet (setup/font-upload/palette issue in gba_text.c). So STARFALL's
   HUD + win/lose text are invisible. Bitmap-mode print still works fine.

**Remaining after those:** blend/fade effects (easy, high impact), mode7, windows,
big-map streaming, animation helpers, more example games.

## Session 7 (2026-07-15): sprite-based HUD — tile+sound now ships ✅

**SPRITE-BASED HUD (no TTE) — DONE ✅.** The TTE+maxmod tile-mode crash (Session 6
bug #1/#2, never root-caused) is now SIDESTEPPED for good: in tile mode `print()`
draws each character as an 8x8 hardware OBJ sprite instead of writing glyph tiles
via TTE. Heavy sprites + maxmod was already proven stable, so a sprite HUD is too.

- `gba-sdk/gba_font.h` — baked 8x8 4bpp font, 40 glyphs (space, 0-9, A-Z, `:`, `-`,
  `!`), ink = color index 1. `gba_font_tiles[320]` + `gba_font_map[96]` (char→glyph).
- `gba_api.c`: font tiles load at OBJ tile 900 (clear of the sheet's 512..~899),
  palbank 15 color 1 = white (`load_sprite_tiles`). `hud_glyph`/`hud_draw_str`/
  `hud_draw_int` emit one OAM entry per char. `gba_print`/`_int`/`_num` route to the
  sprite HUD when `in_tile_mode()` ((REG_DISPCNT&7)<=2); bitmap mode keeps TTE.
- Removed the dead dirty-text cache (`txt_cache`/`txt_unchanged`/…) — the tile path
  no longer touches TTE, the bitmap path writes unconditionally (no maxmod conflict).
- Build: `gba_font.h` added to build-gba.mjs includes. Clean compile, no warnings.

**VERIFIED with SOUND ON:** STARFALL (music(0) + sfx) — "SCORE0/LIVES3" renders,
score digit updates live to "SCORE30" as enemies die, GAME OVER screen text renders,
run()/restart survives — and cpu({op:'read'}) stays `mode:system` through **1020+
frames** (the old TTE crash hit at 100-400f). Both Session-6 bugs closed by one fix.

Note: gba_text.c (tiled TTE) stays linked for bitmap-mode games; it's just unused by
tile+sound games now. The root-cause TTE/maxmod conflict is still not understood —
we routed around it, which is the right call (a game needs sound AND a HUD).

## Session 8 (2026-07-15): color effects — blend + fade ✅

**HARDWARE COLOR EFFECTS — DONE ✅.** The GBA's PPU blend unit (FREE, no per-pixel
CPU) exposed as two friendly verbs. New GBA capability → new verbs (the right call
per the "familiarity + full power" principle).

- `gba-sdk/gba_fx.c` (new) — drives REG_BLDCNT/BLDALPHA/BLDY:
  - `fade(amount, [white])` — brightness fade of the WHOLE screen (all BG layers +
    sprites + backdrop) to black (default) or white. amount 0..1 (16.16). The
    level-wipe / hit-flash / pause-dim workhorse. amount<=0 → blend unit off.
  - `blend(layer, alpha)` — alpha-blend one layer over the scene behind it (glass/
    ghost/dimmed-UI). layer 0..2 tiles, 3 text, 4 sprites; alpha 0..1. Top = layer
    at eva=alpha, bottom = every OTHER target at evb=(1-alpha) → true cross-fade.
  - `blend_off()` — clear all effects. Also called in gba_init (no stale fx at boot).
- Amounts arrive as 16.16 fixed; `fx_coeff()` → 0..16 GBA weight (rounds, clamps).
- `defaultFor("fade")` = 0 so `fade(a)` defaults to BLACK (a "flip"-typed white flag,
  omitted → 0, not the generic -1 which `((-1)?1:0)`=1 would wrongly read as white).
- Builtins: `blend`/`fade`/`blend_off` (gbaOnly). gba_fx.c added to build sources.

**VERIFIED on mGBA (screenshots):**
- New `examples/effects/` (blob.png, bitmap-mode scene): fade-to-black, fade-to-white,
  and hold-A sprite ghost (blend(4,0.45)) all render correctly; transitions between
  modes clean; cpu stays `mode:system`.
- STARFALL: added a fade-IN from black at start + a capped (0.7) fade-OUT on game-over
  — proves fade works in TILE mode over hardware tile layers + OBJ sprites + the
  sprite HUD + maxmod, all at once. GAME OVER text stays readable under the dim. Ran
  960+ frames, stable.

Blend state is stateful (persists across frames) BY DESIGN — a fade holds until the
game changes it; gba_endframe doesn't touch it. 83/83 compiler tests green.

**Still deferred (task 12 residue):** windows (REG_WINx clipping regions),
big-map streaming, animation helpers.

## Session 9 (2026-07-15): Mode 7 — affine background ✅

**MODE 7 (AFFINE BG) — DONE ✅.** The GBA's signature effect: BG2 as a flat plane
you rotate/scale/scroll entirely in hardware (F-Zero ground, spinning maps). Three
verbs; genuinely new capability → new verbs.

- `gba-sdk/gba_mode7.c` (new) — drives BG2's affine registers via libtonc:
  - `mode7()` — load the bundled affine plane onto BG2, switch to Mode 1 (so BG0/1
    + the text/HUD layer still draw on top). CBB1 for 8bpp tiles, SBB20 for the
    1-byte map, BG_WRAP on (endless plane), priority 2.
  - `mode7_cam(x, y, angle, [zoom])` — per frame. Builds an AFF_SRC_EX (texture
    anchor = world (x,y) in .8, screen anchor = center 120,80, step = 1/zoom in
    8.8, angle = turns→[0,0xFFFF]) → `bg_rotscale_ex()` → `REG_BG_AFFINE[2]`. x/y
    arrive as 16.16; zoom defaults to 1.0.
  - `mode7_off()` — hide the affine layer.
  - Safe no-op stubs when no --mode7 asset (game still links).
- **Asset pipeline:** affine BGs are 8bpp (1 byte/px, 16 words/tile), single 256-
  color palette, SQUARE power-of-2 map (16/32/64/128 tiles) with 1-byte cells. Added
  `pngToAffineMap()` to png-tiles.mjs + `convertMode7()` + `--mode7 plane.png` CLI
  flag → `gba_mode7_asset.h` (m7_tiles/m7_map packed 4 cells/u32/m7_pal/m7_side).
- KEY GOTCHAS baked in: affine P is an INVERSE map (screen→texture) so the per-pixel
  step = 1/zoom, NOT zoom; the affine map is 1 byte/cell (memcpy32 as packed words);
  Mode 1 (not 2) keeps BG0/1 for a HUD. The sprite HUD works over Mode 1 (in_tile_mode
  is `(DISPCNT&7)<=2`, Mode 1 = 1) and OBJ palbank 15 is clear of the BG 256-palette.

**VERIFIED on mGBA (screenshots):** new `examples/mode7/` (generated 256x256 plane.png,
grid + road + checkered band): base plane renders + sprite-HUD on top; d-pad LEFT
rotates the whole plane; A zooms in (2x); UP drives forward along the heading with
wraparound. cpu stays `mode:system` through 540+ frames. 83/83 compiler tests green;
all existing examples still build.

**Still deferred:** big-map streaming, anim helpers.

## Session 10 (2026-07-15): windows — hardware clip regions ✅

**WINDOWS — DONE ✅.** The GBA's rectangular clipping regions (FREE in the PPU): a
screen rect where you pick which layers are visible. Spotlight/iris reveals, HUD
panels, region-masked blending. New capability → new verbs.

- `gba-sdk/gba_win.c` (new) — drives REG_WIN0H/V + REG_WININ/WINOUT + DCNT_WIN0:
  - `window(x0,y0,x1,y1)` — SPOTLIGHT: show everything inside the box, hide outside
    (WININ = WIN_ALL|WIN_BLD, WINOUT = 0). The one-call reveal/iris/peek. Covers most uses.
  - `window_inside(x0,y0,x1,y1, layers)` — general: `layers` bitmask (1=BG0 2=BG1
    4=BG2 8=text 16=sprites; 31=all) picks what shows inside the box.
  - `window_outside(layers)` — what shows OUTSIDE the box(es) (default none/hidden;
    pass 31 to keep the full scene outside and use the box only to override a region).
  - `window_off()` — disable windowing (full screen). Also called in gba_init.
- `layers` bits line up 1:1 with GBA WIN_BG0..WIN_OBJ; WIN_BLD kept on inside so
  fade/blend still work within a window. Edges clamped to [0,240]/[0,160].
- No new asset/CLI plumbing (windows are pure geometry from Lua ints).

**VERIFIED on mGBA (screenshots):** new `examples/windows/` (spotlight over the Mode-7
plane): centered box reveals the plane, outside is black; d-pad MOVES the box; A GROWS
it; sprites (the HUD text) are correctly clipped by the window too; L → window_off →
full screen back. Composes with Mode 7. cpu `mode:system` through 480+ frames. 83/83
compiler tests green; all 5 examples build.

**Effects epic COMPLETE** (blend, fade, mode7, windows all shipped). Remaining SDK
work is polish: big-map streaming, animation helpers, more games.

## Session 11 (2026-07-15): animation helpers ✅

**ANIMATION HELPERS — DONE ✅.** Turn a frame RANGE + speed into "which frame now",
timed off the boot frame clock. Replaces the hand-rolled `spr(1+flr(t*8)%4,...)` idiom.

- `gba-sdk/gba_anim.c` (new) — a 32-slot animator pool (static, no heap):
  - `anim(slot, first, last, fps)` → current frame, LOOPS. Feed to spr(): `spr(anim(0,0,3,10),x,y)`.
  - `anim_once(slot, first, last, fps)` → plays once, HOLDS on last; `anim_done(slot)` goes true.
  - `anim_pingpong(slot, first, last, fps)` → bounces first..last..first.
  - `anim_reset(slot)` → restart / re-arm. `fps` is 16.16 animation-frames/sec.
- Timing: `gba_math.c` gained a `frame_no` counter (gba_ticks()) advanced in gba_time_tick;
  each animator does delta timing (real frames * fps / 60 → 16.16 acc → whole frames).
  Frame-rate independent of how the game structures its update.
- CONVENTION: `anim_done()` returns int → Lua needs `!= 0` (checker requires explicit
  boolean compare). Documented in the example.

**VERIFIED on mGBA (screenshots):** new `examples/anim/` (generated 4-frame critter.png):
three critters run the SAME sheet as loop / pingpong / once at different fps; frames
visibly advance independently; "DONE" appears when the once-anim finishes; A → anim_reset
re-arms it (DONE clears, replays). cpu stable.
- GOTCHA FOUND + FIXED IN THE EXAMPLE: first cut used cls() → BITMAP mode → TTE text,
  which TRUNCATED ("anim hel", "l") — the same bitmap-TTE fragility. Switched the example
  to a tile background (map_show) so print() uses the ROBUST sprite HUD → text renders
  clean. (Confirms: prefer tile-mode + sprite HUD; bitmap TTE is flaky. Feeds task 18.)

## Session 12 (2026-07-15): TTE+maxmod crash ROOT-CAUSED + FIXED ✅✅

**THE SOUND-UNDER-LOAD CRASH IS FINALLY ROOT-CAUSED AND FIXED AT THE SOURCE.** For
6 sessions this was only sidestepped (Mode-4 single-buffer, sprite HUD). Now solved.

**Root cause (proven by bisection):** `mmInitDefault()` `calloc()`s maxmod's channel
buffers from the C HEAP. On this toolchain the heap ALIASES in-use `.bss` — the
calloc'd channel structs overlapped libtonc's `__tte_main_context`. The FIRST tiled
`print()` runs `tte_init_base()` → `memset(__tte_main_context, 0, sizeof(TTC))`, which
silently ZEROED maxmod's channel pointers. The NEXT `mmFrame()` dereferenced them →
wild branch → undefined-instruction crash (`mode:undefined`, LR=0x08000000, ~frame 6).

**The bisection that nailed it (all via romdev cpu({op:'read'}) + a GBA_FORCE_TTE debug flag):**
- TTE-in-tile-mode ALONE (no sound): 200f clean.
- maxmod + heavy sprites (no TTE): 400f clean.
- maxmod + forced tiled TTE: crashes deterministically at FRAME 6 (the TTE-init frame).
- Masking IME around the WHOLE TTE op: STILL crashes → NOT an IRQ-during-TTE race.
- **Disabling mmFrame(): crash VANISHES** → the crash is INSIDE mmFrame reading corrupt state.
- → TTE-init corrupts maxmod state that mmFrame reads = the calloc/.bss overlap.

**The fix (`gba-sdk/gba_sound.c`):** replaced `mmInitDefault` (heap calloc) with `mmInit`
+ STATIC, linker-placed buffers (module/active/mixing channels + wave + mix memory,
16ch @ 16kHz, sizes from the maxmod GBA ABI). No heap → nothing can alias maxmod's
state. Also matches the SDK's no-heap philosophy.

**VERIFIED on mGBA:**
- The exact repro (forced tiled TTE + music + per-frame print) that crashed at frame 6
  now runs **600 frames clean**; the tiled text ("frame N") renders live over sound.
- Audio still works: `audioDebug record` with A held (firing sfx) = RMS ~8700, peak
  ~32766 (LOUD) on BOTH the old mmInitDefault build and the new mmInit build → the fix
  preserves sound. (Idle music module 0 is quiet by nature; SFX prove the pipeline.)
- STARFALL (sprite HUD + sound): 1000 frames stable, sfx audible on fire.

The SPRITE HUD stays the DEFAULT for tile-mode print() (crisp, frees BG3, no per-frame
VRAM writes) — but tiled TTE is no longer a landmine, so a game CAN use it with sound now.
Debug scaffolding (GBA_FORCE_TTE / GBA_NO_MMFRAME) removed. 83/83 tests green.

## Session 13 (2026-07-15): richer music module + CORRECTION to session 12

**RICHER BACKGROUND MUSIC — DONE ✅ (bitmap mode).** Replaced the old 2-channel
arpeggio chiptune with a proper 4-channel tune (lead + bass + arp + noise drums, 3
instruments with volume envelopes, 4 patterns, 8-bar A-minor loop). Fully synthesized
from primitives (CC0). New pipeline in `assets/`:
- `make_music_xm.mjs` → `music.xm` (2513 B FastTracker II, 4ch/4pat/3inst).
- `build_soundbank.mjs` → `soundbank.bin` (3096 B, was 1420) + `soundbank_ids.h`, via
  romdev's pure-JS mmutil (`romdev-maxmod` `soundbankFromModule`, byte-identical to mmutil).
  Kept the module name 'chiptune' so `MOD_CHIPTUNE = 0` / `music(0)` is unchanged (drop-in).
- VERIFIED playing: `audioDebug record` on a bitmap-mode (`cls`) music test = RMS ~2613,
  multi-octave harmonic content across the loop (Goertzel: bass+lead+arp simultaneously).

**★ CORRECTION to Session 12: the mmInit static-buffer "fix" BROKE MODULE PLAYBACK. ★**
Session 12 claimed audio still worked — but that was only verified with SFX (mmEffect).
This session found (clean bitmap music tests): mmInitDefault plays modules (RMS ~3300);
the Session-12 static-buffer `mmInit` = SILENT for `mmStart` (sfx still fine). Some mmInit
setup detail (buffer placement/config) is wrong. **REVERTED gba_sound.c to mmInitDefault**
— the proven path for BOTH music and sfx. The TTE+maxmod crash it was dodging only fires
with FORCED tiled TTE (not the SDK default sprite HUD), so normal games are unaffected;
a tiled-TTE-plus-sound game should use bitmap text or the sprite HUD.

**★ NEW BUG FOUND (pre-existing, not the new module): TILE MODE silences MODULE music. ★**
`map_show()` (tile Mode 0) + `music(0)` = SILENT; `cls` (bitmap Mode 4) + `music(0)` =
PLAYS. Confirmed with BOTH the old and new soundbank (so it's not the module) and with
mmFrame running (sfx audible in the same tile ROM — STARFALL fire = RMS ~8700). The
module's MAIN LAYER produces no samples in tile mode while the effect layer does. Sound
HW is fully correct in tile mode (SOUNDCNT_X=0x80, DMA1=0xB640 enabled, Timer0 running).
LIKELY the SAME heap-aliases-.bss root cause as the crash: mmInitDefault's calloc'd wave
buffer overlaps ACTIVELY-USED .bss in tile mode (bigger footprint: OAM shadow, BG state)
→ the wave buffer is overwritten with silence each frame; sfx re-mix fresh so they punch
through. The real fix = static-buffer mmInit (no heap) — BUT that needs the module-playback
setup detail cracked first (see the correction above). DEFERRED — needs deeper maxmod RE.
Net today: music is RICHER and plays in bitmap-mode games; tile games have working SFX,
music silent (pre-existing). 83/83 tests green; all 6 examples build.

## Session 14 (2026-07-15): music-playback deep-dive — EMULATOR RULED OUT, quirk isolated

**KEY: the emulator's audio WORKS — verified against a REAL commercial ROM.** Loaded
`~/Downloads/NBA Jam 2002 (USA, Europe).gba`, advanced to its MAIN MENU, `audioDebug
record` = RMS 3595 (music plays). So mgba's DirectSound + the WAV capture are fine; the
maxmod-music issue is OURS, not the emulator/tooling. (Splash screens are silent — step
past them with start before recording. This is a reusable audio-sanity oracle.)

**Refined the trigger by bisection (all `audioDebug record`):** the earlier "tile mode
silences music" was a RED HERRING. The REAL discriminator is `print()`:
- `music(0)` + `print(...)` (any real text) → module PLAYS (RMS ~2900), bitmap OR tile.
- `music(0)` alone / + `cls` / + `pset` / + `rectfill(100x100)` / + a 30k busy-loop /
  + an empty `tte_write("")` → ALL SILENT.
- Only a real TTE GLYPH render (`print` with text) unsticks the module. SFX always play.
So it's something SPECIFIC to the TTE glyph code path (a function-pointer call chain +
its .bss context), NOT tile-vs-bitmap, NOT VRAM-write volume, NOT CPU-starvation, NOT IME.

**Also ruled out for the no-heap fix:** static-buffer `mmInit` does NOT play modules even
with print AND explicit buffer zeroing (struct offsets verified correct vs the maxmod GBA
ABI; sfx work, modules silent). So mmInit has its own unsolved module-setup bug — it's not
the escape hatch. And combining `music(0)` with a full example (effects: shapes+print+fx)
HANGS/crashes (0xE3A0100C wild-branch) — the layout-dependent heap/.bss aliasing again.

**Conclusion + shipped state:** module music is entangled with an mgba↔maxmod interaction
(the TTE-glyph-path dependency) AND layout-dependent heap/.bss fragility that I could not
resolve without deeper maxmod/newlib RE. SHIPPED: mmInitDefault + the richer 4-channel
soundbank + the working music()/sfx() API. Music PLAYS in bitmap games that print a HUD
(the realistic case); SFX are reliable everywhere; the shipped examples keep music OFF so
they stay rock-solid (STARFALL: music+sfx, sprite HUD, 500f stable, sfx audible). The
`music()` API is correct and ready for when the underlying quirk is cracked. DEFERRED with
a full evidence trail. 83/83 tests; all 6 examples build; tree clean of all diagnostics.

## Session 15 (2026-07-15): NATIVE-LEVEL RE of the music silence (cycle-accurate debugger)

Went to the metal per the mandate "understand EXACTLY how native works then fix this."
Used cpu({op:read}) + breakpoint({on:pc})+registersAtHit + watch({on:pc}) coverage +
disasm({target:rom,thumb}) + audioDebug({op:inspect,chip:gba}) on the SILENT vs PLAYING
builds. Read the maxmod GBA asm source (mm_main_gba.s / mm_mas.s / mm_mixer_gba.s) to know
exactly what to check.

**EMULATOR IS FINE:** a real ROM (NBA Jam 2002) plays audio on its menu (RMS 3595).

**maxmod runs CORRECTLY in the silent case — every stage verified by execution trace:**
- `gba_music(0)`: sound_ready=1 (r3=1 at the check), n=0 → falls through to `bl mmStart`.
- `mmStart`/`mmPlayModule` EXECUTE (coverage trace of 0x0800B848+ shows the whole body).
- `mmFrame` module path: at the ISPLAYING check (`ldrb r1,[mmLayerMain,#6]; cmp; beq skip`)
  it does NOT take the skip branch → the module IS processed; the mix loop (0x0800D354+)
  and `mmMixerMix` (IWRAM 0x03000800) run 600+ times/3 frames — actively mixing.
- `mmVBlank` (IWRAM 0x0300077C) runs each vblank incl. the DMA-restart + segment-swap path.
- Sound HW registers are BYTE-IDENTICAL silent vs playing: SOUNDCNT_H=0x0C12, SOUNDCNT_X=
  0x80, DirectSound A→L / B→R both enabled @100%, SOUNDBIAS=0x200, DMA1 enabled/FIFO. Same.

**So the ONLY difference is the mixed PCM values** — the mixer's accumulator registers are
all ZERO in the silent case (the module's mixing channels output silence), while the
byte-identical code + hardware with `print` produces signal. Ruled OUT as fixes: mmFrame/
VBlank reorder, double mmFrame, busy-wait CPU burn, a 4KB .bss layout-shim, forcing module
volume — all still silent. The maxmod mixer disables each channel at init (CHN_SRC bit31=1)
and `mppProcessTick` re-enables it when a note triggers; the zero accumulators point to the
channels never getting enabled (CHN_SRC still 0x80000000) — but CONFIRMING that needs to
read one IWRAM byte in the mix-channel struct (~0x030017xx)...

**BLOCKED by a romdev tool defect (documented):** `memory({op:read, region:system_ram})`
and `breakpoint captureMemory` return ALL ZEROS for GBA IWRAM (0x03xxxxxx) — the region
does not map IWRAM (reads the live stack @0x03007xxx as zeros too). Every maxmod runtime
struct lives in IWRAM, so the final channel-state confirmation is unreadable. Full writeup:
`~/code/cliemu/internal-gbalua/ROMDEV_MEMORY_REGION_DEFECT.md` (for the MCP dev).

**Net:** the SDK code + maxmod are provably correct; the silence is either an mgba FIFO/
timing artifact (real HW would play — all state is identical + correct) or a module-channel-
enable detail that's unconfirmable until IWRAM reads work. NOT a code bug I can see. Shipped
state unchanged (mmInitDefault + richer soundbank; music plays in print-having games; sfx
everywhere; examples music-off + stable). 83/83 tests; tree clean.

## Session 16 (2026-07-15): romdev fixed the IWRAM tool → root cause TRACED

The MCP dev CONFIRMED + FIXED the memory defect (romdevtools@0.91.0): `system_ram` was
mgba-libretro returning the Game Boy 32 KB size on GBA, so it read the first 32 KB of EWRAM;
IWRAM was unreachable. Fix: `system_ram` now = honest 256 KB EWRAM + a NEW **`gba_iwram`**
region (32 KB @ 0x03000000). (Reply: internal-gbalua/ROMDEV_MEMORY_REGION_DEFECT_REPLY.md.)

With IWRAM readable I traced the maxmod silence to the exact byte (full writeup:
internal-gbalua/MAXMOD_SILENCE_ROOTCAUSE.md). In the SILENT build:
- maxmod init OK (`mp_solution`=0x0800F9F0), module PLAYING (`mmLayerMain[6]`=1), and the
  SEQUENCER ADVANCES (mmLayerMain position bytes tick over frames).
- `mmFrame`/`mmMixerMix` run and WRITE the double-buffered wave buffer (0x03001F70/2078,
  mm_mixlen=264) — but every sample written is **0x00** (watch on:range: PC 0x03000C54,
  528 writes, sampleValue 0x00).
- ROOT CAUSE: **the mixer channels are never enabled.** `mm_mixchannels`→0x030027D0, 16×16B;
  every CHN_SRC = **0x80000000** (bit31=disabled) and there are **0 writes** to that array
  over 10 frames. maxmod inits channels disabled; `mppProcessTick` should clear bit31 + set
  the sample source on a note trigger — that write never happens → mixer sums to silence.
- So: pattern sequencer runs + advances, but NOTES NEVER TRIGGER A MIXER CHANNEL. Everything
  else (soundbank, HW regs, DMA, mmVBlank) is byte-identical to the playing build.

Still open: only `print()` (a real tte_write glyph render) flips it audible; nothing print
does touches maxmod memory/regs, and the audio is timing-fragile (same ROM plays/silent by
step-interleave). => an mgba note-trigger timing/phase artifact OR a maxmod trigger detail
the TTE path incidentally satisfies. NOT gba_lua_sdk C (provably correct). Needs a 2nd GBA
core to test the emulator-artifact theory, or maxmod-internal RE of the note-trigger path.
Shipped state unchanged + solid.

## Session 18 (2026-07-15): MUSIC SILENCE *** SOLVED *** — it was a romdev bug

The romdev owner cracked it from the persisted baseline `.gba` I gave them: **romdev's
`binaryFile()` was decoding the soundbank base64 as UTF-8**, so the ROM embedded the
base64 TEXT of the soundbank instead of the bytes → maxmod read garbage where the MAS bank
should be → mmReadPattern misread → the phantom-channel-9 `MCH_UPDATE=0x200` tell I traced
→ no note ever triggered → deterministic silence, layout/execution-independent. EVERY symptom.
Fixed in **romdevtools@0.91.1** (`binaryFile` honors bytes-or-base64 like the per-toolchain
guards did; regression test asserts a bank's base64 can never appear in a ROM). The whole
"only print() makes it play" was a CONFOUND — my playing vs silent builds differed in how the
bank reached the build, never in whether TTE ran. LESSON (from the dev, earned): when two
parties disagree about "the same build," exchange the BYTES, not the descriptions — persisting
the .gba is what broke it open. (Chain: MEMORY defect report → gba_iwram → live struct trace →
phantom-channel tell → refusing the "known-good" bisect → persisted ROM → base64 signature.)

**VERIFIED on 0.91.1:** bareminimum (no print/cls, just music(0)) = RMS 7018 (PLAYS).
STARFALL (tile game, music+sfx) = RMS 6915, FFT confirms the real 4-channel Am–F–C–G tune;
940 frames stable. The richer background music the user asked for WORKS, tile games included.
STARFALL now ships with music ON.

**NEW, NARROWER bug this uncovered** (was masked by the corrupt bank): **Mode-4 (bitmap) +
maxmod crashes** at ~700-1000 frames. Minimal repro: `_init: music(0)` + `_draw: cls(1)` and
NOTHING else. Tell: crash register file is all `0x01010101` = `quad8(1)` from cls's m4_fill,
`spsr=0x92` (IRQ) → mmVBlank corrupts the IRQ return → execution branches INTO the Mode-4
bitmap VRAM (filled with 0x01) and runs it as code. TILE mode (Mode 0) + music is UNAFFECTED
(STARFALL). Likely my Mode-4 gba_init/gba_vsync single-buffer × mmVBlank glue, not romdev.
Flagged to the dev (MAXMOD_SILENCE_SOLVED_REPLY.md). DEFERRED — narrow (bitmap-only); tile is
the default path. Bitmap examples (effects/hello) stay music-off until it's closed.
83/83 tests; all 6 examples build.

## Next moves (post-Spike-3)

1. **Real asset pipeline** — the ONE weakest spot: sprites are still ONE hand-
   authored 16×16 alien (`alien_sprite.h`). Wire romdev's `convertImageToTiles`/
   `encodeArt` (4bpp, grit bundled) so a game supplies a `--sheet foo.png` and
   `spr(n)` indexes real tiles. This is what turns demos into games.
2. **`mode7`** — the SECOND headliner (bg_rotscale_ex + an HBlank handler). Big
   visual payoff; verify against a Tonc mode7 reference.
3. **Mutable sprite handles** (`s.angle=t()`) — Phase 2 of affine; the fun
   ergonomic form. Needs a new AST/check.js handle kind + emit OAM-slot binding.
   monteslu's call whether to do this vs keep flat `sprr()`.
4. **`map`/hardware BG layers + scroll** — tilemap games + parallax (needs a real
   tiled BG mode alongside the Mode-4 bitmap, or a mode switch).
5. **maxmod music/sfx** (`music`/`sfx`) — romdev bundles maxmod; wire the verbs.
6. **`run` in a window** — `gtlua run --target gba` via a node-sdl mGBA host (the
   gt-lua `bin/gtlua-run.mjs` pattern), so you can play without romdev.
7. **Parity pass** — build the Tonc demos via romdev + `frame({op:'sideBySide'})`
   each verb against them (the PLAN's Bucket-1 method).
8. **Genre example games** — a shmup / platformer once sheets + map land.

## Still-open design decisions (monteslu's call — see PLAN.md)

1. Sprite-handle syntax: mutable handles (`s.angle = t()`) vs. flat calls
   (`spr_rot(1,x,y,angle,scale)`). Rec: handles.
2. First-release scope: MVP (core + affine sprites + one Mode-7 demo) vs. wider.
