// gba_text.c — text that works in BOTH render modes.
//
// Bitmap mode (Mode 4): print() draws glyphs straight into the bitmap (TTE bmp).
// Tile mode (Mode 0): the bitmap doesn't exist, so we run TTE in tiled mode on a
// DEDICATED BG layer (BG3) with its own charblock + screenblock — separate from
// the game's tile layers, drawn on top. This avoids the corruption from writing
// bitmap pixels into tile VRAM.
//
// gba_text_init_tiled() is called the first time print() runs in tile mode.

#include "gba_api.h"

// BG3 = the text layer. Its own charblock (3) for glyph tiles + screenblock (31)
// for the text map. CBB 3 = 0x0600C000, SBB 31 = 0x0600FC00 — both above the
// game's tile charblock 0 and clear of OBJ VRAM (0x06010000).
// VRAM layout for text (the layout collision was the whole bug):
//   glyph tiles -> CHARBLOCK 2 (0x08000-0x0C000). NOT CBB3: CBB3 (0x0C000-0x10000)
//     OVERLAPS the map screenblocks SBB 28-31 (0x0E000-0x10000), so clearing it
//     wiped the game's tilemaps -> black screen. CBB2 is clear of CBB0 (game
//     tiles) AND the screenblocks.
//   text map -> SBB 31 (BG3's natural map slot). A game using text should not
//     also use BG layer 3 (layers 0-2 = 3 tile layers is plenty).
#define TEXT_BG    3
#define TEXT_CBB   2
#define TEXT_SBB   31
// TEXT_PALBANK is declared in gba_api.h (shared with gba_api.c's tte_color).

static int text_tiled_ready;

// initialize TTE for tiled text on BG3 (chr4c = 4bpp tiled surface).
// tte_init_chr4c(bgnr, bgcnt, se0, cattrs, clrs, font, proc):
//   bgcnt = the BG3 control value (our cbb/sbb/size/prio),
//   se0   = base screen entry — its palbank (bits 12-15) picks the text palbank,
//   cattrs = color-attr indices (ink in bits 0-3),
//   clrs  = ink color (low 16 bits) [+ shadow high]. We use ink index 1, white.
void gba_text_init_tiled(void)
{
    if (text_tiled_ready) return;
    text_tiled_ready = 1;
    // Use libtonc's canonical chr4c default init (font=vwf_default, ink=1 white,
    // shadow=orange, palbank 15 via se0=0xF000). This is the exact form the Tonc
    // text tutorial uses; our hand-rolled call rendered nothing.
    // EXACTLY the working pure-C sequence (verified: renders text even after
    // tte_init_bmp + Mode-0 setup). Just bgcnt = CBB|SBB; no size/prio/4bpp flags
    // in the macro's bgcnt (the default handles those).
    // chr4c with the fixed-width sys8 font (8x8, 1bpp). The text layer's bgcnt
    // has NO BG_PRIO bits, so it's priority 0 (frontmost); the game's tile layers
    // are set to priority 1+ (gba_bg.c) so text draws ON TOP of them.
    tte_init_chr4c(TEXT_BG, BG_CBB(TEXT_CBB) | BG_SBB(TEXT_SBB),
                   0xF000, 0x0001, 0x00007FFF,
                   &sys8Font, NULL);
    REG_DISPCNT |= DCNT_BG3;                        // enable the text layer
    gba_text_clear();                              // blank the HUD region (no garbage)
}

// blank the text layer for a fresh frame's HUD. We only need to clear the tiles
// that TTE actually renders glyphs into. schr4c_prep_map mapped each screen cell
// to its own tile (32x32 = 1024 tiles, but CBB3 holds 512 — so it wraps; TTE
// only touches the top rows in practice). Clear the first 128 tiles (top 4 rows
// of cells) — enough for a HUD — rather than the whole block (which blanked the
// display). Cheap + safe.
void gba_text_clear(void)
{
    if (!text_tiled_ready) return;
    // zero the WHOLE glyph charblock (CBB3 = 512 tiles = 4096 words) so every
    // mapped cell shows transparent until TTE renders a glyph into it. memset32
    // takes a WORD count (not bytes) — the earlier byte-count call overran into
    // OBJ VRAM and blacked the screen.
    memset32(&tile_mem[TEXT_CBB][0], 0, 4096);
    tte_set_pos(0, 0);
}

int gba_text_tiled_active(void) { return text_tiled_ready; }
