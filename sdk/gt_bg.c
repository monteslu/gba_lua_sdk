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
/* the decode body, exiled to bank 2 (B2CODE) with the sheet; see below */
void gt_bg_compose_impl(int *map, int cols, int cx, int cy, int cw, int ch);
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

/* Enter CPU-write mode targeting the background GRAM page (group 1, quadrant
 * 0): a dummy clipped 1x1 blit latches the group, then DMA-off routes CPU
 * writes into it. After this, vram[(y<<7)|x] lands in the bg page. */
static void bg_enter_write(void) {
    bg_drain();
    *dma_flags = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_GCARRY;
    *bank_reg  = bankflip | BG_GROUP | BANK_CLIP_X | BANK_CLIP_Y;
    vram[GX] = 0; vram[GY] = 0;      /* GX/GY bit7 = 0 -> quadrant 0 */
    vram[VX] = 200; vram[VY] = 200;  /* offscreen + clipped: no visible pixel */
    vram[WIDTH] = 1; vram[HEIGHT] = 1;
    gt_draw_busy = 1;
    vram[START] = 1;
    bg_drain();
    *dma_flags = DMA_NMI;            /* CPU_TO_VRAM off + DMA off -> GRAM writes */
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
#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_BG_COMPOSE gt_bg_compose_impl
#else
#define GT_BG_COMPOSE gt_bg_compose
#endif
void GT_BG_COMPOSE(int *map, int cols, int cx, int cy, int cw, int ch) {
    int i, j;
    unsigned char py, t, sy0, b;
    unsigned char lut[16];
    const unsigned char *sheet = gt_sheet_ptr;
    if (!sheet) return;
    /* Hoist the p8 palette into a 16-byte LUT ONCE. The old inner loop called
     * gt_p8pal() (a cdecl function call) PER PIXEL — 16 K calls for a full
     * window, the whole reason compose blocked _init for well over a hundred
     * frames. Now it's 16 calls total, then a byte index per pixel. */
    for (b = 0; b < 16; ++b) lut[b] = gt_p8pal(b);
    bg_enter_write();
    /* Clear the page to color 0 first: GRAM powers on random, and empty (tile 0)
     * cells are SKIPPED below, so without this they'd show power-on garbage. A
     * full-window compose becomes fully opaque (the common background case). */
    { unsigned int p; unsigned char c0 = lut[0];
      for (p = 0; p < 16384u; ++p) vram[p] = c0; }
    for (j = 0; j < ch; ++j) {
        if (cy + j < 0) continue;
        for (i = 0; i < cw; ++i) {
            if (cx + i < 0) continue;
            t = (unsigned char)map[(cy + j) * cols + (cx + i)];
            if (t == 0) continue;                    /* transparent cell */
            /* sheet cell origin: sx0 = (t&15)<<3 (always even -> the row's 8
             * source pixels are 4 whole packed bytes), sy0 = (t>>4)<<3 */
            sy0 = (unsigned char)((t >> 4) << 3);
            for (py = 0; py < 8; ++py) {
                /* src row byte cursor: (sy*128 + sx0) >> 1 = (sy<<6) | (sx0>>1)
                 * = ((sy0+py)<<6) | ((t&15)<<2). 4 bytes = 8 pixels, low
                 * nibble first (matches the old (src&1)? hi : lo decode). */
                const unsigned char *sp =
                    sheet + (((unsigned int)(sy0 + py) << 6) | (unsigned int)((t & 15) << 2));
                /* dest cursor in the bg page: screen (i*8, j*8+py) */
                unsigned char *dp =
                    vram + ((((unsigned int)(j << 3) + py) << 7) | (unsigned int)(i << 3));
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

#ifdef GT_BANKED
#pragma code-name ("CODE")
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

/* Blit the background window to the screen. (sx,sy) is the source offset within
 * the bg page (for a level larger than one screen; 0,0 draws the page as-is).
 * ONE big blit — the cheap per-frame cost. Enqueued? No: the queue's shared
 * bank byte points at GRAM group 0; a bg blit needs group 1, so it runs
 * synchronously here (drain, program, wait). It's one blit/frame, so the drain
 * cost is negligible and it can't fill-flicker (it runs to completion before
 * the frame's sprites, which draw on top). */
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
