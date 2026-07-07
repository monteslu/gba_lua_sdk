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
    *bank_reg  = bankflip | BG_GROUP | BANK_CLIP_X | BANK_CLIP_Y;
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
    *bank_reg  = bankflip | BG_GROUP | BANK_CLIP_X | BANK_CLIP_Y;
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
