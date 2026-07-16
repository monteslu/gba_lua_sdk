// gba_api.c — gba-lua runtime. Thin libtonc wrappers; the GBA hardware does the
// work, so this is glue, not an engine (no asm, no software rasterizers beyond
// the small circle loop libtonc happens not to ship).
//
// RENDERING MODEL (the core design decision):
//   * SHAPE / immediate drawing (cls/rect/rectfill/circ/line/pset/print) →
//     a Mode-4 8bpp paletted BITMAP background (BG2, 240x160). This is what
//     PICO-8-style immediate drawing wants: a framebuffer you paint each frame.
//     Double-buffered via vid_flip() so we never draw a torn frame.
//   * SPRITES (spr, and later the affine handles) → real HARDWARE OBJ sprites,
//     composited by the PPU ON TOP of the bitmap. spr() fills an OAM shadow;
//     gba_endframe() flushes it.
// Both coexist: DCNT = MODE4 | BG2 | OBJ | OBJ_1D.
//
// Colors are PICO-8 indices 0..15 into a fixed 16-entry BG palette (so cls(1)
// is dark blue, etc.), mirrored into the OBJ palette so sprites share it.

#include "gba_api.h"
#ifdef GBA_HAVE_SOUND
#include <maxmod.h>   // for mmVBlank (installed as the vblank IRQ handler)
#endif
// gba_assets.h is GENERATED per build: it #includes either the converted sheet
// (sheet_tiles/sheet_pal) or the built-in alien fallback, and defines
// GBA_SHEET_TILES / GBA_SHEET_PAL / GBA_SHEET_HAS_PAL. The build always provides
// it, so both this TU and main.c see the same asset without a cross-TU -D flag.
#include "gba_assets.h"
#include "gba_font.h"    // gba_font_tiles[] + gba_font_map[96] (8x8 HUD glyphs)

// ---- the PICO-8 16-color palette (RGB) -------------------------------------
static const u8 P8_RGB[16][3] = {
    {0,0,0},{29,43,83},{126,37,83},{0,135,81},{171,82,54},{95,87,79},
    {194,195,199},{255,241,232},{255,0,77},{255,163,0},{255,236,39},{0,228,54},
    {41,173,255},{131,118,156},{255,119,168},{255,204,170}
};
// same palette pre-baked to BGR555 LITERALS (RGB15() isn't a constant-expression,
// so a static initializer needs the raw values), exported so gba_fx.c (backdrop)
// can map a PICO-8 color index to a hardware color without duplicating the table.
const unsigned short GBA_P8_PAL15[16] = {
    0x0000, 0x28A3, 0x288F, 0x2A00,
    0x1955, 0x254B, 0x6318, 0x77DF,
    0x241F, 0x029F, 0x13BF, 0x1B80,
    0x7EA5, 0x4DD0, 0x55DF, 0x573F,
};

// ---- OAM shadow ------------------------------------------------------------
static OBJ_ATTR obj_buffer[128];
static int sprites_used;
// The 32 OBJ affine matrices alias obj_buffer (pa/pb/pc/pd live in the filler
// fields of every 4th OBJ_ATTR). affine_used = matrices claimed this frame.
static OBJ_AFFINE *const obj_aff_buffer = (OBJ_AFFINE *)obj_buffer;
static int affine_used;

// ---- input latch -----------------------------------------------------------
static u16 key_curr, key_prev;
// gba-lua btn index -> KEY_ mask. PICO-8 order for 0-5 (LEFT/RIGHT/UP/DOWN/A/B),
// then the GBA's extra buttons: 6=L 7=R shoulders, 8=START 9=SELECT. All ten
// physical GBA buttons are reachable (a menu needs both shoulders + select).
#define BTN_COUNT 10
static const u16 BTN_MASK[BTN_COUNT] = {
    KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_A, KEY_B,
    KEY_L, KEY_R, KEY_START, KEY_SELECT
};

// current draw color (set by color(); used when a draw call omits its color)
static int cur_color = 7;
// Mode-4 double-buffer: endframe requests a flip, gba_vsync does it in vblank.
static int pending_flip;
// per-sprite draw modifiers (palbank + priority + mode + mosaic), reset each
// frame in endframe. spr_mode: 0=normal 1=alpha-blend (translucent) 2=obj-window.
static int spr_palbank;
static int spr_prio;
static int spr_mode;      // ATTR0_MODE for the next spr(): 0 normal, 1 blend, 2 window
static int spr_mosaic;    // 1 => apply ATTR0_MOSAIC to the next spr()

// ---- palette setup ---------------------------------------------------------
static void load_palettes(void)
{
    // BG palette bank 0 = the PICO-8 16 colors (so cls(1) etc. + bitmap draws are
    // the real PICO-8 colors). Also mirror into OBJ palbank 0 as a default.
    for (int i = 0; i < 16; i++) {
        COLOR c = RGB15(P8_RGB[i][0] >> 3, P8_RGB[i][1] >> 3, P8_RGB[i][2] >> 3);
        pal_bg_mem[i]  = c;
        pal_obj_mem[i] = c;
    }
#if GBA_SHEET_HAS_PAL
    // a converted sheet brings its own 16-color OBJ palette (palbank 0).
    memcpy32(pal_obj_mem, GBA_SHEET_PAL, 16 / 2);
#endif
}

// ---- sprite tiles ----------------------------------------------------------
// Temp hand-authored 16x16 4bpp alien (alien_sprite.h). The PNG->tile importer
// replaces this but keeps the same 4bpp format. A 16x16 4bpp sprite = 4 tiles.
//
// MODE-4 SPRITE GOTCHA: in bitmap modes (3-5) the first 512 OBJ tiles overlap
// the bitmap's page memory, so sprite tiles MUST start at index 512+. We load
// the alien at tile 512 (charblock 4 is 4bpp TILE[512]; tile 512 = block 5's
// tile 0). gba_spr() adds this base to n. tile4_mem[5] is that region.
#define OBJ_TILE_BASE 512
// HUD font: 40 8x8 glyphs loaded at OBJ tile 900 (well past the sprite sheet's
// 512..~899 range), in palbank 15 where color 1 = white. HUD text is drawn as
// 8x8 OBJ sprites indexing these — NO TTE, so it's stable with maxmod (the
// TTE-write path crashed under sound; heavy sprites + sound is proven stable).
#define HUD_FONT_TILE 900
#define HUD_PALBANK   15
static void load_sprite_tiles(void)
{
    // block 5 (tile_mem[5]) == OBJ tiles 512.. — safe in bitmap modes.
    memcpy32(&tile_mem[5][0], GBA_SHEET_TILES, GBA_SHEET_TILES_WORDS);
    // font tiles at OBJ tile 900 (tile_mem[4] is OBJ CBB; tile 900 = &[4][900]).
    memcpy32(&tile_mem[4][HUD_FONT_TILE], gba_font_tiles, GBA_FONT_NTILES * 8);
    // palbank 15 color 1 = white (the font ink).
    pal_obj_mem[HUD_PALBANK * 16 + 1] = RGB15(31, 31, 31);
}

// ---- harness ---------------------------------------------------------------
void gba_init(void)
{
    irq_init(NULL);
#ifdef GBA_HAVE_SOUND
    // maxmod requires mmVBlank() in the VBlank IRQ slot (it's the audio clock).
    // Install it AS the vblank handler (not NULL) — it also acks the IRQ so
    // VBlankIntrWait still works. mmInitDefault runs next (in gba_sound_init).
    irq_add(II_VBLANK, mmVBlank);
    gba_sound_init();
#else
    irq_add(II_VBLANK, NULL);
#endif

    load_palettes();
    load_sprite_tiles();
    oam_init(obj_buffer, 128);

    // Tonc Text Engine over the Mode-4 bitmap (draws into the same m4_surface as
    // the shape primitives). Ink color is set per print() call.
    tte_init_bmp(4, NULL, NULL);

    // Mode 4 bitmap (BG2) + hardware objects (1D mapping). Forced-blank cleared.
    // Page 0 (front, DCNT_PAGE clear) is the single buffer.
    REG_DISPCNT = DCNT_MODE4 | DCNT_BG2 | DCNT_OBJ | DCNT_OBJ_1D;

    // SINGLE-BUFFERED on the FRONT page (vid_mem). libtonc inits vid_page to the
    // BACK page, so point it (and TTE's surface) at the front page = the visible
    // one. All m4_* shapes + TTE text draw straight to what's displayed. (No
    // vid_flip: it raced maxmod's mmVBlank and blanked the screen with sound on.)
    vid_page = vid_mem;
    tte_get_context()->dst.data = (u8 *)vid_mem;

    gba_bg_reset();
    // (gba_sound_init() already ran above, right after installing mmVBlank.)
    sprites_used = 0;
    affine_used = 0;
    pending_flip = 0;
    key_curr = key_prev = 0;
    cur_color = 7;
    gba_blend_off();   // no stale color effect at power-on / after run()
    gba_window_off();  // no stale window clip at power-on / after run()
}

void gba_vsync(void)
{
    VBlankIntrWait();
#ifdef GBA_HAVE_SOUND
    // maxmod's mixer step MUST run once per frame from MAIN context, right after
    // vblank — so it finishes well before the NEXT vblank IRQ (mmVBlank) fires.
    // Running it at endframe (after the game's heavy _update/_draw) let a busy
    // frame push mmFrame so late that the next vblank IRQ raced it -> a wild
    // branch / crash under load. Right-after-vblank matches maxmod's demo.
    gba_sound_frame();
#endif
    key_prev = key_curr;
    key_curr = ~REG_KEYINPUT & KEY_MASK;
    // Mode-4 bitmap is SINGLE-BUFFERED (draw straight to the visible front page).
    // Double-buffering (vid_flip) raced maxmod's mmVBlank handler and blanked the
    // screen when sound was on; single-buffer sidesteps it entirely. For the
    // PICO-8-style immediate mode (cls + redraw right after vblank) this is fine —
    // the visible tearing window is small and only on the bitmap path (tile games
    // don't touch this). vid_page + TTE both target the front page (set in init).
    (void)pending_flip;
    // tile-mode HUD: blank the text layer before this frame's print()s so a
    // changing value (score) doesn't leave stale glyphs. Safe now — clears the
    // text glyph charblock (CBB2), which no longer overlaps the map screenblocks.
    // DISABLED for crash bisection.
    // if (gba_text_tiled_active()) gba_text_clear();
}

void gba_endframe(void)
{
    // hide unused OAM slots, push the shadow to hardware OAM.
    for (int i = sprites_used; i < 128; i++) obj_hide(&obj_buffer[i]);
    oam_copy(oam_mem, obj_buffer, 128);
    sprites_used = 0;
    affine_used = 0;
    spr_palbank = 0;
    spr_prio = 0;
    spr_mode = 0;
    spr_mosaic = 0;
    // (mmFrame runs in gba_vsync right after vblank, not here — see the note there.)
    gba_time_tick();   // advance t()/time()
}

// resolve a possibly-omitted color arg (-1 sentinel) to the current draw color.
static inline u8 resolve_color(int c)
{
    if (c < 0) c = cur_color;
    return (u8)(c & 15);
}

// ---- immediate drawing (Mode-4 bitmap) -------------------------------------
void gba_cls(int color)
{
    // PICO-8 cls: clear the bitmap to `color` (default 0) AND reset the sprite
    // frame (next spr() starts at slot 0). Draws to the CURRENT back buffer.
    u8 c = (color < 0) ? 0 : (u8)(color & 15);
    m4_fill(c);
    sprites_used = 0;
    affine_used = 0;
}

void gba_color(int c) { cur_color = c & 15; }

void gba_pset(int x, int y, int color) { m4_plot(x, y, resolve_color(color)); }

void gba_rect(int x0, int y0, int x1, int y1, int color)
{
    m4_frame(x0, y0, x1, y1, resolve_color(color));   // outline (inclusive rect)
}

void gba_rectfill(int x0, int y0, int x1, int y1, int color)
{
    m4_rect(x0, y0, x1 + 1, y1 + 1, resolve_color(color));  // filled (m4_rect is exclusive-right/bottom)
}

void gba_line(int x0, int y0, int x1, int y1, int color)
{
    m4_line(x0, y0, x1, y1, resolve_color(color));
}

// libtonc's m4_plot/m4_hline do NOT clip — an off-screen x/y corrupts adjacent
// rows (wraps across the 240-wide framebuffer). So we clip to [0,240)x[0,160).
#define SCRW 240
#define SCRH 160
static inline void plot_clip(int x, int y, u8 c)
{
    if ((unsigned)x < SCRW && (unsigned)y < SCRH) m4_plot(x, y, c);
}
static inline void hline_clip(int x1, int x2, int y, u8 c)
{
    if ((unsigned)y >= SCRH) return;
    if (x1 > x2) { int t = x1; x1 = x2; x2 = t; }
    if (x2 < 0 || x1 >= SCRW) return;
    if (x1 < 0) x1 = 0;
    if (x2 >= SCRW) x2 = SCRW - 1;
    m4_hline(x1, y, x2, c);
}

// circle: midpoint algorithm over CLIPPED m4 primitives.
void gba_circ(int cx, int cy, int r, int color)
{
    u8 c = resolve_color(color);
    int x = r, y = 0, err = 1 - r;
    while (x >= y) {
        plot_clip(cx + x, cy + y, c); plot_clip(cx - x, cy + y, c);
        plot_clip(cx + x, cy - y, c); plot_clip(cx - x, cy - y, c);
        plot_clip(cx + y, cy + x, c); plot_clip(cx - y, cy + x, c);
        plot_clip(cx + y, cy - x, c); plot_clip(cx - y, cy - x, c);
        y++;
        if (err < 0) err += 2 * y + 1;
        else { x--; err += 2 * (y - x) + 1; }
    }
}

void gba_circfill(int cx, int cy, int r, int color)
{
    u8 c = resolve_color(color);
    int x = r, y = 0, err = 1 - r;
    while (x >= y) {
        hline_clip(cx - x, cx + x, cy + y, c);
        hline_clip(cx - x, cx + x, cy - y, c);
        hline_clip(cx - y, cx + y, cy + x, c);
        hline_clip(cx - y, cx + y, cy - x, c);
        y++;
        if (err < 0) err += 2 * y + 1;
        else { x--; err += 2 * (y - x) + 1; }
    }
}

// ---- text (TTE over the Mode-4 bitmap) -------------------------------------
// TTE ink is a palette index. We reserve BG palette slot 0xF1 as the "current
// text ink" and repoint it to the requested PICO-8 color each print(), so text
// gets any of the 16 colors while TTE stays configured for one ink index.
#define TTE_INK_SLOT 0xF1

// Text works in BOTH modes:
//   Mode 4 (bitmap): glyphs drawn straight into the bitmap (the bmp TTE).
//   Mode 0 (tiles):  a tiled TTE on BG3 (lazily init'd) — writing glyph pixels
//     into the bitmap area would corrupt the tile VRAM, so tile games get a real
//     text layer instead.
static void tte_color(int color)
{
    int c = (color < 0) ? cur_color : (color & 15);
    COLOR col = RGB15(P8_RGB[c][0] >> 3, P8_RGB[c][1] >> 3, P8_RGB[c][2] >> 3);
    if ((REG_DISPCNT & 7) == 0) {         // tile mode: text on BG3
        if (!gba_text_tiled_active()) gba_text_init_tiled();
        pal_bg_mem[(TEXT_PALBANK << 4) + 1] = col;   // ink = color 1 of the text palbank
    } else {
        pal_bg_mem[TTE_INK_SLOT] = col;
    }
}

// PICO-8 fixed (16.16) -> a plain integer string is enough for the common case;
// print a whole number (drop the fraction) for now.
static int fx_to_int(long v) { return (int)(v >> 16); }

// Hand-rolled int->string (NO newlib printf). tte_printf pulls in vsnprintf,
// which uses a LOT of stack — and when maxmod's mmVBlank IRQ nested on top of a
// deep printf, the tiny IRQ stack collided with it → wild-branch crash under
// sound. A tiny itoa keeps the stack shallow and sidesteps it entirely.
static void itoa10(long v, char *buf)
{
    char tmp[12];
    int i = 0, neg = 0;
    unsigned long u;
    if (v < 0) { neg = 1; u = (unsigned long)(-v); } else u = (unsigned long)v;
    if (u == 0) tmp[i++] = '0';
    while (u) { tmp[i++] = '0' + (u % 10); u /= 10; }
    int j = 0;
    if (neg) buf[j++] = '-';
    while (i) buf[j++] = tmp[--i];
    buf[j] = 0;
}

// Render text with IRQs momentarily masked. TTE's glyph renderer is a deep call
// chain; when maxmod's mmVBlank IRQ nested on top of it EVERY frame (a tile game
// printing a HUD + sound), the stack/state raced → a wild-branch crash. Masking
// IRQs (REG_IME) around the render prevents the nesting. The FIFO DMA is hardware
// and keeps flowing; mmFrame runs at vblank (not here), so audio is unaffected.
static void write_guarded(const char *s)
{
    u16 ime = REG_IME;
    REG_IME = 0;
    tte_write(s);
    REG_IME = ime;
}

// sprite-HUD helpers (defined below, near the other OBJ code). In TILE mode
// print() routes here — 8x8 glyph sprites, stable under maxmod (unlike TTE).
static int hud_draw_str(const char *sp, int x, int y);
static int hud_draw_int(long v, int x, int y);

// is the display in a TILED mode (Mode 0/1/2)? Then there's no bitmap to draw
// text into, AND per-frame TTE races maxmod — so route print() to sprite glyphs.
static inline int in_tile_mode(void) { return (REG_DISPCNT & 7) <= 2; }

void gba_print(const char *s, int x, int y, int color)
{
    // TILE mode: draw as 8x8 OBJ glyphs (the sprite HUD) — crisp, needs no BG3
    // charblock, and composes with Mode 7 / tile layers. (The old TTE+maxmod tile
    // crash that forced this is now fixed at the source — maxmod uses static
    // buffers, see gba_sound.c — so tiled TTE is safe too, but the sprite HUD
    // stays the default: one fewer BG layer used and no per-frame VRAM writes.)
    (void)color;   // sprite font is single-ink white in tile mode
    if (in_tile_mode()) { hud_draw_str(s, x, y); return; }
    tte_color(color);
    tte_set_pos(x, y);
    write_guarded(s);
}
void gba_print_int(int v, int x, int y, int color)
{
    if (in_tile_mode()) { hud_draw_int(v, x, y); return; }
    char buf[12]; itoa10(v, buf);
    tte_color(color);
    tte_set_pos(x, y);
    write_guarded(buf);
}
void gba_print_num(long v, int x, int y, int color) { gba_print_int(fx_to_int(v), x, y, color); }

void gba_print_cur_str(const char *s, int color) { tte_color(color); write_guarded(s); }
void gba_print_cur_int(int v, int color) { char buf[12]; itoa10(v, buf); tte_color(color); write_guarded(buf); }
void gba_print_cur_num(long v, int color) { gba_print_cur_int(fx_to_int(v), color); }

// ---- sprites (hardware OBJ) -------------------------------------------------
// per-sprite draw attributes set before the next spr() (PICO-8-style stateful
// modifiers, reset each frame): palette bank + priority vs BG layers.
// (spr_palbank / spr_prio declared file-scope up top.)
// combine the per-sprite ATTR0 mode + mosaic modifiers into the flag bits spr()
// ORs into its shape. mode 1=blend, 2=window; mosaic adds ATTR0_MOSAIC.
static inline u16 spr_a0_flags(void)
{
    u16 f = 0;
    if (spr_mode == 1) f |= ATTR0_BLEND;    // ATTR0_MODE(1) — alpha target
    else if (spr_mode == 2) f |= ATTR0_WINDOW; // ATTR0_MODE(2) — obj-window mask
    if (spr_mosaic) f |= ATTR0_MOSAIC;
    return f;
}

void gba_spr_pal(int bank) { spr_palbank = bank & 15; }
void gba_spr_prio(int p)   { spr_prio = p & 3; }
// spr_blend(): the NEXT spr() is a translucent alpha-blend target (uses the blend
// weights from blend()/REG_BLDALPHA) — ghosts, shields, shadows. spr_blend_off()
// restores normal. Both reset each frame like spr_pal.
void gba_spr_blend(void)     { spr_mode = 1; }
void gba_spr_blend_off(void) { spr_mode = 0; }
// spr_window(): the NEXT spr() becomes a SHAPED window mask (OBJ window) instead
// of drawing — a sprite-shaped spotlight/reveal. Pair with window_obj().
void gba_spr_window(void)    { spr_mode = 2; }
// spr_mosaic(on): apply the mosaic grid (from mosaic()) to the next spr().
void gba_spr_mosaic(int on)  { spr_mosaic = on ? 1 : 0; }

// The sheet is a grid of 16x16 cells; cell n = 4 consecutive tiles (the
// converter lays them out NW,NE,SW,SE per cell). So a 16x16 sprite's tile base
// is 4*n; a full row of the sheet is `sheet_cols` cells apart. w/h in 8px cells
// pick the hardware size (1=8x8, 2=16x16, 4=32x32, 8=64x64). For sizes != 16x16
// the tile index is still 4*n (cell granularity) — good enough for game art laid
// out on a 16x16 grid; small 8x8 sprites use spr8().
void gba_spr(int n, int x, int y, int w, int h, int flip)
{
    if (sprites_used >= 128) return;
    OBJ_ATTR *s = &obj_buffer[sprites_used++];

    u16 shape = ATTR0_SQUARE, a1size;
    // choose shape (square/wide/tall) + size from w,h (in 8px cells).
    if (w == h) {
        shape = ATTR0_SQUARE;
        a1size = w >= 8 ? ATTR1_SIZE_64 : w >= 4 ? ATTR1_SIZE_32 : w >= 2 ? ATTR1_SIZE_16 : ATTR1_SIZE_8;
    } else if (w > h) {
        shape = ATTR0_WIDE;
        a1size = w >= 8 ? ATTR1_SIZE_64 : w >= 4 ? ATTR1_SIZE_32 : ATTR1_SIZE_16;
    } else {
        shape = ATTR0_TALL;
        a1size = h >= 8 ? ATTR1_SIZE_64 : h >= 4 ? ATTR1_SIZE_32 : ATTR1_SIZE_16;
    }

    u16 a1flip = 0;
    if (flip & 1) a1flip |= ATTR1_HFLIP;
    if (flip & 2) a1flip |= ATTR1_VFLIP;

    obj_set_attr(s, shape | spr_a0_flags(), a1size | a1flip,
                 ATTR2_ID(OBJ_TILE_BASE + 4 * n) | ATTR2_PALBANK(spr_palbank) | ATTR2_PRIO(spr_prio));
    obj_set_pos(s, x, y);
}

// spr8(t, x, y, [flip]): an 8x8 sprite from raw tile index t (0-based into the
// sheet's tiles). For small things — bullets, pickups, particles. The sheet's
// tiles are 4-per-16x16-cell, so tile t is cell (t/4), sub-tile (t%4).
void gba_spr8(int t, int x, int y, int flip)
{
    if (sprites_used >= 128) return;
    OBJ_ATTR *s = &obj_buffer[sprites_used++];
    u16 a1flip = 0;
    if (flip & 1) a1flip |= ATTR1_HFLIP;
    if (flip & 2) a1flip |= ATTR1_VFLIP;
    obj_set_attr(s, ATTR0_SQUARE | spr_a0_flags(), ATTR1_SIZE_8 | a1flip,
                 ATTR2_ID(OBJ_TILE_BASE + t) | ATTR2_PALBANK(spr_palbank) | ATTR2_PRIO(spr_prio));
    obj_set_pos(s, x, y);
}

// ---- sprite-based HUD (no TTE) ---------------------------------------------
// print() in TILE mode crashes when maxmod is playing (the TTE glyph-render path
// races the mmVBlank IRQ — a low-level TTE/maxmod conflict we never root-caused,
// only sidestepped). Heavy OBJ
// sprites + maxmod is PROVEN stable, so in tile mode we draw HUD text as 8x8 OBJ
// sprites from the baked font (gba_font.h, tiles at HUD_FONT_TILE, palbank 15).
// One OAM entry per glyph, flushed with the game's sprites at vblank. No VRAM
// writes per frame → nothing for the IRQ to race.
//
// draw a single font glyph as an 8x8 sprite at (x,y). `g` is a font tile index.
static void hud_glyph(int g, int x, int y)
{
    if (sprites_used >= 128) return;
    OBJ_ATTR *s = &obj_buffer[sprites_used++];
    obj_set_attr(s, ATTR0_SQUARE, ATTR1_SIZE_8,
                 ATTR2_ID(HUD_FONT_TILE + g) | ATTR2_PALBANK(HUD_PALBANK) | ATTR2_PRIO(0));
    obj_set_pos(s, x, y);
}

// draw a string as 8x8 glyph sprites, 8px per cell, left to right. Uppercases
// a-z, maps via gba_font_map; unknown chars render as a space (glyph 0). Returns
// the pen x after the string (so numbers can follow labels).
static int hud_draw_str(const char *sp, int x, int y)
{
    for (; *sp; sp++) {
        int c = (unsigned char)*sp;
        if (c >= 'a' && c <= 'z') c -= 32;      // fold to uppercase (font is caps only)
        int g = (c >= 32 && c < 128) ? gba_font_map[c - 32] : 0;
        hud_glyph(g, x, y);
        x += 8;
    }
    return x;
}

// draw a signed integer as glyph sprites (right-grows from x). Shares itoa10.
static int hud_draw_int(long v, int x, int y)
{
    char buf[12];
    itoa10(v, buf);
    return hud_draw_str(buf, x, y);
}

// sprr(n, x, y, angle, scale): rotated + scaled hardware sprite. THE affine
// feature. angle/scale arrive as PICO-8 16.16 fixed; convert to what
// obj_aff_rotscale wants (u16 angle where 0x10000==one turn wraps to 0..0xFFFF;
// 8.8 FIXED scale). A 16x16 affine sprite uses double-render size (32x32 box) so
// rotated corners don't clip; we center it on (x,y).
// core: rotated + INDEPENDENTLY-scaled 16x16 affine sprite. sx/sy are 16.16.
static void spr_affine(int n, int x, int y, long angle, long sx, long sy)
{
    if (sprites_used >= 128 || affine_used >= 32) return;
    OBJ_ATTR *s = &obj_buffer[sprites_used++];
    int aff_id = affine_used++;

    // 16.16 turns -> u16 angle: (angle & 0xFFFF) maps 0..1.0 turn onto 0..0xFFFF.
    u16 alpha = (u16)(angle >> 0) & 0xFFFF;
    // obj_aff_rotscale takes the ZOOM as 8.8 fixed (256 = 1.0). 16.16 >>8 -> 8.8.
    FIXED zx = (FIXED)(sx >> 8), zy = (FIXED)(sy >> 8);
    if (zx <= 0) zx = 1;
    if (zy <= 0) zy = 1;

    obj_aff_rotscale(&obj_aff_buffer[aff_id], zx, zy, alpha);

    obj_set_attr(s,
        ATTR0_SQUARE | ATTR0_AFF | ATTR0_AFF_DBL | spr_a0_flags(),  // affine + double box
        ATTR1_SIZE_16 | ATTR1_AFF_ID(aff_id),
        ATTR2_ID(OBJ_TILE_BASE + 4 * n) | ATTR2_PALBANK(spr_palbank) | ATTR2_PRIO(spr_prio));
    // double-size box is 32x32; position by its top-left so the 16x16 centers on (x,y).
    obj_set_pos(s, x - 8, y - 8);
}

// sprr(n, x, y, angle, scale): rotated + uniformly-scaled hardware sprite. THE
// affine feature. angle = PICO-8 turns (16.16, 0..1 = one turn); scale = 16.16.
void gba_sprr(int n, int x, int y, long angle, long scale)
{
    spr_affine(n, x, y, angle, scale, scale);
}

// sprr2(n, x, y, angle, sx, sy): rotated + NON-UNIFORMLY scaled — independent x/y
// scale gives squash-and-stretch, a spinning coin (sx→0 and back), stretched
// projectiles. sx/sy are 16.16 (1.0 = normal).
void gba_sprr2(int n, int x, int y, long angle, long sx, long sy)
{
    spr_affine(n, x, y, angle, sx, sy);
}

// ---- run()/reset(): restart the game from power-on -------------------------
// A true PICO-8 run() restarts everything. On GBA the BIOS soft reset jumps back
// to the cart entry, re-running crt0 + main() from scratch — top-level Lua
// initializers restored, _init() runs again. We clear graphics RAM first so the
// old frame doesn't linger, and stop audio (maxmod owns DMA/timers).
void gba_run(void)
{
#ifdef GBA_HAVE_SOUND
    gba_music_stop();
#endif
    RegisterRamReset(RESET_GFX | RESET_VRAM | RESET_OAM);
    SoftReset();
}

// ---- input -----------------------------------------------------------------
int gba_btn(int i, int player)
{
    (void)player;
    if (i < 0 || i >= BTN_COUNT) return 0;
    return (key_curr & BTN_MASK[i]) ? 1 : 0;
}

int gba_btnp(int i, int player)
{
    (void)player;
    if (i < 0 || i >= BTN_COUNT) return 0;
    u16 m = BTN_MASK[i];
    return ((key_curr & m) && !(key_prev & m)) ? 1 : 0;
}
