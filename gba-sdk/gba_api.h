// gba_api.h — the gba-lua runtime surface (thin libtonc wrappers).
//
// The C the compiler emits calls into these. Every gba-lua builtin resolves to
// a gba_* symbol here (the emitter remaps the shared builtins table's gt_* names
// to gba_*). This first slice covers the frame harness + cls + spr; the affine
// sprite-handle API and the rest of the verb set land on top of this.
//
// Design: sprites are HARDWARE OAM entries. Each frame the game issues spr()
// calls that fill an OAM shadow buffer; gba_endframe() flushes it to real OAM at
// vblank. This is the foundation the s.angle/s.scale affine handles build on.

#ifndef GBA_API_H
#define GBA_API_H

#include "gba_config.h"   // generated per build: feature flags (GBA_HAVE_SOUND, ...)
#include <tonc.h>
#include "gba_math.h"   // fixed-point math builtins (sin/cos/sqrt/atan2/rnd/t)

// ---- frame harness ---------------------------------------------------------
void gba_run(void);       // run()/reset(): restart the game from power-on
void gba_init(void);      // vblank IRQ + video bring-up + tile/palette setup
void gba_vsync(void);     // VBlankIntrWait + latch input for this frame
void gba_endframe(void);  // flush the OAM shadow to hardware, reset for next frame

// ---- immediate drawing (Mode-4 bitmap) -------------------------------------
// Colors are PICO-8 indices 0..15. A color arg of -1 means "use current color".
void gba_cls(int color);                                   // clear bitmap + reset sprite frame
void gba_color(int c);                                     // set the default draw color
void gba_pset(int x, int y, int color);
void gba_rect(int x0, int y0, int x1, int y1, int color);      // outline
void gba_rectfill(int x0, int y0, int x1, int y1, int color);  // filled
void gba_circ(int cx, int cy, int r, int color);              // outline
void gba_circfill(int cx, int cy, int r, int color);          // filled
void gba_line(int x0, int y0, int x1, int y1, int color);

// ---- backgrounds: hardware TILE layers (Mode 0) — the real game path -------
// The GBA has 4 hardware BG layers. A layer shows a tilemap (built from an
// 8x8-tile tileset) and scrolls for FREE via hardware — this is how real
// scrolling GBA games work (vs the slow Mode-4 bitmap). Tilemaps can be bigger
// than the screen (up to 512x512 px) and the camera scrolls a window over them.
//
// gba_tileset(layer, tiles, ntiles, pal): load a layer's tileset + palette.
// gba_tilemap(layer, map, cols, rows): set the layer's tilemap (col-major tile
//   indices, u16 each: low 10 bits = tile id, bits 10/11 = flip, 12-15 palbank).
// gba_layer_show(layer, on): enable/disable a BG layer.
// gba_layer_priority(layer, prio): 0 = front .. 3 = back (vs sprites too).
// gba_camera(x, y): scroll ALL layers by the camera (parallax via scroll_factor).
// gba_layer_scroll(layer, x, y): set one layer's scroll directly (parallax/HUD).
void gba_tileset(int layer, const unsigned int *tiles, int ntiles, const unsigned short *pal);
void gba_tilemap(int layer, const unsigned short *map, int cols, int rows);
void gba_layer_show(int layer, int on);
void gba_layer_priority(int layer, int prio);
void gba_camera(int x, int y);
void gba_layer_scroll(int layer, int x, int y);
// mget/mset: read/modify a tile in a layer's map at (col,row).
int  gba_mget(int layer, int col, int row);
void gba_mset(int layer, int col, int row, int tile);
void gba_layer_parallax(int layer, long factor);   // 16.16 follow-factor
void gba_map_show(int layer);                       // show the --map tilemap on a layer
void gba_bg_reset(void);   // internal: reset BG state (called by gba_init)

// ---- text: works in bitmap (Mode 4) AND tile (Mode 0) modes ----------------
#define TEXT_PALBANK 15               // BG palbank the tiled text layer uses
void gba_text_init_tiled(void);       // lazily set up tiled text on BG3 (tile mode)
int  gba_text_tiled_active(void);
void gba_text_clear(void);            // erase the tiled text layer (per-frame refresh)

// ---- text (Tonc Text Engine over the Mode-4 bitmap) ------------------------
// print(str/val, x, y, color). Positioned and cursor forms; str/int/num typed.
void gba_print(const char *s, int x, int y, int color);
void gba_print_int(int v, int x, int y, int color);
void gba_print_num(long v, int x, int y, int color);   // 16.16 fixed
void gba_print_cur_str(const char *s, int color);
void gba_print_cur_int(int v, int color);
void gba_print_cur_num(long v, int color);

// ---- sprites (hardware OBJ) ------------------------------------------------
// spr(n, x, y, w, h, flip): draw hardware sprite tile `n` at (x,y). w/h are in
// 8px cells (1 = 8x8, 2 = 16x16); flip packs bit0=X, bit1=Y. Allocates the next
// OAM slot for this frame; the PPU composites it over the bitmap.
void gba_spr(int n, int x, int y, int w, int h, int flip);
void gba_spr8(int t, int x, int y, int flip);   // 8x8 sprite from raw tile index
void gba_spr_pal(int bank);   // palbank for subsequent spr() this frame (0..15)
void gba_spr_prio(int p);     // priority vs BG layers (0 front .. 3 back)
void gba_spr_blend(void);     // next spr(): translucent alpha-blend target
void gba_spr_blend_off(void); // next spr(): back to normal (opaque)
void gba_spr_window(void);    // next spr(): a shaped OBJ-window mask (pair with window_obj)
void gba_spr_mosaic(int on);  // next spr(): apply the mosaic() grid

// sprr(n, x, y, angle, scale): a ROTATED + SCALED hardware sprite (the GBA
// affine feature the SDK leans into). angle is PICO-8 turns in 16.16 fixed
// (0..1.0 == one full turn); scale is a 16.16 fixed multiplier (1.0 = normal).
// Allocates an OBJ affine matrix (32 available). 16x16 sprite; centered at (x,y).
void gba_sprr(int n, int x, int y, long angle, long scale);
// sprr2: rotated + NON-uniform scale (independent sx,sy 16.16) — squash/stretch.
void gba_sprr2(int n, int x, int y, long angle, long sx, long sy);

// ---- animation helpers (frame-range cycling, timed off the frame clock) ----
// Turn a first..last frame range + an fps (16.16) into "which frame now". `slot`
// is a small per-actor id (0..31). Feed the result to spr()/spr8()/sprf().
int  gba_anim(int slot, int first, int last, long fps);          // looping cycle
int  gba_anim_once(int slot, int first, int last, long fps);     // play once, hold last
int  gba_anim_pingpong(int slot, int first, int last, long fps); // bounce back and forth
void gba_anim_reset(int slot);                                   // restart a slot
int  gba_anim_done(int slot);                                    // once-anim finished?

// ---- windows: hardware rectangular clipping regions (FREE in the PPU) ------
// A window is a screen rect where you pick which layers are visible. Two rect
// windows. `layers` is a bitmask: bit0=BG0 bit1=BG1 bit2=BG2 bit3=text(BG3)
// bit4=sprites (the Lua constant ALL = 31 covers all of them).
void gba_window(int x0, int y0, int x1, int y1);                       // spotlight: show inside, hide outside
void gba_window_inside(int x0, int y0, int x1, int y1, int layers);    // pick layers shown inside the box
void gba_window_outside(int layers);                                   // pick layers shown outside the box(es)
void gba_window_obj(int layers);                                       // OBJ window: spr_window() sprites mask `layers`
void gba_window_off(void);                                             // disable windowing

// ---- Mode 7: affine background (rotate/scale/scroll a plane in hardware) ----
// The GBA's signature effect. BG2 becomes a flat plane you fly a camera over —
// F-Zero ground, spinning maps, zooming menus. Data comes from --mode7 plane.png
// (8bpp, square, 128/256/512/1024 px). angle = PICO-8 turns (16.16); zoom = 16.16
// scale; x/y = the world point the screen centers on.
void gba_mode7(void);                                    // show the bundled affine plane
void gba_mode7_cam(long x, long y, long angle, long zoom); // per-frame camera over the plane
void gba_mode7_off(void);                                // hide the affine layer

// ---- color effects (hardware blend unit — FREE, no per-pixel CPU) ----------
// The GBA composites layers with an alpha/fade unit in the PPU. gba-lua exposes
// it as two friendly verbs. `layer` ids: 0..2 tile BGs, 3 text/HUD, 4 sprites.
// Amounts are PICO-8-style 0.0..1.0 in 16.16 fixed (like sin/parallax factors).
void gba_blend(int layer, long alpha);  // blend(layer,a): draw layer at `a` opacity over the scene
void gba_fade(long amount, int white);  // fade(amount,[white]): darken (or whiten) the whole screen
void gba_blend_off(void);               // blend_off(): clear all color effects
void gba_mosaic(int n);                 // mosaic(n): square hardware pixelate (0=off..15)
void gba_mosaic2(int bh, int bv);       // mosaic2(bh,bv): independent x/y pixelate
int  gba_mosaic_active(void);           // internal: is mosaic on (spr code applies the OBJ bit)
void gba_backdrop(int color);           // backdrop(color): the void behind all layers (BG palette 0)
void gba_screen_off(void);              // screen_off(): force-blank (hide a VRAM rebuild, instant cut)
void gba_screen_on(void);               // screen_on(): un-blank
void gba_pal(int idx, int r, int g, int b);      // pal(i,r,g,b): set a BG palette color at runtime
void gba_spr_col(int idx, int r, int g, int b);  // spr_col(i,r,g,b): set an OBJ palette color
void gba_hgradient(const int *table);            // hgradient(table): per-scanline backdrop gradient (160 colors)

// ---- hardware odds & ends (gba_hw.c) ---------------------------------------
void gba_save(int slot, const unsigned char *arr, int n); // save(slot, array8, n): persist to SRAM
int  gba_load(int slot, unsigned char *arr, int n);       // load(slot, array8, n): restore (returns bytes, 0=none)
void gba_timer_start(void);                               // timer_start(): reset+run a free timer
int  gba_timer_read(void);                                // timer_read(): sample it (sub-frame / profiling)

// ---- sound (maxmod: module music + sample SFX) -----------------------------
void gba_sound_init(void);    // internal: init maxmod (called by gba_init)
void gba_sound_frame(void);   // internal: mmFrame() (called by gba_endframe)
void gba_music(int n, int loop);   // music(n,[loop]): start module n; music(-1) stops
void gba_music_stop(void);
void gba_music_volume(int vol);    // 0..1024
void gba_sfx(int n, int ch);       // sfx(n,[ch]): play sample effect n (ch ignored)
void gba_sfx_ex(int n, int vol, int pan, long pitch); // sfx_ex(n,vol,pan,pitch): per-shot vol/pan/pitch
void gba_sfx_volume(int vol);      // sfx_volume(0..1024): master sfx volume

// ---- input -----------------------------------------------------------------
// btn(i, [player]): is button i held? 0-3 d-pad (U/D/L/R), 4=A, 5=B, 6=L, 7=R,
// (start/select later). player is ignored (GBA is 1-pad) but kept for API parity.
int gba_btn(int i, int player);
int gba_btnp(int i, int player);

#endif
