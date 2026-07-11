/* gt_bg.c — offscreen-GRAM background canvas.
 *
 * THE PERF LEVER (measured 2026-07-03): the GameTank has 512 KB of GRAM = 32
 * pages of 128x128, and the SDK uses only page 0 (the sprite sheet). A blit
 * costs ~1193 cycles of setup REGARDLESS of size, so a full-screen background
 * drawn as ONE big blit from a spare GRAM page is ~free (measured 2.00
 * vsyncs/frame, locked 30fps), vs a per-tile spr() loop (~1 blit per visible
 * tile — e.g. 77 tiles = 1.76 vsyncs in newleste).
 *
 * Usage: compose the level's static tiles into the bg page ONCE per level load,
 * then blit the whole thing (or a scrolled window) every frame:
 *   gt.bg_compose(map, cols, cx, cy, cw, ch)   -- CPU-paint tiles -> bg page
 *   gt.bg_draw([sx], [sy])                      -- blit bg window -> screen
 *
 * GRAM page addressing (from the core): a blit read / CPU write reaches
 *   gram[(addr & 0x3FFF) | (((bank_reg & 7) << 2 | mid) << 14)]
 * mid (0..3) = GX/GY bit7. Page = (bank_reg&7, GX/GY bit7). Page 0 = the sheet;
 * this uses GRAM GROUP 1 quadrant 0 as the background page.
 *
 * The blitter can only WRITE to VRAM (framebuffer), never to GRAM — so
 * gt_bg_compose paints the bg page with CPU writes (reading tile pixels from
 * the packed sheet in ROM, like gt_sheet_load), and gt_bg_draw is the cheap
 * per-frame blit FROM the page. */
#include "gametank.h"
#include "gt_api.h"

#define BG_GROUP 1                  /* bank_reg low bits select GRAM group 1 */
#define TRACK_GROUP 3               /* group 3: a free 256x256 canvas (0=fb+sheet,
                                     * 1=bg atlas, 2=font cache) — the scrolling
                                     * track cache for driftmania-style renderers */

/* Which GRAM group the CPU-write + bg_draw paths target. Default BG_GROUP; the
 * track-cache path flips it to TRACK_GROUP around a compose/view and restores. */
static unsigned char bg_grp = BG_GROUP;

/* draw-mode + page-flip plumbing (defined in gt_api.c). frameflip/bankflip are
 * the page-flip bit states; a normal frame's blit runs against $2007 =
 * DMA_NMI|ENABLE|IRQ|OPAQUE|GCARRY|frameflip and $2005 = bankflip. The bg blit
 * derives its flags/bank from these (NOT the flags_mirror/banks_mirror shadows,
 * which sit in a CPU-write state until the end-of-frame flip_pages) so it works
 * on the very first frame after compose. */
extern char gt_draw_mode;
extern char flags_mirror;
extern char banks_mirror;
extern char frameflip;              /* DMA_PAGE_OUT bit (vid-out page this frame) */
extern char bankflip;               /* BANK_SECOND_FRAMEBUFFER bit (bg-write page) */
extern const unsigned char *gt_sheet_ptr;   /* packed 4bpp sheet, or NULL */
#ifdef GT_BANKED
extern unsigned char gt_cur_bank;           /* current $8000 bank (gt_bank.s) */
/* the decode bodies, exiled to bank 2 (B2CODE) with the sheet; see below */
#ifdef GT_BG_COMPOSE_ON
void gt_bg_compose_impl(int *map, int cols, int cx, int cy, int cw, int ch);
#endif
void gt_bg_tile_impl(int t, int px, int py);
#endif

#define MODE_NONE 0

/* Restore the blitter to the SAME state a normal queued-blit frame runs under.
 *
 * WHY (the state-corruption bug): both compose and bg_draw poke $2007/$2005
 * DIRECTLY, bypassing the flags_mirror/banks_mirror shadows the SDK's draw
 * path keeps in sync with the hardware. On exit the shadows disagree with the
 * registers, and — worse — the LIVE $2007 is left in a NON-blit state
 * (DMA_NMI: DMA_ENABLE clear). The emulator materializes a finished blit and
 * chooses the displayed framebuffer page from the LIVE $2007/$2005 at that
 * moment, so a later spr()/rectfill kicked while $2007 has DMA_ENABLE clear
 * writes NOTHING (whole screen black), and gt_bg_draw's own blit — which reads
 * flags_mirror — inherits the same dead flags on the first frame (before the
 * end-of-frame flip_pages refreshes the shadow). Restoring here re-establishes
 * exactly what flip_pages leaves for the CURRENT page: shadows == hardware ==
 * a live opaque blit to this frame's draw page, so the next queued blit and the
 * page presentation both see valid state. Cheap (a few register stores) and
 * called once per compose / per bg_draw, not per pixel. */
static void bg_restore_draw_state(void) {
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_OPAQUE | DMA_GCARRY | frameflip;
    *dma_flags = flags_mirror;
    banks_mirror = bankflip;
    *bank_reg = banks_mirror;
    gt_qbank = bankflip | BANK_CLIP_X | BANK_CLIP_Y;  /* queue's $2005 byte */
    gt_draw_mode = MODE_NONE;
}

#ifdef GT_BANKED
#ifndef GT_SHEET_BANK
#define GT_SHEET_BANK 2             /* FLASH2M: the sheet rides in bank 2 */
#endif
#endif

/* Fully drain the blit queue + the in-flight blit (mirrors await_drawing). */
static void bg_drain(void) {
    __asm__("CLI");
    while (gt_qhead != gt_qtail) gt_q_pump();
    while (gt_draw_busy) {}
    (void)*((volatile unsigned char *)0x4000);
}

/* Enter CPU-write mode targeting one 128x128 quadrant of the background GRAM
 * group. A group is a 256x256 canvas of 4 quadrants; the blitter picks the
 * quadrant from GX/GY bit 7 (mid=0 TL, 1 TR, 2 BL, 3 BR), and that selection
 * is LATCHED by a blit — so a dummy clipped 1x1 blit with GX/GY bit7 = the
 * quadrant latches it, then DMA-off routes CPU writes into that quadrant.
 * After this, vram[(y<<7)|x] (x,y in 0..127) lands in the chosen quadrant. */
static void bg_enter_write_q(unsigned char quad) {
    bg_drain();
    /* keep frameflip (PAGE_OUT) intact: the display page is read from the
     * LIVE $2007, and this state persists across whole vsyncs during a long
     * compose/clear — dropping the bit flips the presented page out of phase
     * with the game's flip protocol (seen as content on alternate frames
     * only). */
    *dma_flags = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_GCARRY | frameflip;
    *bank_reg  = bankflip | bg_grp | BANK_CLIP_X | BANK_CLIP_Y;
    vram[GX] = (quad & 1) ? 0x80 : 0;   /* GX bit7 -> right quadrant column */
    vram[GY] = (quad & 2) ? 0x80 : 0;   /* GY bit7 -> bottom quadrant row */
    vram[VX] = 200; vram[VY] = 200;  /* offscreen + clipped: no visible pixel */
    vram[WIDTH] = 1; vram[HEIGHT] = 1;
    gt_draw_busy = 1;
    vram[START] = 1;
    bg_drain();
    *dma_flags = DMA_NMI | frameflip;   /* CPU_TO_VRAM off + DMA off -> GRAM writes */
}

/* Compose a tilemap into the background page. The page is first cleared to
 * color 0, then for each of the cw x ch map cells starting at (cx,cy) this
 * copies that tile's 8x8 pixels from the packed sheet to bg position
 * ((i-cx)*8, (j-cy)*8). Tile 0 is left as the cleared color 0 (the PICO-8
 * empty). map[j*cols+i] is the tile index (0-255) at cell (i,j); >255 masked.
 *
 * ONE-TIME cost (per level load), not per frame. Reads the sheet from ROM
 * (bank-mapped in FLASH2M), decodes 4bpp through the palette, writes raw color
 * bytes into the bg page.
 *
 * FLASH2M placement (GT_BANKED): the decode body is a BIG cold routine that
 * would blow the always-mapped fixed bank, so it rides in bank 2 ALONGSIDE the
 * sheet (segment B2CODE) — mapped exactly when it reads the sheet, no
 * mid-routine re-bank. A tiny fixed-bank stub (gt_bg_compose, below) switches
 * to bank 2, calls this _impl, and restores the caller's bank. */
#ifdef GT_BG_COMPOSE_ON
#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_BG_COMPOSE gt_bg_compose_impl
#else
#define GT_BG_COMPOSE gt_bg_compose
#endif
void GT_BG_COMPOSE(int *map, int cols, int cx, int cy, int cw, int ch) {
    int i, j;
    unsigned char py, t, sy0, b, quad, cur_quad, lx;
    unsigned char lut[16];
    const unsigned char *sheet = gt_sheet_ptr;
    if (!sheet) return;
    /* Hoist the p8 palette into a 16-byte LUT ONCE. The old inner loop called
     * gt_p8pal() (a cdecl function call) PER PIXEL — 16 K calls for a full
     * window, the whole reason compose blocked _init for well over a hundred
     * frames. Now it's 16 calls total, then a byte index per pixel. */
    for (b = 0; b < 16; ++b) lut[b] = gt_p8pal(b);
    /* Clear all four quadrants to color 0 first: GRAM powers on random and
     * empty (tile 0) cells are SKIPPED below, and a bg_draw with a small
     * wrapping source offset — a screenshake — must sample clean black.
     * The old "kills rendering in FLAT builds" issue was a phantom: the
     * 64K CPU clear plus a 16K sheet load takes ~55 frames of boot time,
     * and every black screen was a screenshot taken before _init finished
     * (verified: same cart renders at frame 200). Budget accordingly: a
     * full compose is a one-time cost of around a second. */
    { unsigned char q; unsigned int p; unsigned char c0 = lut[0];
      for (q = 0; q < 4; ++q) {
          bg_enter_write_q(q);
          for (p = 0; p < 16384u; ++p) vram[p] = c0;
      }
    }
    cur_quad = 0xFF;                  /* force a re-latch on the first tile */
    for (j = 0; j < ch; ++j) {
        if (cy + j < 0) continue;
        for (i = 0; i < cw; ++i) {
            if (cx + i < 0) continue;
            t = (unsigned char)map[(cy + j) * cols + (cx + i)];
            if (t == 0) continue;                    /* transparent cell */
            /* which 128x128 quadrant does cell (i,j) land in? pixel (i*8, j*8):
             * bit 7 of i*8 == bit 3 of i; likewise j. Tiles are 8px-aligned and
             * quadrants 128px-aligned, so a tile never straddles a boundary. */
            quad = (unsigned char)((((j >> 4) & 1) << 1) | ((i >> 4) & 1));
            if (quad != cur_quad) {  /* re-latch CPU writes to this quadrant */
                bg_enter_write_q(quad);
                cur_quad = quad;
            }
            lx = (unsigned char)((i << 3) & 0x7F);   /* local x within quadrant */
            /* sheet cell origin: sx0 = (t&15)<<3 (always even -> the row's 8
             * source pixels are 4 whole packed bytes), sy0 = (t>>4)<<3 */
            sy0 = (unsigned char)((t >> 4) << 3);
            for (py = 0; py < 8; ++py) {
                /* src row byte cursor: (sy*128 + sx0) >> 1 = (sy<<6) | (sx0>>1)
                 * = ((sy0+py)<<6) | ((t&15)<<2). 4 bytes = 8 pixels, low
                 * nibble first (matches the old (src&1)? hi : lo decode). */
                const unsigned char *sp =
                    sheet + (((unsigned int)(sy0 + py) << 6) | (unsigned int)((t & 15) << 2));
                /* dest cursor: local (lx, (j*8+py)&127) within the quadrant */
                unsigned char *dp =
                    vram + (((unsigned int)(((j << 3) + py) & 0x7F) << 7) | lx);
                unsigned char k;
                for (k = 0; k < 4; ++k) {
                    b = *sp++;
                    *dp++ = lut[b & 15];
                    *dp++ = lut[b >> 4];
                }
            }
        }
    }
    bg_restore_draw_state();          /* hand the blitter back in normal state */
}
#endif /* GT_BG_COMPOSE_ON */

#ifdef GT_BANKED
#pragma code-name ("CODE")
#ifdef GT_BG_COMPOSE_ON
/* Fixed-bank stub: map bank 2 (sheet + the _impl body live there together),
 * run the decode, restore the caller's bank. gt_bank only remaps $8000-$BFFF;
 * the args on the C-stack (RAM) and A/X/sreg survive the switch. */
void gt_bg_compose(int *map, int cols, int cx, int cy, int cw, int ch) {
    unsigned char saved_bank = gt_cur_bank;
    if (!gt_sheet_ptr) return;
    gt_bank(GT_SHEET_BANK);
    gt_bg_compose_impl(map, cols, cx, cy, cw, ch);
    gt_bank(saved_bank);
}
#endif

/* Blit a 128x128 window of the background onto the screen at source offset
 * (sx,sy). The bg group is a 256x256 canvas (4 quadrants); the blitter picks
 * the quadrant per-pixel from GX/GY bit 7 as the source counter crosses 128,
 * so a window at any (sx,sy) in 0..128 scrolls SEAMLESSLY across quadrants —
 * that's how a level larger than one screen scrolls (compose the whole
 * 256x256, then bg_draw(camera_x, camera_y)). 0,0 draws the top-left screen.
 *
 * ONE big blit — the cheap per-frame cost. Enqueued? No: the queue's shared
 * bank byte points at GRAM group 0; a bg blit needs group 1, so it runs
 * synchronously here (drain, program, wait). It's one blit/frame, so the drain
 * cost is negligible and it can't fill-flicker (it runs to completion before
 * the frame's sprites, which draw on top). */
#endif /* GT_BG_COMPOSE_ON */

void gt_bg_draw(int sx, int sy) {
    bg_drain();
    /* exactly a normal opaque frame blit to THIS frame's draw page (derived
     * from frameflip/bankflip, NOT the flags_mirror shadow — on the first
     * frame after compose the shadow is still in the CPU-write DMA_NMI state
     * with DMA_ENABLE clear, which would blit nothing). Source GRAM group 1
     * (the composed bg page) via BG_GROUP. */
    *dma_flags = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_OPAQUE | DMA_GCARRY | frameflip;
    *bank_reg  = bankflip | bg_grp | BANK_CLIP_X | BANK_CLIP_Y;
    vram[GX] = (unsigned char)sx;
    vram[GY] = (unsigned char)sy;
    vram[VX] = 0;
    vram[VY] = 0;
    vram[WIDTH]  = 127;
    vram[HEIGHT] = 127;
    gt_draw_busy = 1;
    vram[START] = 1;
    bg_drain();
    bg_restore_draw_state();          /* hand the blitter back in normal state */
}

/* ---- track cache (group 3) -----------------------------------------------
 * A second scrolling canvas independent of the bg atlas (group 1). A renderer
 * whose whole background re-blits every frame (a scrolling tilemap) composes
 * the visible window + margin ONCE into group 3, then restores it each frame
 * with a single windowed blit (gt_track_view) — 4 quadrant copies instead of
 * the dozens/hundreds of per-cell fills+chunk blits the live render stages.
 *
 * Compose reuses gt_bg_compose_impl verbatim; only the target GROUP differs
 * (bg_grp). The map is a tile-id grid the caller builds for the visible window
 * (tile 0 = transparent -> left as the cleared color 0). Restore is gt_bg_draw
 * with the group flipped. Both save/restore bg_grp so bg-atlas users are
 * unaffected. */
#if defined(GT_BG_COMPOSE_ON) && defined(GT_TRACK_CACHE)
/* Compose a BYTE tile-id grid (cw x ch, stride cols) into the track cache
 * (group 3). Tile 0 = transparent (left cleared). Same 4bpp sheet decode as
 * gt_bg_compose, but the map is bytes (tile ids fit a byte) — half the RAM of
 * the int map, which matters in the 2 KB budget. Composes to quadrant 0..3 by
 * the cell's 128px block, re-latching CPU writes per quadrant. */
#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_TRACK_COMPOSE gt_track_compose_impl
#else
#define GT_TRACK_COMPOSE gt_track_compose
#endif
void GT_TRACK_COMPOSE(unsigned char *map, int cols, int cx, int cy,
                      int cw, int ch) {
    int i, j;
    unsigned char py, t, sy0, b, quad, cur_quad, lx;
    unsigned char lut[16];
    const unsigned char *sheet = gt_sheet_ptr;
    if (!sheet) return;
    for (b = 0; b < 16; ++b) lut[b] = gt_p8pal(b);
    bg_grp = TRACK_GROUP;
    { unsigned char q; unsigned int p; unsigned char c0 = lut[0];
      for (q = 0; q < 4; ++q) { bg_enter_write_q(q);
          for (p = 0; p < 16384u; ++p) vram[p] = c0; } }
    cur_quad = 0xFF;
    for (j = 0; j < ch; ++j) {
        if (cy + j < 0) continue;
        for (i = 0; i < cw; ++i) {
            if (cx + i < 0) continue;
            t = map[(cy + j) * cols + (cx + i)];
            if (t == 0) continue;
            quad = (unsigned char)((((j >> 4) & 1) << 1) | ((i >> 4) & 1));
            if (quad != cur_quad) { bg_enter_write_q(quad); cur_quad = quad; }
            lx = (unsigned char)((i << 3) & 0x7F);
            if (t & 0x80) {
                /* flat fill: 8x8 of color (t & 15) — matches chunks_draw's
                 * direct rectfill in color k (NOT a sheet tile). */
                b = lut[t & 15];
                for (py = 0; py < 8; ++py) {
                    unsigned char *dp =
                        vram + (((unsigned int)(((j << 3) + py) & 0x7F) << 7) | lx);
                    unsigned char k; for (k = 0; k < 8; ++k) *dp++ = b;
                }
                continue;
            }
            sy0 = (unsigned char)((t >> 4) << 3);
            for (py = 0; py < 8; ++py) {
                const unsigned char *sp =
                    sheet + (((unsigned int)(sy0 + py) << 6) | (unsigned int)((t & 15) << 2));
                unsigned char *dp =
                    vram + (((unsigned int)(((j << 3) + py) & 0x7F) << 7) | lx);
                unsigned char k;
                for (k = 0; k < 4; ++k) {
                    b = *sp++;
                    *dp++ = lut[b & 15];
                    *dp++ = lut[b >> 4];
                }
            }
        }
    }
    bg_restore_draw_state();
    bg_grp = BG_GROUP;
}

#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_track_compose(unsigned char *map, int cols, int cx, int cy,
                      int cw, int ch) {
    unsigned char saved_bank = gt_cur_bank;
    if (!gt_sheet_ptr) return;
    gt_bank(GT_SHEET_BANK);
    gt_track_compose_impl(map, cols, cx, cy, cw, ch);
    gt_bank(saved_bank);
}
#endif

/* ---- cgrid-driven track compose (the real path) --------------------------
 * Paint the visible 16x16 sub-tile window (128x128) directly from the packed
 * chunk grid, running gt.chunks_draw's exact per-cell decode but writing GRAM
 * group 3 instead of staging blits. No RAM tile-map (reads cgrid), and it
 * layers road THEN decal-with-colorkey so decal transparency shows the road —
 * which the flat one-tile-per-cell map couldn't. Pixel-identical to the live
 * render by construction.
 *
 * grid  : cgrid, an int per 3x3-tile chunk cell, row stride `stride` cells.
 * ckdt  : int[]; ckdt[n] low byte = ckd(n) (color if <16, atlas idx if >=16),
 *         high byte = ckt(n) (a solid-color sheet tile, unused here).
 * ctiles: int[]; ctile(idx) = (idx&1) ? ctiles[idx>>1]>>8 : ctiles[idx>>1]&255
 *         — the atlas chunk's 9 sub-tile sheet ids.
 * tx0/ty0: top-left 8px-tile of the window. grassCol: p8 color for empty road.
 * decb: the decal ckdt offset (driftmania's DECB). */
#if defined(GT_TRACK_CACHE)
/* decode ONE 8px sub-tile from sheet tile `t` at canvas (lx, py0..+7). If
 * colorkey, source nibble 0 is skipped (leaves the road underneath). */
static void tgrid_tile(const unsigned char *sheet, const unsigned char *lut,
                       unsigned char t, unsigned char lx, unsigned char py0,
                       unsigned char colorkey) {
    unsigned char py, k, b, sy0 = (unsigned char)((t >> 4) << 3);
    for (py = 0; py < 8; ++py) {
        const unsigned char *sp =
            sheet + (((unsigned int)(sy0 + py) << 6) | (unsigned int)((t & 15) << 2));
        unsigned char *dp = vram + (((unsigned int)((py0 + py) & 0x7F) << 7) | lx);
        for (k = 0; k < 4; ++k) {
            b = *sp++;
            if (!colorkey || (b & 15)) *dp = lut[b & 15];
            dp++;
            if (!colorkey || (b >> 4)) *dp = lut[b >> 4];
            dp++;
        }
    }
}

/* Resolve + paint ONE world sub-tile into the current quadrant at local
 * (lx, py0). Runs chunks_draw's exact road+decal decode: flat road = opaque
 * fill; atlas road = grass then colorkey chunk; decal (over road) = flat opaque
 * or colorkey atlas. ckdt/ctiles are Lua 1-indexed (ckdt[n-1]; ctiles[idx>>1]
 * where the Lua +1 and C -1 cancel). Shared by grid/col/row compose.
 *
 * The chunk cell (cxc,cyr) + sub-tile (srx,sry) come in PRE-DIVIDED: the caller
 * tracks them incrementally (srx cycles 0,1,2; cxc bumps on wrap) so the hot
 * loop never runs the 6502 software divide (udiv16by8a was ~3.5k cyc/column in
 * the profile — no /3 in here now). oob=1 forces grass (off the 90x90 grid). */
/* world tile t -> chunk cell *cc, sub *sr (0..2), *oob if off the 90x90 grid.
 * The ONE /3 site; callers hoist it out of the sub-tile loop (per row/column,
 * or once for a constant-tile column). */
static void tdiv(int t, int *cc, int *sr, int *oob) {
    if (t < 0 || t >= 90) { *oob = 1; *cc = 0; *sr = 0; return; }
    *oob = 0;
    { int c = t / 3; *cc = c; *sr = t - c * 3; }
}
static void paint_subtile(int *grid, int *ckdt, int *ctiles, int stride,
                          const unsigned char *sheet, const unsigned char *lut,
                          int cxc, int cyr, int srx, int sry, int oob,
                          int grassCol, int decb,
                          unsigned char lx, unsigned char py0) {
    int cg, sub, r, d, k;
    unsigned char rtile = 0, dtile = 0, rflat = 0xFF, dflat = 0xFF, py, kk, c;
    if (oob) { cg = 0; }
    else cg = grid[cyr * stride + cxc];
    sub = sry * 3 + srx;
    r = cg & 31;
    if (r == 0) { rflat = (unsigned char)grassCol; }
    else {
        k = ckdt[r - 1] & 255;
        if (k < 16) rflat = (unsigned char)k;
        else { int idx = (k - 16) * 9 + sub;
               rtile = (unsigned char)((idx & 1) ? (ctiles[idx >> 1] >> 8)
                                                 : (ctiles[idx >> 1] & 255)); }
    }
    d = (cg >> 5) & 31;
    if (d != 0) {
        k = ckdt[d + decb - 1] & 255;
        if (k < 16) dflat = (unsigned char)k;
        else { int idx = (k - 16) * 9 + sub;
               dtile = (unsigned char)((idx & 1) ? (ctiles[idx >> 1] >> 8)
                                                 : (ctiles[idx >> 1] & 255)); }
    }
    /* road */
    if (rflat != 0xFF) {
        c = lut[rflat];
        for (py = 0; py < 8; ++py) {
            unsigned char *dp = vram + (((unsigned int)((py0 + py) & 0x7F) << 7) | lx);
            for (kk = 0; kk < 8; ++kk) *dp++ = c;
        }
    } else {
        c = lut[(unsigned char)grassCol];
        for (py = 0; py < 8; ++py) {
            unsigned char *dp = vram + (((unsigned int)((py0 + py) & 0x7F) << 7) | lx);
            for (kk = 0; kk < 8; ++kk) *dp++ = c;
        }
        if (rtile) tgrid_tile(sheet, lut, rtile, lx, py0, 1);
    }
    /* decal over road */
    if (dflat != 0xFF) {
        c = lut[dflat];
        for (py = 0; py < 8; ++py) {
            unsigned char *dp = vram + (((unsigned int)((py0 + py) & 0x7F) << 7) | lx);
            for (kk = 0; kk < 8; ++kk) *dp++ = c;
        }
    } else if (dtile) tgrid_tile(sheet, lut, dtile, lx, py0, 1);
}
#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_TRACK_GRID gt_track_grid_impl
#else
#define GT_TRACK_GRID gt_track_grid
#endif
/* Composes a 32x32 sub-tile (256x256px) region = ALL FOUR group-3 quadrants,
 * so the 128x128 view can scroll up to ~128px within it before a recompose.
 * tx0/ty0 = top-left 8px-tile of the 256px region. */
void GT_TRACK_GRID(int *grid, int *ckdt, int *ctiles, int stride,
                   int tx0, int ty0, int grassCol, int decb) {
    unsigned char lut[16];
    unsigned char b, quad;
    const unsigned char *sheet = gt_sheet_ptr;
    if (!sheet) return;
    for (b = 0; b < 16; ++b) lut[b] = gt_p8pal(b);
    bg_grp = TRACK_GROUP;
    /* TORUS: world tile (tx0+i, ty0+j) lands at canvas ((tx0+i)&31)*8,
     * ((ty0+j)&31)*8 = (worldpx & 255). track_view reads at (camxi&255,
     * camyi&255), so the seam wraps seamlessly. QUADRANT-MAJOR over CANVAS
     * quadrants: enter CPU-write ONCE per quadrant. Canvas col cvx (0..31) ->
     * quadrant column cvx>>4, local x (cvx&15)<<3; the world tile for this
     * canvas col is the one whose (&31) == cvx, i.e. tx0 + ((cvx - (tx0&31))
     * & 31). Same for rows. */
    { unsigned char qy, qx, jj, ii;
    int tbaseX = tx0 & 31, tbaseY = ty0 & 31;
    for (qy = 0; qy < 2; ++qy)
    for (qx = 0; qx < 2; ++qx) {
      quad = (unsigned char)((qy << 1) | qx);
      bg_enter_write_q(quad);
      for (jj = 0; jj < 16; ++jj) {
        int cvy = (qy << 4) + jj;                 /* canvas sub-row 0..31 */
        int ty = ty0 + ((cvy - tbaseY) & 31);     /* world tile at this canvas row */
        unsigned char py0 = (unsigned char)((cvy << 3) & 0x7F);
        int cyr, sry, yoob; tdiv(ty, &cyr, &sry, &yoob);   /* ONE /3 per row */
        for (ii = 0; ii < 16; ++ii) {
            int cvx = (qx << 4) + ii;              /* canvas sub-col 0..31 */
            int tx = tx0 + ((cvx - tbaseX) & 31);  /* world tile at this canvas col */
            unsigned char lx = (unsigned char)((cvx << 3) & 0x7F);
            int cxc, srx, xoob; tdiv(tx, &cxc, &srx, &xoob);
            paint_subtile(grid, ckdt, ctiles, stride, sheet, lut,
                          cxc, cyr, srx, sry, xoob || yoob, grassCol, decb, lx, py0);
        }
      }
    }
    }
    bg_restore_draw_state();
    bg_grp = BG_GROUP;
}

/* Refresh ONE canvas column (32 sub-tiles tall) for world tile-x `wtx`, at the
 * torus canvas x = (wtx & 31)*8. `wty0` = the world tile-y at canvas row 0.
 * Cheap incremental scroll: paint only the column that just entered the view. */
#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_TRACK_COL gt_track_col_impl
#else
#define GT_TRACK_COL gt_track_col
#endif
void GT_TRACK_COL(int *grid, int *ckdt, int *ctiles, int stride,
                  int wtx, int wty0, int grassCol, int decb) {
    unsigned char lut[16], b, cvx, quad, jj;
    const unsigned char *sheet = gt_sheet_ptr;
    if (!sheet) return;
    for (b = 0; b < 16; ++b) lut[b] = gt_p8pal(b);
    bg_grp = TRACK_GROUP;
    cvx = (unsigned char)(wtx & 31);              /* canvas sub-col 0..31 */
    { unsigned char qy; int tbaseY = wty0 & 31;
      unsigned char lx = (unsigned char)((cvx << 3) & 0x7F);
      int cxc, srx, xoob; tdiv(wtx, &cxc, &srx, &xoob);   /* wtx CONSTANT: one /3 */
      for (qy = 0; qy < 2; ++qy) {
        quad = (unsigned char)((qy << 1) | (cvx >> 4));
        bg_enter_write_q(quad);
        for (jj = 0; jj < 16; ++jj) {
            int cvy = (qy << 4) + jj;
            int ty = wty0 + ((cvy - tbaseY) & 31);
            unsigned char py0 = (unsigned char)((cvy << 3) & 0x7F);
            int cyr, sry, yoob; tdiv(ty, &cyr, &sry, &yoob);
            paint_subtile(grid, ckdt, ctiles, stride, sheet, lut,
                          cxc, cyr, srx, sry, xoob || yoob, grassCol, decb, lx, py0);
        }
      }
    }
    bg_restore_draw_state();
    bg_grp = BG_GROUP;
}

/* Refresh ONE canvas row (32 sub-tiles wide) for world tile-y `wty`, at torus
 * canvas y = (wty & 31)*8. `wtx0` = world tile-x at canvas col 0. */
#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_TRACK_ROW2 gt_track_row2_impl
#else
#define GT_TRACK_ROW2 gt_track_row2
#endif
void GT_TRACK_ROW2(int *grid, int *ckdt, int *ctiles, int stride,
                   int wty, int wtx0, int grassCol, int decb) {
    unsigned char lut[16], b, cvy, quad, ii;
    const unsigned char *sheet = gt_sheet_ptr;
    if (!sheet) return;
    for (b = 0; b < 16; ++b) lut[b] = gt_p8pal(b);
    bg_grp = TRACK_GROUP;
    cvy = (unsigned char)(wty & 31);
    { unsigned char qx; int tbaseX = wtx0 & 31;
      unsigned char py0 = (unsigned char)((cvy << 3) & 0x7F);
      int cyr, sry, yoob; tdiv(wty, &cyr, &sry, &yoob);   /* wty CONSTANT: one /3 */
      for (qx = 0; qx < 2; ++qx) {
        quad = (unsigned char)(((cvy >> 4) << 1) | qx);
        bg_enter_write_q(quad);
        for (ii = 0; ii < 16; ++ii) {
            int cvx = (qx << 4) + ii;
            int tx = wtx0 + ((cvx - tbaseX) & 31);
            unsigned char lx = (unsigned char)((cvx << 3) & 0x7F);
            int cxc, srx, xoob; tdiv(tx, &cxc, &srx, &xoob);
            paint_subtile(grid, ckdt, ctiles, stride, sheet, lut,
                          cxc, cyr, srx, sry, xoob || yoob, grassCol, decb, lx, py0);
        }
      }
    }
    bg_restore_draw_state();
    bg_grp = BG_GROUP;
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_track_grid(int *grid, int *ckdt, int *ctiles, int stride,
                   int tx0, int ty0, int grassCol, int decb) {
    unsigned char saved_bank = gt_cur_bank;
    if (!gt_sheet_ptr) return;
    gt_bank(GT_SHEET_BANK);
    gt_track_grid_impl(grid, ckdt, ctiles, stride, tx0, ty0, grassCol, decb);
    gt_bank(saved_bank);
}
void gt_track_col(int *grid, int *ckdt, int *ctiles, int stride,
                  int wtx, int wty0, int grassCol, int decb) {
    unsigned char saved_bank = gt_cur_bank;
    if (!gt_sheet_ptr) return;
    gt_bank(GT_SHEET_BANK);
    gt_track_col_impl(grid, ckdt, ctiles, stride, wtx, wty0, grassCol, decb);
    gt_bank(saved_bank);
}
void gt_track_row2(int *grid, int *ckdt, int *ctiles, int stride,
                   int wty, int wtx0, int grassCol, int decb) {
    unsigned char saved_bank = gt_cur_bank;
    if (!gt_sheet_ptr) return;
    gt_bank(GT_SHEET_BANK);
    gt_track_row2_impl(grid, ckdt, ctiles, stride, wty, wtx0, grassCol, decb);
    gt_bank(saved_bank);
}
#endif
#endif /* GT_TRACK_CACHE */


/* gt_track_view lives in gt_api.c: it reuses the QUEUED gt_canvas_view path
 * (async 4-copy, no synchronous drain) targeting group 3 — the cheap per-frame
 * restore that hits the render ceiling, unlike a synchronous gt_bg_draw. */
#endif /* GT_TRACK_CACHE */

/* ---- atlas-building primitives -------------------------------------------
 * gt.bg_clear() + gt.bg_tile(t, px, py) let a game paint the 256x256 canvas
 * freeform — an ATLAS of pre-rendered multi-tile chunks, a big boss sprite,
 * anything — without materializing a full tile map in scarce RAM (a 30x18
 * atlas map alone would be >1 KB). Stamp tiles anywhere (8px-aligned so a
 * tile never straddles a quadrant), then blit any rect back per frame with
 * gt.gspr(). All one-time init cost. */

#ifdef GT_BG_ATLAS
/* Clear the whole 256x256 canvas to color 0 (all four quadrants). */
void gt_bg_clear(void) {
    unsigned char q; unsigned int p;
    unsigned char c0 = gt_p8pal(0);
    for (q = 0; q < 4; ++q) {
        bg_enter_write_q(q);
        for (p = 0; p < 16384u; ++p) vram[p] = c0;
    }
    bg_restore_draw_state();
}

/* Stamp sheet tile t (0-255) at canvas pixel (px,py); multiples of 8 only.
 * Same 4bpp sheet decode as compose, one 8x8 cell. */
#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_BG_TILE gt_bg_tile_impl
#else
#define GT_BG_TILE gt_bg_tile
#endif
extern unsigned char p8pal[16];
void GT_BG_TILE(int t, int px, int py) {
    unsigned char py2, b, k, quad, lx, sy0;
    const unsigned char *lut = p8pal;   /* pal-aware, no per-stamp rebuild */
    const unsigned char *sheet = gt_sheet_ptr;
    if (!sheet) return;
    if (t < 0 || t > 255) return;
    quad = (unsigned char)((((py >> 7) & 1) << 1) | ((px >> 7) & 1));
    bg_enter_write_q(quad);
    lx  = (unsigned char)(px & 0x7F);
    if (t == 0) {
        /* tile 0 = clear the cell to color 0: ring-canvas users stamp air
         * over stale columns (the old skip left garbage on screen) */
        b = lut[0];
        for (py2 = 0; py2 < 8; ++py2) {
            unsigned char *dp =
                vram + (((unsigned int)((py + py2) & 0x7F) << 7) | lx);
            for (k = 0; k < 8; ++k) *dp++ = b;
        }
        bg_restore_draw_state();
        return;
    }
    sy0 = (unsigned char)(((t >> 4) & 15) << 3);
    for (py2 = 0; py2 < 8; ++py2) {
        const unsigned char *sp =
            sheet + (((unsigned int)(sy0 + py2) << 6) | (unsigned int)((t & 15) << 2));
        unsigned char *dp =
            vram + (((unsigned int)((py + py2) & 0x7F) << 7) | lx);
        for (k = 0; k < 4; ++k) {
            b = *sp++;
            *dp++ = lut[b & 15];
            *dp++ = lut[b >> 4];
        }
    }
    bg_restore_draw_state();
}

/* stamp a COLUMN of n cells (one mode dance total — per-stamp enter/
 * restore was ~1.2k cycles each, 19k for a 16-row ring column). The
 * column must stay inside one 128px quadrant vertically. cells[i] = 0
 * clears that cell to color 0. */
#ifdef GT_BANKED
#define GT_BG_COLN gt_bg_coln_impl
#else
#define GT_BG_COLN gt_bg_coln
#endif
#ifdef GT_BANKED
static
#endif
void GT_BG_COLN(unsigned char *cells, int px, int py, int n) {
    unsigned char py2, b, k, quad, lx, sy0, t, i;
    const unsigned char *lut = p8pal;
    const unsigned char *sheet = gt_sheet_ptr;
    if (!sheet) return;
    quad = (unsigned char)((((py >> 7) & 1) << 1) | ((px >> 7) & 1));
    bg_enter_write_q(quad);
    lx = (unsigned char)(px & 0x7F);
    for (i = 0; i < n; ++i, py += 8) {
        t = cells[i];
        if (t == 0) {
            b = lut[0];
            for (py2 = 0; py2 < 8; ++py2) {
                unsigned char *dp =
                    vram + (((unsigned int)((py + py2) & 0x7F) << 7) | lx);
                for (k = 0; k < 8; ++k) *dp++ = b;
            }
            continue;
        }
        sy0 = (unsigned char)(((t >> 4) & 15) << 3);
        for (py2 = 0; py2 < 8; ++py2) {
            const unsigned char *sp =
                sheet + (((unsigned int)(sy0 + py2) << 6) | (unsigned int)((t & 15) << 2));
            unsigned char *dp =
                vram + (((unsigned int)((py + py2) & 0x7F) << 7) | lx);
            for (k = 0; k < 4; ++k) {
                b = *sp++;
                *dp++ = lut[b & 15];
                *dp++ = lut[b >> 4];
            }
        }
    }
    bg_restore_draw_state();
}

#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_bg_coln(unsigned char *cells, int px, int py, int n) {
    unsigned char saved_bank = gt_cur_bank;
    if (!gt_sheet_ptr) return;
    gt_bank(GT_SHEET_BANK);
    gt_bg_coln_impl(cells, px, py, n);
    gt_bank(saved_bank);
}
#endif

#ifdef GT_BANKED
/* fixed-bank stub, same pattern as gt_bg_compose */
void gt_bg_tile(int t, int px, int py) {
    unsigned char saved_bank = gt_cur_bank;
    if (!gt_sheet_ptr) return;
    /* (t==0 clears the cell; the impl handles it) */
    gt_bank(GT_SHEET_BANK);
    gt_bg_tile_impl(t, px, py);
    gt_bank(saved_bank);
}
#endif
#endif /* GT_BG_ATLAS */

/* Fully drain the blit queue + in-flight blit, then re-establish a clean
 * live-blit draw state. Exposed for the track-cache path: after track_view's
 * group-3 opaque blits, draining before the group-1 prop gspr's sidesteps an
 * emulator blitter hang where a group-1 colorkey blit queued behind a completed
 * group-3 opaque blit never raises its done-IRQ. Cheap (drains what's pending). */
void gt_gflush(void) {
    bg_drain();
    bg_restore_draw_state();
}

/* Queue-blit a w x h rect FROM the canvas at (gx,gy) to screen (x,y) — a
 * "sprite" cut from the composed 256x256 page. Camera-adjusted and colorkey-
 * transparent like spr(); rides the normal blit queue (the per-entry bank
 * byte in the color slot selects the bg GRAM group), so it interleaves freely
 * with sheet sprites and fills. This is what makes a chunk ATLAS pay: a
 * pre-rendered 24x24 block is ONE blit instead of nine 8x8 tile blits. */
void gt_gspr(int gx, int gy, int w, int h, int x, int y) {
    x -= gt_cam_x;
    y -= gt_cam_y;
    if (x <= -w || x > 127 || y <= -h || y > 127) return;
    gt_ent[0] = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_GCARRY;   /* colorkey copy */
    gt_ent[1] = (unsigned char)x;
    gt_ent[2] = (unsigned char)y;
    gt_ent[3] = (unsigned char)gx;
    gt_ent[4] = (unsigned char)gy;
    gt_ent[5] = (unsigned char)w;
    gt_ent[6] = (unsigned char)h;
    gt_ent[7] = (unsigned char)(gt_qbank | BG_GROUP);   /* per-entry bank */
    gt_draw_mode = MODE_NONE;
    gt_q_push();
}
