/* gt_api.c — GameTank runtime with the PICO-8-shaped drawing/input surface.
 *
 * Register protocols follow clydeshaffer/gametank_sdk (MIT). Hardware rules
 * encoded here, never exposed:
 *  - drain gt_draw_busy before touching $2007/$2005 or kicking a blit
 *    (the blit-complete IRQ clears it; blitter regs are write-only)
 *  - the blitter inverts the COLOR register: poke ~color
 *  - a WxH blit writes exactly WxH pixels, W/H <= 127
 *  - CPU writes reach VRAM only with DMA_CPU_TO_VRAM set and DMA_ENABLE
 *    clear; the lazy mode tracker below flips between blit and CPU modes
 */
#include "gametank.h"
#include "gt_api.h"

char gt_frameflag;
char gt_draw_busy;
unsigned int gt_ticks;

static char flags_mirror;   /* last value written to $2007 */
static char banks_mirror;   /* last value written to $2005 */
static char frameflip;      /* DMA_PAGE_OUT bit state      */
static char bankflip;       /* BANK_SECOND_FRAMEBUFFER bit state */
static char fps30;          /* _update() mode: two vsyncs per logical frame */

/* draw state (PICO-8 sticky globals) */
static int cam_x, cam_y;
static unsigned char draw_color;   /* resolved GameTank byte */

/* PICO-8 color 0-15 -> GameTank byte; pal() remaps this live table */
static const unsigned char p8pal_rom[16] = {
    0x00, 0xA9, 0x5A, 0xDB, 0x33, 0x03, 0x06, 0x07,
    0x5B, 0x3E, 0x1F, 0xFE, 0xBE, 0x8C, 0x5E, 0x2F,
};
static unsigned char p8pal[16];

/* resolve a color argument: -1 = current; 0x100|b = raw byte; else p8 index.
 * Giving a color also SETS the current color (P8 trailing-color rule). */
static unsigned char resolve_color(int c) {
    if (c < 0) return draw_color;
    if (c & 0x100) draw_color = (unsigned char)c;
    else draw_color = p8pal[c & 15];
    return draw_color;
}

/* ---- mode tracking: blitter registers vs CPU->VRAM writes ---- */
#define MODE_NONE 0
#define MODE_BLIT 1
#define MODE_CPU  2
static char draw_mode;

static void await_drawing(void) {
    __asm__("CLI");
    while (gt_draw_busy) {}
    /* Touch the VDMA bus once after the drain. The emulator materializes
     * blit pixels lazily using the LIVE dma/bank registers; without this
     * read, the frame's final blits can land after a page flip or mode
     * change and stamp the wrong page (visible as flicker). A read forces
     * the catch-up under the still-current state. Harmless on hardware. */
    (void)*((volatile unsigned char *)0x4000);
}

static void enter_blit_mode(void) {
    if (draw_mode == MODE_BLIT) { await_drawing(); return; }
    await_drawing();
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_COLORFILL_ENABLE | DMA_OPAQUE;
    *dma_flags = flags_mirror;
    banks_mirror = bankflip | BANK_CLIP_X | BANK_CLIP_Y;
    *bank_reg = banks_mirror;
    draw_mode = MODE_BLIT;
}

static void enter_cpu_mode(void) {
    if (draw_mode == MODE_CPU) return;
    await_drawing();
    flags_mirror = DMA_NMI | DMA_CPU_TO_VRAM;   /* DMA off: CPU owns VRAM */
    *dma_flags = flags_mirror;
    banks_mirror = bankflip;                    /* write the DRAW page */
    *bank_reg = banks_mirror;
    draw_mode = MODE_CPU;
}

/* raw fill; caller guarantees 0<=x,y<=127, 1<=w,h<=127 (after clipping) */
static void box_raw(unsigned char x, unsigned char y,
                    unsigned char w, unsigned char h, unsigned char color) {
    enter_blit_mode();
    vram[VX] = x;
    vram[VY] = y;
    vram[WIDTH] = w;
    vram[HEIGHT] = h;
    vram[COLOR] = ~color;
    gt_draw_busy = 1;
    vram[START] = 1;
}

/* clipped fill in screen coords (inclusive corners), camera already applied */
static void fill_clipped(int x0, int y0, int x1, int y1, unsigned char color) {
    int t;
    if (x0 > x1) { t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { t = y0; y0 = y1; y1 = t; }
    if (x1 < 0 || y1 < 0 || x0 > 127 || y0 > 127) return;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > 127) x1 = 127;
    if (y1 > 127) y1 = 127;
    /* a full 128-wide/high span needs two blits (7-bit blit counters) */
    if (x1 - x0 == 127) {
        fill_clipped(x0, y0, x1 - 1, y1, color);
        fill_clipped(x1, y0, x1, y1, color);
        return;
    }
    if (y1 - y0 == 127) {
        fill_clipped(x0, y0, x1, y1 - 1, color);
        fill_clipped(x0, y1, x1, y1, color);
        return;
    }
    box_raw((unsigned char)x0, (unsigned char)y0,
            (unsigned char)(x1 - x0 + 1), (unsigned char)(y1 - y0 + 1), color);
}

/* ---- PICO-8 drawing API ---- */

void gt_p8_cls(int c) {
    unsigned char col = (c < 0) ? p8pal[0] : resolve_color(c);
    box_raw(0, 0, 127, 127, col);
    box_raw(127, 0, 1, 127, col);
    box_raw(0, 127, 127, 1, col);
    box_raw(127, 127, 1, 1, col);
}

void gt_p8_camera(int x, int y) { cam_x = x; cam_y = y; }
void gt_p8_color(int c) { resolve_color(c); }

void gt_p8_pal(int c0, int c1) {
    unsigned char i;
    if (c0 < 0) {                     /* pal() — reset */
        for (i = 0; i < 16; ++i) p8pal[i] = p8pal_rom[i];
        return;
    }
    if (c1 < 0) return;
    p8pal[c0 & 15] = (c1 & 0x100) ? (unsigned char)c1 : p8pal_rom[c1 & 15];
}

void gt_p8_rectfill(int x0, int y0, int x1, int y1, int c) {
    unsigned char col = resolve_color(c);
    fill_clipped(x0 - cam_x, y0 - cam_y, x1 - cam_x, y1 - cam_y, col);
}

void gt_p8_rect(int x0, int y0, int x1, int y1, int c) {
    unsigned char col = resolve_color(c);
    int t;
    x0 -= cam_x; x1 -= cam_x; y0 -= cam_y; y1 -= cam_y;
    if (x0 > x1) { t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { t = y0; y0 = y1; y1 = t; }
    fill_clipped(x0, y0, x1, y0, col);
    if (y1 != y0) fill_clipped(x0, y1, x1, y1, col);
    if (y1 - y0 > 1) {
        fill_clipped(x0, y0 + 1, x0, y1 - 1, col);
        if (x1 != x0) fill_clipped(x1, y0 + 1, x1, y1 - 1, col);
    }
}

static void pset_raw(int x, int y, unsigned char col) {
    if (x < 0 || x > 127 || y < 0 || y > 127) return;
    enter_cpu_mode();
    vram[((unsigned int)y << 7) | (unsigned int)x] = col;
}

void gt_p8_pset(int x, int y, int c) {
    pset_raw(x - cam_x, y - cam_y, resolve_color(c));
}

void gt_p8_line(int x0, int y0, int x1, int y1, int c) {
    unsigned char col = resolve_color(c);
    int dx, dy, sx, sy, e2, errv;
    x0 -= cam_x; y0 -= cam_y; x1 -= cam_x; y1 -= cam_y;
    /* axis-aligned lines are cheap blitter fills */
    if (y0 == y1) { fill_clipped(x0, y0, x1, y1, col); return; }
    if (x0 == x1) { fill_clipped(x0, y0, x1, y1, col); return; }
    dx = gt_absi(x1 - x0);
    dy = -gt_absi(y1 - y0);
    sx = x0 < x1 ? 1 : -1;
    sy = y0 < y1 ? 1 : -1;
    errv = dx + dy;
    for (;;) {
        pset_raw(x0, y0, col);
        if (x0 == x1 && y0 == y1) break;
        e2 = errv << 1;
        if (e2 >= dy) { errv += dy; x0 += sx; }
        if (e2 <= dx) { errv += dx; y0 += sy; }
    }
}

void gt_p8_circfill(int cx, int cy, int r, int c) {
    unsigned char col = resolve_color(c);
    int x, y, d;
    cx -= cam_x; cy -= cam_y;
    if (r < 0) return;
    if (r == 0) { pset_raw(cx, cy, col); return; }
    /* midpoint circle -> two horizontal spans per step pair */
    x = r; y = 0; d = 1 - r;
    while (y <= x) {
        fill_clipped(cx - x, cy + y, cx + x, cy + y, col);
        if (y != 0) fill_clipped(cx - x, cy - y, cx + x, cy - y, col);
        if (d < 0) {
            d += (y << 1) + 3;
        } else {
            if (x != y) {
                fill_clipped(cx - y, cy + x, cx + y, cy + x, col);
                fill_clipped(cx - y, cy - x, cx + y, cy - x, col);
            }
            d += ((y - x) << 1) + 5;
            --x;
        }
        ++y;
    }
}

void gt_p8_circ(int cx, int cy, int r, int c) {
    unsigned char col = resolve_color(c);
    int x, y, d;
    cx -= cam_x; cy -= cam_y;
    if (r < 0) return;
    if (r == 0) { pset_raw(cx, cy, col); return; }
    x = r; y = 0; d = 1 - r;
    while (y <= x) {
        pset_raw(cx + x, cy + y, col); pset_raw(cx - x, cy + y, col);
        pset_raw(cx + x, cy - y, col); pset_raw(cx - x, cy - y, col);
        pset_raw(cx + y, cy + x, col); pset_raw(cx - y, cy + x, col);
        pset_raw(cx + y, cy - x, col); pset_raw(cx - y, cy - x, col);
        if (d < 0) d += (y << 1) + 3;
        else { d += ((y - x) << 1) + 5; --x; }
        ++y;
    }
}

void gt_p8_border(int c) {
    /* fill the overscan ring (visible area is x 1..126, y 7..119) */
    unsigned char col = resolve_color(c);
    fill_clipped(0, 0, 127, 6, col);
    fill_clipped(0, 120, 127, 127, col);
    fill_clipped(0, 7, 0, 119, col);
    fill_clipped(127, 7, 127, 119, col);
}

/* ---- input: latch + two reads per pad (active-low), per the C SDK ---- */

static unsigned int pad_now[2], pad_prev[2], pad_rpt[2];
static unsigned char hold_cnt[2][8];

/* P8 button index -> mask bit in the assembled pad word */
static const unsigned int btn_mask[8] = {
    512, 256, 2056, 1028,   /* left right up down */
    16, 4096, 8192, 32,     /* O(GT A)  X(GT B)  GT C  START */
};

#define GT_INPUT_ALL (512|256|2056|1028|16|4096|8192|32)

#pragma optimize (push, off)
static unsigned int read_pad(unsigned char which) {
    char lo, hi;
    if (which == 0) {
        lo = *gamepad_2;              /* reset the select line */
        lo = *gamepad_1;
        hi = *gamepad_1;
    } else {
        lo = *gamepad_2;
        hi = *gamepad_2;
    }
    return (unsigned int)(~((((int)hi) << 8) | (lo & 0xFF))) & GT_INPUT_ALL;
}
#pragma optimize (pop)

void gt_update_inputs(void) {
    unsigned char pl, b;
    unsigned char rpt_start, rpt_every;
    /* P8 btnp auto-repeat: 15 frames then every 4 at 30fps; doubled at 60 */
    if (fps30) { rpt_start = 15; rpt_every = 4; }
    else { rpt_start = 30; rpt_every = 8; }
    pad_prev[0] = pad_now[0];
    pad_now[0] = read_pad(0);
    pad_prev[1] = pad_now[1];
    pad_now[1] = read_pad(1);
    for (pl = 0; pl < 2; ++pl) {
        unsigned int rpt = 0;
        for (b = 0; b < 8; ++b) {
            if (pad_now[pl] & btn_mask[b]) {
                unsigned char n = ++hold_cnt[pl][b];
                if (n == 1) rpt |= btn_mask[b];
                else if (n > rpt_start && ((n - rpt_start - 1) % rpt_every) == 0) rpt |= btn_mask[b];
                if (n == 255) hold_cnt[pl][b] = rpt_start + 1; /* avoid wrap-to-fresh */
            } else {
                hold_cnt[pl][b] = 0;
            }
        }
        pad_rpt[pl] = rpt;
    }
}

unsigned char gt_p8_btn(int i, int pl) {
    if (i < 0 || i > 7) return 0;
    return (pad_now[pl & 1] & btn_mask[i]) != 0;
}

unsigned char gt_p8_btnp(int i, int pl) {
    if (i < 0 || i > 7) return 0;
    return (pad_rpt[pl & 1] & btn_mask[i]) != 0;
}

/* ---- lifecycle ---- */

static void await_vsync(void) {
    gt_frameflag = 1;
    while (gt_frameflag) {}
}

static void flip_pages(void) {
    frameflip ^= DMA_PAGE_OUT;
    bankflip ^= BANK_SECOND_FRAMEBUFFER;
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_OPAQUE | DMA_GCARRY | frameflip;
    *dma_flags = flags_mirror;
    banks_mirror = bankflip;
    *bank_reg = banks_mirror;
    draw_mode = MODE_NONE;
}

void gt_p8_fps30(void) { fps30 = 1; }

void gt_init(void) {
    unsigned char i;
    gt_frameflag = 0;
    gt_draw_busy = 0;
    gt_ticks = 0;
    frameflip = 0;
    bankflip = BANK_SECOND_FRAMEBUFFER;
    fps30 = 0;
    cam_x = 0; cam_y = 0;
    draw_mode = MODE_NONE;
    for (i = 0; i < 16; ++i) p8pal[i] = p8pal_rom[i];
    draw_color = p8pal[6];             /* P8 default draw color: 6 */
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ;
    *dma_flags = flags_mirror;
    banks_mirror = bankflip;
    *bank_reg = banks_mirror;
    __asm__("CLI");
    /* power-on VRAM is noise: clear both pages so frame 0 is deterministic */
    gt_p8_cls(0);
    await_drawing();
    flip_pages();
    gt_p8_cls(0);
    await_drawing();
    flip_pages();
}

void gt_endframe(void) {
    await_drawing();
    await_vsync();
    flip_pages();
    gt_time_tick();
    if (fps30) {                 /* 30fps mode: burn the second vsync */
        await_vsync();
        gt_time_tick();
    }
}
