/* gt_api.c — minimal direct-draw GameTank runtime for gtlua.
 *
 * Register protocols follow clydeshaffer/gametank_sdk (gfx_sys.c,
 * draw_direct.c, input.c — MIT) with the draw queue omitted: every draw is a
 * direct blit behind the draw_busy IRQ protocol.
 *
 * Hardware rules encoded here (never exposed to user code):
 *  - never touch $2007/$2005 or kick a blit while one is in flight
 *    (drain gt_draw_busy first; the blit-complete IRQ clears it)
 *  - $2007/$2005 are write-only: RAM mirrors are the only readable copy
 *  - the blitter COLOR register is inverted on output, so poke ~color
 *  - a WxH blit writes exactly WxH pixels, W/H <= 127 (bit 7 = flip flag)
 */
#include "gametank.h"
#include "gt_api.h"

char gt_frameflag;
char gt_draw_busy;
unsigned int gt_ticks;

int gt_p1_buttons, gt_p1_prev, gt_p1_pressed;
int gt_p2_buttons, gt_p2_prev, gt_p2_pressed;

static char flags_mirror;   /* last value written to $2007 */
static char banks_mirror;   /* last value written to $2005 */
static char frameflip;      /* DMA_PAGE_OUT bit state      */
static char bankflip;       /* BANK_SECOND_FRAMEBUFFER bit state */

#define GT_INPUT_ALL (GT_UP|GT_DOWN|GT_LEFT|GT_RIGHT|GT_A|GT_B|GT_C|GT_START)

/* ---- blitter drain: spin until the blit-complete IRQ clears the flag ---- */
static void await_drawing(void) {
    __asm__("CLI");
    while (gt_draw_busy) {}
}

static void await_vsync(void) {
    gt_frameflag = 1;
    while (gt_frameflag) {}
}

static void flip_pages(void) {
    frameflip ^= DMA_PAGE_OUT;
    bankflip ^= BANK_SECOND_FRAMEBUFFER;
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_OPAQUE | DMA_GCARRY
                 | frameflip;
    *dma_flags = flags_mirror;
    banks_mirror = bankflip;
    *bank_reg = banks_mirror;
}

/* ---- direct color-fill blit; caller guarantees w,h in 1..127 ---- */
static void box_raw(unsigned char x, unsigned char y,
                    unsigned char w, unsigned char h, unsigned char color) {
    await_drawing();
    flags_mirror |= DMA_ENABLE | DMA_IRQ | DMA_COLORFILL_ENABLE | DMA_OPAQUE;
    *dma_flags = flags_mirror;
    banks_mirror &= ~(BANK_RAM_MASK | BANK_SECOND_FRAMEBUFFER);
    banks_mirror |= bankflip | BANK_CLIP_X | BANK_CLIP_Y;
    *bank_reg = banks_mirror;
    vram[VX] = x;
    vram[VY] = y;
    vram[WIDTH] = w;
    vram[HEIGHT] = h;
    vram[COLOR] = ~color;
    gt_draw_busy = 1;
    vram[START] = 1;
}

void gt_box(unsigned char x, unsigned char y,
            unsigned char w, unsigned char h, unsigned char color) {
    if (x > 127 || y > 127 || w == 0 || h == 0) return;
    if (w > 127) w = 127;
    if (h > 127) h = 127;
    box_raw(x, y, w, h, color);
}

/* Full 128x128 clear. One blit maxes at 127x127, so finish the right
 * column, bottom row, and corner pixel with three small fills. */
void gt_cls(unsigned char color) {
    box_raw(0, 0, 127, 127, color);
    box_raw(127, 0, 1, 127, color);
    box_raw(0, 127, 127, 1, color);
    box_raw(127, 127, 1, 1, color);
}

/* ---- input: latch + two reads per pad, active-low, per the C SDK ---- */
#pragma optimize (push, off)
void gt_update_inputs(void) {
    char lo, hi;
    lo = *gamepad_2;              /* reset the select line */
    lo = *gamepad_1;
    hi = *gamepad_1;
    gt_p1_prev = gt_p1_buttons;
    gt_p1_buttons = ~((((int) hi) << 8) | (lo & 0xFF));
    gt_p1_buttons &= GT_INPUT_ALL;
    gt_p1_pressed = gt_p1_buttons & ~gt_p1_prev;

    lo = *gamepad_2;
    hi = *gamepad_2;
    gt_p2_prev = gt_p2_buttons;
    gt_p2_buttons = ~((((int) hi) << 8) | (lo & 0xFF));
    gt_p2_buttons &= GT_INPUT_ALL;
    gt_p2_pressed = gt_p2_buttons & ~gt_p2_prev;
}
#pragma optimize (pop)

unsigned char gt_btn(int mask)   { return (gt_p1_buttons & mask) != 0; }
unsigned char gt_btnp(int mask)  { return (gt_p1_pressed & mask) != 0; }
unsigned char gt_btn2(int mask)  { return (gt_p2_buttons & mask) != 0; }
unsigned char gt_btnp2(int mask) { return (gt_p2_pressed & mask) != 0; }

/* ---- lifecycle ---- */
void gt_init(void) {
    gt_frameflag = 0;
    gt_draw_busy = 0;
    gt_ticks = 0;
    frameflip = 0;
    bankflip = BANK_SECOND_FRAMEBUFFER;
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ;
    *dma_flags = flags_mirror;
    banks_mirror = bankflip;
    *bank_reg = banks_mirror;
    __asm__("CLI");
    /* Power-on VRAM is random noise on real hardware and in the emulator.
     * Clear both pages so frame 0 is deterministic. */
    gt_cls(0);
    await_drawing();
    flip_pages();
    gt_cls(0);
    await_drawing();
    flip_pages();
}

void gt_endframe(void) {
    await_drawing();
    await_vsync();
    flip_pages();
}
