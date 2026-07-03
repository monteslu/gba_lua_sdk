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
#include "gt_font.h"

char gt_frameflag;
char gt_draw_busy;
unsigned int gt_ticks;

/* per-frame hook: null unless gt_music_init() installs the sfx/music
 * sequencer. Lets gt_endframe() advance audio without hard-linking
 * gt_music.o into games that never call sfx()/music(). */
void (*gt_frame_hook)(void) = 0;

char flags_mirror;          /* last value written to $2007 (bg reads it) */
char banks_mirror;          /* last value written to $2005 (bg reads it) */
char frameflip;             /* DMA_PAGE_OUT bit state */
char bankflip;              /* BANK_SECOND_FRAMEBUFFER bit state */
static char fps30;          /* _update() mode: two vsyncs per logical frame */

/* draw state (PICO-8 sticky globals; camera lives in zp — gt_blitq.s) */
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

/* p8 index (0-15) -> current hardware color byte (honors pal() remaps).
 * Exposed for the background compositor (gt_bg.c decodes 4bpp sheet tiles). */
unsigned char gt_p8pal(unsigned char idx) {
    return p8pal[idx & 15];
}

/* ---- mode tracking: CPU->VRAM / GRAM writes vs queued blits ----
 * Blits carry their own dma_flags byte in their queue entry (gt_blitq.s),
 * so there is no blit "mode" any more — only the CPU-write modes need the
 * flags register held stable, and any enqueue invalidates them. */
#define MODE_NONE 0
#define MODE_CPU  2
#define MODE_GRAM 3
char gt_draw_mode;

/* dma_flags bytes carried in queue entries */
#define QF_RECT (DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_COLORFILL_ENABLE | DMA_OPAQUE)
#define QF_SPR  (DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_GCARRY)

static void await_drawing(void) {
    __asm__("CLI");
    /* drain: keep pumping until the queue is empty and the blit finished */
    while (gt_qhead != gt_qtail) gt_q_pump();
    while (gt_draw_busy) {}
    /* Touch the VDMA bus once after the drain. The emulator materializes
     * blit pixels lazily using the LIVE dma/bank registers; without this
     * read, the frame's final blits can land after a page flip or mode
     * change and stamp the wrong page (visible as flicker). A read forces
     * the catch-up under the still-current state. Harmless on hardware. */
    (void)*((volatile unsigned char *)0x4000);
}

/* Producers stage an entry with 8 zero-page stores and call gt_q_push()
 * (asm: commit + pump). No C-stack arguments anywhere on this path — the
 * measured cost of queueing a blit is the stores + one JSR. */
#define Q_COMMIT() (gt_draw_mode = MODE_NONE, gt_q_push())

static void enter_cpu_mode(void) {
    if (gt_draw_mode == MODE_CPU) return;
    await_drawing();
    flags_mirror = DMA_NMI | DMA_CPU_TO_VRAM;   /* DMA off: CPU owns VRAM */
    *dma_flags = flags_mirror;
    banks_mirror = bankflip;                    /* write the DRAW page */
    *bank_reg = banks_mirror;
    gt_draw_mode = MODE_CPU;
}

/* GRAM CPU-write mode: dummy clipped 1x1 blit latches sheet quadrant 0,
 * then DMA off routes CPU writes into GRAM (hardware ref 3.4). */
static void enter_gram_mode(void) {
    if (gt_draw_mode == MODE_GRAM) return;
    await_drawing();
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_GCARRY;
    *dma_flags = flags_mirror;
    banks_mirror = bankflip | BANK_CLIP_X | BANK_CLIP_Y;
    *bank_reg = banks_mirror;
    vram[GX] = 0;
    vram[GY] = 0;
    vram[VX] = 200;              /* offscreen + clip: no visible pixel */
    vram[VY] = 200;
    vram[WIDTH] = 1;
    vram[HEIGHT] = 1;
    gt_draw_busy = 1;
    vram[START] = 1;
    await_drawing();
    flags_mirror = DMA_NMI;      /* DMA off, CPU_TO_VRAM off -> GRAM writes */
    *dma_flags = flags_mirror;
    gt_draw_mode = MODE_GRAM;
}

/* framebuffer row start addresses (ROM table: vram is fixed at $4000) */
#define VR(n) (unsigned char *)(0x4000 + ((n) << 7))
#define VR8(n) VR(n), VR(n+1), VR(n+2), VR(n+3), VR(n+4), VR(n+5), VR(n+6), VR(n+7)
static unsigned char *const vram_row[128] = {
    VR8(0),   VR8(8),   VR8(16),  VR8(24),  VR8(32),  VR8(40),  VR8(48),  VR8(56),
    VR8(64),  VR8(72),  VR8(80),  VR8(88),  VR8(96),  VR8(104), VR8(112), VR8(120),
};

/* print: 3x5 glyphs via CPU writes; returns the x after the last glyph
 * (the PICO-8 width-measuring idiom). Fully-visible glyphs take a fast
 * row-pointer walk; edge glyphs fall back to per-pixel clipping. */
int gt_p8_print(const char *str, int x, int y, int c) {
    unsigned char col = resolve_color(c);
    unsigned char row, bits;
    const unsigned char *g;
    unsigned char *p;
    x -= gt_cam_x;
    y -= gt_cam_y;
    enter_cpu_mode();
    while (*str) {
        g = gt_font[gt_glyph(*str)];
        if (x >= 0 && x <= 125 && y >= 0 && y <= 123) {
            /* fast path: the whole 3x5 glyph is on screen */
            p = vram_row[(unsigned char)y] + x;
            for (row = 0; row < 5; ++row) {
                bits = g[row];
                if (bits & 4) p[0] = col;
                if (bits & 2) p[1] = col;
                if (bits & 1) p[2] = col;
                p += 128;
            }
        } else if (x >= -2 && x <= 127 && y >= -4 && y <= 127) {
            for (row = 0; row < 5; ++row) {
                int py = y + row;
                if (py < 0 || py > 127) continue;
                bits = g[row];
                if ((bits & 4) && x >= 0 && x <= 127) vram_row[py][x] = col;
                if ((bits & 2) && x + 1 >= 0 && x + 1 <= 127) vram_row[py][x + 1] = col;
                if ((bits & 1) && x + 2 >= 0 && x + 2 <= 127) vram_row[py][x + 2] = col;
            }
        }
        x += 4;
        ++str;
    }
    return x + gt_cam_x;
}

/* print a 16.16 number: integer part (P8 prints integers bare) */
int gt_p8_print_num(long v, int x, int y, int c) {
    char buf[8];
    char *p = buf + 7;
    int iv = (int)(v >> 16);
    unsigned int uv;
    unsigned char neg = 0;
    *p = 0;
    if (iv < 0) { neg = 1; uv = (unsigned int)(-iv); } else uv = (unsigned int)iv;
    do { *--p = '0' + (uv % 10); uv /= 10; } while (uv);
    if (neg) *--p = '-';
    return gt_p8_print(p, x, y, c);
}

/* The packed sheet pointer, stashed by gt_sheet_load so the background
 * compositor (gt_bg.c) can re-read tile pixels from it. In FLASH2M builds the
 * sheet lives in bank 2, mapped in by gt_sheet_init before gt_sheet_load runs;
 * gt_bg_compose re-maps that bank the same way before reading. NULL until a
 * sheet is loaded (bg_compose is a no-op then). */
const unsigned char *gt_sheet_ptr;

/* Load a packed 4bpp PICO-8 sheet (8192 bytes, two pixels per byte, low
 * nibble first) into GRAM through the palette map. Called by the generated
 * gt_sheet_init() before _init() when the build links a --sheet. */
void gt_sheet_load(const unsigned char *packed) {
    unsigned int i;
    unsigned char b;
    gt_sheet_ptr = packed;
    enter_gram_mode();
    for (i = 0; i < 8192; ++i) {
        b = packed[i];
        vram[i << 1] = p8pal[b & 15];
        vram[(i << 1) | 1] = p8pal[b >> 4];
    }
}

/* PICO-8 sset: plot into the 128x128 sprite sheet (GRAM quadrant 0) */
void gt_p8_sset_z(void) {
    unsigned char col = resolve_color(gt_a2);
    int x = gt_a0, y = gt_a1;
    if (x < 0 || x > 127 || y < 0 || y > 127) return;
    enter_gram_mode();
    vram[((unsigned int)y << 7) | (unsigned int)x] = col;
}

void gt_p8_sset(int x, int y, int c) {
    gt_a0 = x; gt_a1 = y; gt_a2 = c;
    gt_p8_sset_z();
}

/* PICO-8 spr: blit sprite cell n (8x8, 16 per row) with transparency.
 * The hot path lives in asm (gt_blitq.s _gt_p8_spr_z): camera-adjust,
 * offscreen reject, stage a QF_SPR entry, pump. This is the cdecl shim. */
void gt_p8_spr(int n, int x, int y, int w, int h, int flip) {
    gt_a0 = n; gt_a1 = x; gt_a2 = y; gt_a3 = w; gt_a4 = h;
    gt_a5 = flip;                       /* bit0 = flip X, bit1 = flip Y */
    gt_p8_spr_z();
}

/* current fill color for the argless draw-core hot path (staging out, no
 * cc65 arg-push). Set by callers before box_raw/hspan_raw/fill_clipped_z. */
static unsigned char fc_col;

/* raw fill; caller guarantees 0<=x,y<=127, 1<=w,h<=127 (after clipping) */
static void box_raw(unsigned char x, unsigned char y,
                    unsigned char w, unsigned char h, unsigned char color) {
    gt_ent[0] = QF_RECT;
    gt_ent[1] = x;
    gt_ent[2] = y;
    gt_ent[3] = 0;
    gt_ent[4] = 0;
    gt_ent[5] = w;
    gt_ent[6] = h;
    gt_ent[7] = (unsigned char)~color;
    Q_COMMIT();
}

/* Lean single-scanline horizontal span at height 1, x0..x1 inclusive, in
 * fc_col. This is the hot inner primitive for circfill/circ/line: those
 * callers guarantee x0<=x1 and a span never 128 wide (r<=63), so it skips
 * fill_clipped_z's int-swap, both-axes-full, and 128-split logic — the exact
 * per-scanline overhead that made circfill blow the blit budget. Off-screen
 * rows are rejected whole; partial rows clip to [0,127]. Coords are int so a
 * negative x0/large x1 clamps correctly before narrowing to the 7-bit blit. */
static void hspan_raw(int x0, int x1, int y) {
    if (y < 0 || y > 127 || x1 < 0 || x0 > 127) return;
    if (x0 < 0) x0 = 0;
    if (x1 > 127) x1 = 127;
    gt_ent[0] = QF_RECT;
    gt_ent[1] = (unsigned char)x0;
    gt_ent[2] = (unsigned char)y;
    gt_ent[3] = 0;
    gt_ent[4] = 0;
    gt_ent[5] = (unsigned char)(x1 - x0 + 1);
    gt_ent[6] = 1;
    gt_ent[7] = (unsigned char)~fc_col;
    Q_COMMIT();
}

/* clipped fill in screen coords: corners in gt_a0..gt_a3 (inclusive, camera
 * already applied), color in fc_col. Argless — the draw core's hot path has
 * no cc65 arg-push anywhere: zp in, staging out. Clobbers gt_a0..a3. */
static void fill_clipped_z(void) {
    int t;
    /* Hot fast path: all four corners already on-screen and ordered, and
     * neither span the full 128 (the common case for game rects — camera-
     * adjusted sprites/HUD boxes that aren't clipping a screen edge or filling
     * the whole axis). Skips the four int range-clamps and both 128-span
     * splits below, staging in one shot. `(unsigned)v <= 127` folds the >=0
     * and <=127 tests into one branch. A full-128 span (width/height == 128,
     * which the 7-bit counter can't encode) fails `gt_a2 - gt_a0 < 127` and
     * falls through to the slow path that splits it. */
    if ((unsigned)gt_a0 <= 127 && (unsigned)gt_a1 <= 127 &&
        (unsigned)gt_a2 <= 127 && (unsigned)gt_a3 <= 127 &&
        gt_a0 <= gt_a2 && gt_a1 <= gt_a3 &&
        gt_a2 - gt_a0 < 127 && gt_a3 - gt_a1 < 127) {
        gt_ent[0] = QF_RECT;
        gt_ent[1] = (unsigned char)gt_a0;
        gt_ent[2] = (unsigned char)gt_a1;
        gt_ent[3] = 0;
        gt_ent[4] = 0;
        gt_ent[5] = (unsigned char)(gt_a2 - gt_a0 + 1);
        gt_ent[6] = (unsigned char)(gt_a3 - gt_a1 + 1);
        gt_ent[7] = (unsigned char)~fc_col;
        Q_COMMIT();
        return;
    }
    if (gt_a0 > gt_a2) { t = gt_a0; gt_a0 = gt_a2; gt_a2 = t; }
    if (gt_a1 > gt_a3) { t = gt_a1; gt_a1 = gt_a3; gt_a3 = t; }
    if (gt_a2 < 0 || gt_a3 < 0 || gt_a0 > 127 || gt_a1 > 127) return;
    if (gt_a0 < 0) gt_a0 = 0;
    if (gt_a1 < 0) gt_a1 = 0;
    if (gt_a2 > 127) gt_a2 = 127;
    if (gt_a3 > 127) gt_a3 = 127;
    /* full 128-wide/high spans need splitting (7-bit blit counters).
     * Both axes full (the 0,0,127,127 fill) = the 4-blit cls pattern. */
    if (gt_a2 - gt_a0 == 127 && gt_a3 - gt_a1 == 127) {
        unsigned char col = fc_col;
        box_raw(127, 0, 1, 127, col);
        box_raw(0, 127, 127, 1, col);
        box_raw(127, 127, 1, 1, col);
        box_raw(0, 0, 127, 127, col);
        return;
    }
    if (gt_a2 - gt_a0 == 127) {          /* width 128, height <=127 */
        gt_ent[0] = QF_RECT;
        gt_ent[1] = 127;
        gt_ent[2] = (unsigned char)gt_a1;
        gt_ent[3] = 0;
        gt_ent[4] = 0;
        gt_ent[5] = 1;
        gt_ent[6] = (unsigned char)(gt_a3 - gt_a1 + 1);
        gt_ent[7] = (unsigned char)~fc_col;
        Q_COMMIT();
        gt_a2 = 126;
    }
    if (gt_a3 - gt_a1 == 127) {          /* height 128, width <=127 */
        gt_ent[0] = QF_RECT;
        gt_ent[1] = (unsigned char)gt_a0;
        gt_ent[2] = 127;
        gt_ent[3] = 0;
        gt_ent[4] = 0;
        gt_ent[5] = (unsigned char)(gt_a2 - gt_a0 + 1);
        gt_ent[6] = 1;
        gt_ent[7] = (unsigned char)~fc_col;
        Q_COMMIT();
        gt_a3 = 126;
    }
    gt_ent[0] = QF_RECT;
    gt_ent[1] = (unsigned char)gt_a0;
    gt_ent[2] = (unsigned char)gt_a1;
    gt_ent[3] = 0;
    gt_ent[4] = 0;
    gt_ent[5] = (unsigned char)(gt_a2 - gt_a0 + 1);
    gt_ent[6] = (unsigned char)(gt_a3 - gt_a1 + 1);
    gt_ent[7] = (unsigned char)~fc_col;
    Q_COMMIT();
}

/* cdecl shim for the cold callers (border, line's axis fast path) */
static void fill_clipped(int x0, int y0, int x1, int y1, unsigned char color) {
    gt_a0 = x0; gt_a1 = y0; gt_a2 = x1; gt_a3 = y1; fc_col = color;
    fill_clipped_z();
}

/* ---- PICO-8 drawing API ---- */

void gt_p8_cls(int c) {
    /* Edge slivers first, the big 127x127 blit LAST: the caller returns
     * while the big DMA is still in flight, so a cls() at the top of
     * _update() overlaps the whole frame's game logic. */
    unsigned char col = (c < 0) ? p8pal[0] : resolve_color(c);
    box_raw(127, 0, 1, 127, col);
    box_raw(0, 127, 127, 1, col);
    box_raw(127, 127, 1, 1, col);
    box_raw(0, 0, 127, 127, col);
}

void gt_p8_camera(int x, int y) { gt_cam_x = x; gt_cam_y = y; }
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

void gt_p8_rectfill_z(void) {
    fc_col = resolve_color(gt_a4);
    gt_a0 -= gt_cam_x;
    gt_a1 -= gt_cam_y;
    gt_a2 -= gt_cam_x;
    gt_a3 -= gt_cam_y;
    fill_clipped_z();
}

void gt_p8_rectfill(int x0, int y0, int x1, int y1, int c) {
    gt_a0 = x0; gt_a1 = y0; gt_a2 = x1; gt_a3 = y1; gt_a4 = c;
    gt_p8_rectfill_z();
}

void gt_p8_rect_z(void) {
    int x0, y0, x1, y1, t;
    fc_col = resolve_color(gt_a4);
    x0 = gt_a0 - gt_cam_x; x1 = gt_a2 - gt_cam_x;
    y0 = gt_a1 - gt_cam_y; y1 = gt_a3 - gt_cam_y;
    if (x0 > x1) { t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { t = y0; y0 = y1; y1 = t; }
    gt_a0 = x0; gt_a1 = y0; gt_a2 = x1; gt_a3 = y0; fill_clipped_z();
    if (y1 != y0) { gt_a0 = x0; gt_a1 = y1; gt_a2 = x1; gt_a3 = y1; fill_clipped_z(); }
    if (y1 - y0 > 1) {
        gt_a0 = x0; gt_a1 = y0 + 1; gt_a2 = x0; gt_a3 = y1 - 1; fill_clipped_z();
        if (x1 != x0) { gt_a0 = x1; gt_a1 = y0 + 1; gt_a2 = x1; gt_a3 = y1 - 1; fill_clipped_z(); }
    }
}

void gt_p8_rect(int x0, int y0, int x1, int y1, int c) {
    gt_a0 = x0; gt_a1 = y0; gt_a2 = x1; gt_a3 = y1; gt_a4 = c;
    gt_p8_rect_z();
}

static void pset_raw(int x, int y, unsigned char col) {
    if (x < 0 || x > 127 || y < 0 || y > 127) return;
    enter_cpu_mode();
    vram_row[(unsigned char)y][(unsigned char)x] = col;
}

void gt_p8_pset_z(void) {
    pset_raw(gt_a0 - gt_cam_x, gt_a1 - gt_cam_y, resolve_color(gt_a2));
}

void gt_p8_pset(int x, int y, int c) {
    gt_a0 = x; gt_a1 = y; gt_a2 = c;
    gt_p8_pset_z();
}

/* ---- parallax starfield ----------------------------------------------------
 * A stock scrolling-starfield primitive. Ports that draw a full-screen field
 * of drifting stars (shmups, space games) would otherwise pay ~1000 cycles of
 * cc65 call overhead PER star per frame calling pset() from the game loop; the
 * whole field here lives in one tight C loop each for move and draw — the
 * measured difference is well over a vsync on a 100-star field, the gap
 * between "3 fps" and "30 fps" for a bullet-hell port.
 *
 * State (positions in whole pixels x, 1/16-pixel y, speed in 16ths/frame):
 *   x  in [0,127], y in [0,2047] (=127.9 px), speed in [8,31] (0.5..~2 px).
 * Colour is by speed tier (the canonical near/mid/far parallax look):
 *   speed <16 -> p8 col 1, <24 -> 13, else 6.
 * move(mode): 0 = quarter+eighth drift (~0.375 px), 1 = 1x, 2 = 2x. */
#define GT_STARS_MAX 128
/* Split-Y representation so the hot DRAW loop needs NO shift: the pixel row is
 * stored directly (star_row 0..127) and the sub-pixel accumulator (star_frac,
 * 16ths) carries into it during move(). Everything is a byte -> the whole loop
 * is 8-bit indexed, no cc65 asrax4/16-bit-pointer math per star. */
static unsigned char star_x[GT_STARS_MAX];   /* column 0..127 */
static unsigned char star_row[GT_STARS_MAX]; /* pixel row 0..127 */
static unsigned char star_frac[GT_STARS_MAX];/* sub-row, 0..15 (16ths) */
static unsigned char star_s[GT_STARS_MAX];   /* speed 8..31 (16ths/frame) */
static unsigned char star_col[GT_STARS_MAX]; /* precomputed colour byte */
static unsigned char star_n;

void gt_starfield_init(int n) {
    unsigned char i, s;
    if (n > GT_STARS_MAX) n = GT_STARS_MAX;
    star_n = (unsigned char)n;
    for (i = 0; i < star_n; ++i) {
        star_x[i]    = (unsigned char)(gt_p8_rnd(128L << 16) >> 16);
        star_row[i]  = (unsigned char)(gt_p8_rnd(128L << 16) >> 16);
        star_frac[i] = 0;
        s = (unsigned char)(8 + (gt_p8_rnd(24L << 16) >> 16));
        star_s[i]    = s;
        /* colour by speed tier, baked once (pset colour never changes) */
        star_col[i]  = (s < 16) ? p8pal[1] : (s < 24) ? p8pal[13] : p8pal[6];
    }
}

/* advance the field. `step` is the 16ths added per star this frame; the caller
 * passes it once, so the per-star loop is a plain byte add + carry. */
static void starfield_advance(unsigned char step_shift, unsigned char dbl) {
    unsigned char i, f, r, adv;
    for (i = 0; i < star_n; ++i) {
        adv = star_s[i];
        if (dbl) adv <<= 1;
        else if (step_shift) adv = (adv >> 2) + (adv >> 3); /* ~0.375x drift */
        f = star_frac[i] + adv;
        r = star_row[i] + (f >> 4);
        f &= 15;
        if (r > 127) r -= 128;
        star_frac[i] = f;
        star_row[i]  = r;
    }
}

void gt_starfield_move(int mode) {
    if (mode == 2)      starfield_advance(0, 1);
    else if (mode == 1) starfield_advance(0, 0);
    else                starfield_advance(1, 0);
}

void gt_starfield_draw(void) {
    unsigned char i;
    enter_cpu_mode();
    for (i = 0; i < star_n; ++i) {
        vram_row[star_row[i]][star_x[i]] = star_col[i];
    }
}

void gt_p8_line_z(void) {
    unsigned char col = resolve_color(gt_a4);
    int x0, y0, x1, y1, dx, dy, sx, sy, e2, errv;
    x0 = gt_a0 - gt_cam_x; y0 = gt_a1 - gt_cam_y;
    x1 = gt_a2 - gt_cam_x; y1 = gt_a3 - gt_cam_y;
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

void gt_p8_line(int x0, int y0, int x1, int y1, int c) {
    gt_a0 = x0; gt_a1 = y0; gt_a2 = x1; gt_a3 = y1; gt_a4 = c;
    gt_p8_line_z();
}

void gt_p8_circfill_z(void) {
    unsigned char col = resolve_color(gt_a3);
    int cx, cy, r, x, y, d;
    cx = gt_a0 - gt_cam_x; cy = gt_a1 - gt_cam_y;
    r = gt_a2;
    if (r < 0) return;
    if (r == 0) { pset_raw(cx, cy, col); return; }
    fc_col = col;
    /* midpoint circle -> two horizontal spans per step pair. Each scanline
     * goes through the lean hspan_raw (spans are pre-ordered and <128 wide),
     * not the full fill_clipped_z — this is what keeps circfill in budget. */
    x = r; y = 0; d = 1 - r;
    while (y <= x) {
        hspan_raw(cx - x, cx + x, cy + y);
        if (y != 0) hspan_raw(cx - x, cx + x, cy - y);
        if (d < 0) {
            d += (y << 1) + 3;
        } else {
            if (x != y) {
                hspan_raw(cx - y, cx + y, cy + x);
                hspan_raw(cx - y, cx + y, cy - x);
            }
            d += ((y - x) << 1) + 5;
            --x;
        }
        ++y;
    }
}

void gt_p8_circfill(int cx, int cy, int r, int c) {
    gt_a0 = cx; gt_a1 = cy; gt_a2 = r; gt_a3 = c;
    gt_p8_circfill_z();
}

void gt_p8_circ_z(void) {
    unsigned char col = resolve_color(gt_a3);
    int cx, cy, r, x, y, d;
    cx = gt_a0 - gt_cam_x; cy = gt_a1 - gt_cam_y;
    r = gt_a2;
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

void gt_p8_circ(int cx, int cy, int r, int c) {
    gt_a0 = cx; gt_a1 = cy; gt_a2 = r; gt_a3 = c;
    gt_p8_circ_z();
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

/* held/newpress words live in zp (gt_blitq.s) so btn()/btnp() with constant
 * arguments compile to inline bit tests — no call at all. */
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

static unsigned int rpt_of(unsigned char pl, unsigned int now,
                           unsigned char rpt_start, unsigned char rpt_every) {
    unsigned char b;
    unsigned int rpt = 0;
    for (b = 0; b < 8; ++b) {
        if (now & btn_mask[b]) {
            unsigned char n = ++hold_cnt[pl][b];
            if (n == 1) rpt |= btn_mask[b];
            else if (n > rpt_start && ((n - rpt_start - 1) % rpt_every) == 0) rpt |= btn_mask[b];
            if (n == 255) hold_cnt[pl][b] = rpt_start + 1; /* avoid wrap-to-fresh */
        } else {
            hold_cnt[pl][b] = 0;
        }
    }
    return rpt;
}

void gt_update_inputs(void) {
    unsigned char rpt_start, rpt_every;
    /* P8 btnp auto-repeat: 15 frames then every 4 at 30fps; doubled at 60 */
    if (fps30) { rpt_start = 15; rpt_every = 4; }
    else { rpt_start = 30; rpt_every = 8; }
    gt_pad0 = read_pad(0);
    gt_pad1 = read_pad(1);
    gt_rpt0 = rpt_of(0, gt_pad0, rpt_start, rpt_every);
    gt_rpt1 = rpt_of(1, gt_pad1, rpt_start, rpt_every);
}

unsigned char gt_p8_btn(int i, int pl) {
    if (i < 0 || i > 7) return 0;
    return ((pl & 1 ? gt_pad1 : gt_pad0) & btn_mask[i]) != 0;
}

unsigned char gt_p8_btnp(int i, int pl) {
    if (i < 0 || i > 7) return 0;
    return ((pl & 1 ? gt_rpt1 : gt_rpt0) & btn_mask[i]) != 0;
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
    gt_qbank = bankflip | BANK_CLIP_X | BANK_CLIP_Y;  /* next frame's blits */
    gt_draw_mode = MODE_NONE;
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
    gt_cam_x = 0; gt_cam_y = 0;
    gt_qhead = 0; gt_qtail = 0;
    gt_qbank = bankflip | BANK_CLIP_X | BANK_CLIP_Y;
    gt_pad0 = 0; gt_pad1 = 0; gt_rpt0 = 0; gt_rpt1 = 0;
    gt_draw_mode = MODE_NONE;
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
    if (gt_frame_hook) gt_frame_hook();     /* advance sfx/music (60 Hz base) */
    if (fps30) {                 /* 30fps mode: burn the second vsync */
        await_vsync();
        gt_time_tick();
        if (gt_frame_hook) gt_frame_hook(); /* keep music at 60 Hz in 30fps mode */
    }
}
