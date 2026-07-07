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
/* the 210 B glyph table rides in bank 2 with its uploader; the rare CPU
 * glyph path (edge clips / 9th color) maps the bank around its reads */
#ifdef GT_BANKED
extern unsigned char gt_cur_bank;   /* live $8000-window bank (gt_bank.s) */
/* the relief bank: cold SDK bodies that default to bank 0 move to bank 2
 * when the placement ladder sets GT_INPUT_B2 (b0-critical carts) */
#ifdef GT_INPUT_B2
#define GT_RELIEF_BANK 2
#else
#define GT_RELIEF_BANK 0
#endif
#pragma rodata-name ("B0RODATA")
#endif
#include "gt_font.h"
#ifdef GT_BANKED
#pragma rodata-name ("RODATA")
#endif

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
unsigned char draw_color;          /* resolved GameTank byte (asm fast paths read/write) */

/* PICO-8 color 0-15 -> GameTank byte; pal() remaps this live table */
static const unsigned char p8pal_rom[16] = {
    0x00, 0xA9, 0x5A, 0xDB, 0x33, 0x03, 0x06, 0x07,
    0x5B, 0x3E, 0x1F, 0xFE, 0xBE, 0x8C, 0x5E, 0x2F,
};
unsigned char p8pal[16];           /* non-static: asm rectfill fast path indexes it */

/* resolve a color argument: -1 = current; 0x100|b = raw byte; else p8 index.
 * Giving a color also SETS the current color (P8 trailing-color rule). */
unsigned char resolve_color(int c) {
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

void await_drawing(void) {
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

void enter_cpu_mode(void) {
    if (gt_draw_mode == MODE_CPU) return;
    await_drawing();
    /* keep frameflip (PAGE_OUT): the video scans the page selected by the
     * LIVE $2007 — dropping the bit mid-frame points the display at the page
     * being DRAWN (flicker + half-drawn content on real hardware and any
     * scan-faithful emulator). Same rule for every $2007 write below. */
    flags_mirror = DMA_NMI | DMA_CPU_TO_VRAM | frameflip;
    *dma_flags = flags_mirror;
    banks_mirror = bankflip;                    /* write the DRAW page */
    *bank_reg = banks_mirror;
    gt_draw_mode = MODE_CPU;
}

/* GRAM CPU-write mode: dummy clipped 1x1 blit latches sheet quadrant 0,
 * then DMA off routes CPU writes into GRAM (hardware ref 3.4). */
/* FLASH2M: the GRAM-mode dance is cold (sset/sheet-load setup) — the body
 * rides bank 0; the fixed stub keeps it callable from any bank. */
#ifdef GT_BANKED
#pragma code-name ("B0CODE")
#define GT_ENTER_GRAM enter_gram_mode_impl
static void enter_gram_mode_impl(void);
#else
#define GT_ENTER_GRAM enter_gram_mode
#endif
#ifdef GT_BANKED
static
#endif
void GT_ENTER_GRAM(void) {
    if (gt_draw_mode == MODE_GRAM) return;
    await_drawing();
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_GCARRY | frameflip;
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
    flags_mirror = DMA_NMI | frameflip;  /* DMA off, CPU_TO_VRAM off -> GRAM writes */
    *dma_flags = flags_mirror;
    gt_draw_mode = MODE_GRAM;
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
static void enter_gram_mode(void) {
    unsigned char saved_bank;
    if (gt_draw_mode == MODE_GRAM) return;  /* fast path: no bank switch —
        a boot-time bake makes thousands of sset calls through here */
    saved_bank = gt_cur_bank;
    gt_bank(0);
    enter_gram_mode_impl();
    gt_bank(saved_bank);
}
#endif

/* framebuffer row start addresses (ROM table: vram is fixed at $4000) */
#define VR(n) (unsigned char *)(0x4000 + ((n) << 7))
#define VR8(n) VR(n), VR(n+1), VR(n+2), VR(n+3), VR(n+4), VR(n+5), VR(n+6), VR(n+7)
static unsigned char *const vram_row[128] = {
    VR8(0),   VR8(8),   VR8(16),  VR8(24),  VR8(32),  VR8(40),  VR8(48),  VR8(56),
    VR8(64),  VR8(72),  VR8(80),  VR8(88),  VR8(96),  VR8(104), VR8(112), VR8(120),
};

/* ---- blitter font ----------------------------------------------------------
 * Mid-draw print used to enter CPU mode, which drains every queued blit's
 * pixels first (~13k cycles with a chunk map in flight) — a three-group HUD
 * was the single biggest draw-side cost in the racing/shmup ports. Instead,
 * the 42-glyph font is rendered ONCE PER TEXT COLOR into GRAM group 2
 * quadrant 0 (42 glyphs x 3x5 at 4px pitch = 128x10 per color slot; 8 slots
 * = 80 of 128 rows), and print stages one colorkeyed copy blit per glyph —
 * no mode transition, hardware edge clipping for free. Color slots cache by
 * RESOLVED byte; a 9th color falls back to the CPU path.
 * The upload runs the same latch dance as the bg canvas (dummy blit selects
 * the quadrant for CPU GRAM writes) and preserves frameflip. */
#define FONT_GROUP 2
#define FONT_SLOTS 8
#ifndef GT_NO_BLITFONT
static unsigned char font_cols[FONT_SLOTS];
static unsigned char font_nslots = 0;

/* back to the queue-owned draw state (mirrors gt_bg.c's restore) */
static void bg_pipeline_restore(void) {
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_OPAQUE | DMA_GCARRY | frameflip;
    *dma_flags = flags_mirror;
    banks_mirror = bankflip;
    *bank_reg = banks_mirror;
    gt_qbank = bankflip | BANK_CLIP_X | BANK_CLIP_Y;
    gt_draw_mode = MODE_NONE;
}

/* FLASH2M: the upload body is cold (once per text color) — it rides in
 * bank 0 WITH the glyph table it reads; a fixed-bank stub banks + restores. */
#ifdef GT_BANKED
#pragma code-name ("B0CODE")
#define GT_FONT_UPLOAD font_upload_impl
#else
#define GT_FONT_UPLOAD font_upload
#endif
static void GT_FONT_UPLOAD(unsigned char slot, unsigned char col) {
    unsigned char gy, row, bits, cidx;
    unsigned int base;
    unsigned char gcount;
    await_drawing();
    /* latch GRAM group 2, quadrant 0 for CPU writes (dummy 1x1 clipped blit) */
    flags_mirror = DMA_NMI | DMA_ENABLE | DMA_IRQ | DMA_GCARRY | frameflip;
    *dma_flags = flags_mirror;
    *bank_reg = bankflip | FONT_GROUP | BANK_CLIP_X | BANK_CLIP_Y;
    vram[GX] = 0; vram[GY] = 0;
    vram[VX] = 200; vram[VY] = 200;
    vram[WIDTH] = 1; vram[HEIGHT] = 1;
    gt_draw_busy = 1;
    vram[START] = 1;
    await_drawing();
    flags_mirror = DMA_NMI | frameflip;      /* GRAM write mode */
    *dma_flags = flags_mirror;
    /* paint the slot's 10 rows: glyph g at x=(g%32)*4, y=slot*10+(g/32)*5 */
    for (gcount = 0; gcount < 42; ++gcount) {
        const unsigned char *g = gt_font[gcount];
        base = ((unsigned int)(slot * 10 + (gcount / 32) * 5) << 7)
             + (gcount % 32) * 4;
        for (row = 0; row < 5; ++row) {
            bits = g[row];
            cidx = (unsigned char)(bits & 4 ? col : 0);
            vram[base] = cidx;
            vram[base + 1] = (unsigned char)(bits & 2 ? col : 0);
            vram[base + 2] = (unsigned char)(bits & 1 ? col : 0);
            vram[base + 3] = 0;
            base += 128;
        }
    }
    bg_pipeline_restore();
    font_cols[slot] = col;
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
static void font_upload(unsigned char slot, unsigned char col) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(0);                  /* the glyph table rides bank 0 */
    font_upload_impl(slot, col);
    gt_bank(saved_bank);
}
#endif
#endif /* !GT_NO_BLITFONT */

#ifdef GT_BANKED
#pragma code-name ("B0CODE")
#endif
static unsigned char gt_glyph(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'z') return 10 + ch - 'a';
    if (ch >= 'A' && ch <= 'Z') return 10 + ch - 'A';
    switch (ch) {
        case '!': return 37;
        case '-': return 38;
        case ':': return 39;
        case '.': return 40;
        case '/': return 41;
        default: return 36;   /* space */
    }
}

static signed char font_slot(unsigned char col) {
#ifdef GT_NO_BLITFONT
    (void)col;
    return -1;                  /* every print takes the CPU glyph path */
#else
    unsigned char i;
    for (i = 0; i < font_nslots; ++i) {
        if (font_cols[i] == col) return (signed char)i;
    }
    if (font_nslots >= FONT_SLOTS) return -1;
    i = font_nslots++;
    font_upload(i, col);
    return (signed char)i;
#endif
}

/* print: 3x5 glyphs via CPU writes; returns the x after the last glyph
 * (the PICO-8 width-measuring idiom). Fully-visible glyphs take a fast
 * row-pointer walk; edge glyphs fall back to per-pixel clipping. */
/* per-pixel clipped glyph (CPU mode entered by the caller). Shared by the
 * edge-glyph case and the >8-colors fallback — one body, fixed-bank space
 * is scarce. */
void glyph_cpu(unsigned char gn, int x, int y, unsigned char col) {
    unsigned char rows[5];
    unsigned char row, bits;
    {
#ifdef GT_BANKED
        unsigned char saved_bank = gt_cur_bank;
        gt_bank(0);
#endif
        for (row = 0; row < 5; ++row) rows[row] = gt_font[gn][row];
#ifdef GT_BANKED
        gt_bank(saved_bank);
#endif
    }
    for (row = 0; row < 5; ++row) {
        int py = y + row;
        if (py < 0 || py > 127) continue;
        bits = rows[row];
        if ((bits & 4) && x >= 0 && x <= 127) vram_row[py][x] = col;
        if ((bits & 2) && x + 1 >= 0 && x + 1 <= 127) vram_row[py][x + 1] = col;
        if ((bits & 1) && x + 2 >= 0 && x + 2 <= 127) vram_row[py][x + 2] = col;
    }
}

#ifdef GT_BANKED
#define GT_PRINT gt_p8_print_impl
static int gt_p8_print_impl(const char *str, int x, int y, int c);
#else
#define GT_PRINT gt_p8_print
#endif
#ifdef GT_BANKED
static
#endif
int GT_PRINT(const char *str, int x, int y, int c) {
    unsigned char col = resolve_color(c);
    unsigned char gn;
    signed char slot;
    x -= gt_cam_x;
    y -= gt_cam_y;
    /* Blitter path: glyphs blit from the GRAM font (built per color on first
     * use) — no CPU-mode transition, so nothing drains. Edge-clipped glyphs
     * and a 9th text color take the per-pixel CPU path. */
    slot = font_slot(col);
    {
    /* hoisted: slot*10 is constant per call; (gn/32)*5 has 3 values */
    static const unsigned char rowoff[3] = { 0, 5, 10 };
    unsigned char rowbase = (slot >= 0) ? (unsigned char)(slot * 10) : 0;
    while (*str) {
        /* the common stretch — blit font, fully onscreen — runs in asm at
         * ~160 cycles/glyph (gt_print_asm.s); C handles the x<0 lead-in,
         * the clipped tail, and the CPU-glyph fallback */
        if (slot >= 0 && x >= 0 && x <= 125 && y >= 0 && y <= 123) {
            gt_a0 = (int)str;
            gt_a1 = x;
            gt_a2 = y;
            gt_a3 = rowbase;
            gt_a4 = (unsigned char)(bankflip | FONT_GROUP | BANK_CLIP_X | BANK_CLIP_Y);
            gt_print_z();
            str = (const char *)gt_a0;
            x = gt_a1;
            if (!*str) break;
        }
        gn = gt_glyph(*str);
        if (slot >= 0 && x >= 0 && x <= 125 && y >= 0 && y <= 123) {
            /* unreachable (asm consumed it) — keep the safety net */
        } else if (x >= -2 && x <= 127 && y >= -4 && y <= 127) {
            enter_cpu_mode();
            glyph_cpu(gn, x, y, col);
        }
        x += 4;
        ++str;
    }
    }
    return x + gt_cam_x;
}

/* print an INT without the fixed marshalling: print(v) with an int-typed
 * argument used to widen to long, shift 16, and run the long digit path —
 * ~600 cycles of pure conversion per call, every HUD frame. */
#ifdef GT_BANKED
#define GT_PRINT_INT gt_p8_print_int_impl
static int gt_p8_print_int_impl(int v, int x, int y, int c);
#else
#define GT_PRINT_INT gt_p8_print_int
#endif
#ifdef GT_BANKED
static
#endif
int GT_PRINT_INT(int v, int x, int y, int c) {
    char buf[8];
    char *p = buf + 7;
    unsigned int uv;
    unsigned char neg = 0;
    *p = 0;
    if (v < 0) { neg = 1; uv = (unsigned int)(-v); } else uv = (unsigned int)v;
    do {
        unsigned int q = uv / 10;
        --p;
        *p = (char)('0' + (unsigned char)(uv - ((q << 3) + (q << 1))));
        uv = q;
    } while (uv);
    if (neg) { --p; *p = '-'; }
    return GT_PRINT(p, x, y, c);
}

/* print a fixed number: integer part (P8 prints integers bare) */
#ifdef GT_BANKED
#define GT_PRINT_NUM gt_p8_print_num_impl
#else
#define GT_PRINT_NUM gt_p8_print_num
#endif
#ifdef GT_NUM8
#ifdef GT_BANKED
static
#endif
int GT_PRINT_NUM(int v, int x, int y, int c) {
    char buf[8];
    char *p = buf + 7;
    int iv = v >> 8;
#else
#ifdef GT_BANKED
static
#endif
int GT_PRINT_NUM(long v, int x, int y, int c) {
    char buf[8];
    char *p = buf + 7;
    int iv = (int)(v >> 16);
#endif
    unsigned int uv;
    unsigned char neg = 0;
    *p = 0;
    if (iv < 0) { neg = 1; uv = (unsigned int)(-iv); } else uv = (unsigned int)iv;
    /* one udiv per digit: cc65 computes % and / as SEPARATE division
     * calls (~450 cycles each); divide once, multiply back for the digit */
    do {
        unsigned int q = uv / 10;
        *--p = (char)('0' + (unsigned char)(uv - ((q << 3) + (q << 1))));
        uv = q;
    } while (uv);
    if (neg) *--p = '-';
    return GT_PRINT(p, x, y, c);
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
int gt_p8_print(const char *str, int x, int y, int c) {
    /* the string usually lives in the CALLER'S bank (a B1 draw function's
     * literal pool) — copy it to RAM while that bank is still mapped, THEN
     * switch to the print body's bank. Garbled glyphs otherwise. */
    char buf[33];               /* 32 glyphs = a full 128px line */
    unsigned char saved_bank = gt_cur_bank;
    unsigned char i;
    int r;
    for (i = 0; i < 32 && str[i]; ++i) buf[i] = str[i];
    buf[i] = 0;
    gt_bank(0);
    r = gt_p8_print_impl(buf, x, y, c);
    gt_bank(saved_bank);
    return r;
}

/* print a runtime byte buffer (NUL-terminated ASCII) — the whole string
 * costs ONE call's worth of wrapper (bank round-trip, clip, font setup)
 * instead of one per print(); ports cache composed numbers this way. */
int gt_p8_print_buf(unsigned char *buf, int off, int x, int y, int c) {
    return gt_p8_print((char *)buf + off, x, y, c);
}
#else
/* flat build: gt_p8_print IS the impl; same one-call contract */
int gt_p8_print_buf(unsigned char *buf, int off, int x, int y, int c) {
    return gt_p8_print((char *)buf + off, x, y, c);
}
#endif
#ifdef GT_BANKED
#ifdef GT_NUM8
int gt_p8_print_num(int v, int x, int y, int c) {
#else
int gt_p8_print_num(long v, int x, int y, int c) {
#endif
    unsigned char saved_bank = gt_cur_bank;
    int r;
    gt_bank(0);
    r = gt_p8_print_num_impl(v, x, y, c);
    gt_bank(saved_bank);
    return r;
}
int gt_p8_print_int(int v, int x, int y, int c) {
    unsigned char saved_bank = gt_cur_bank;
    int r;
    gt_bank(0);
    r = gt_p8_print_int_impl(v, x, y, c);
    gt_bank(saved_bank);
    return r;
}
#endif

/* The packed sheet pointer, stashed by gt_sheet_load so the background
 * compositor (gt_bg.c) can re-read tile pixels from it. In FLASH2M builds the
 * sheet lives in bank 2, mapped in by gt_sheet_init before gt_sheet_load runs;
 * gt_bg_compose re-maps that bank the same way before reading. NULL until a
 * sheet is loaded (bg_compose is a no-op then). */
const unsigned char *gt_sheet_ptr;

/* Load a packed 4bpp PICO-8 sheet (8192 bytes, two pixels per byte, low
 * nibble first) into GRAM through the palette map. Called by the generated
 * gt_sheet_init() before _init() when the build links a --sheet. */
#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#endif
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
/* packbits variant: [n,b0..bn-1] literal (n 1..127), [n|0x80,v] repeat
 * (n 3..127). Emitted by the builder when the game never re-reads the raw
 * sheet; typically halves the sheet's ROM cost. NOTE: gt_sheet_ptr stays
 * NULL — bg_compose needs the raw form and the builder keeps them apart. */
#ifdef GT_SHEET_PACKED
void gt_sheet_load_packed(const unsigned char *p, unsigned int plen) {
    const unsigned char *end = p + plen;
    unsigned int vi = 0;
    unsigned char n, b;
    enter_gram_mode();
    while (p < end) {
        n = *p++;
        if (n & 0x80) {
            n &= 0x7F;
            b = *p++;
            while (n--) {
                vram[vi++] = p8pal[b & 15];
                vram[vi++] = p8pal[b >> 4];
            }
        } else {
            while (n--) {
                b = *p++;
                vram[vi++] = p8pal[b & 15];
                vram[vi++] = p8pal[b >> 4];
            }
        }
    }
}
#endif /* GT_SHEET_PACKED */
#ifdef GT_BANKED
#pragma code-name ("CODE")
#endif

/* PICO-8 sset: plot into the 128x128 sprite sheet (GRAM quadrant 0).
 * Cold (boot-time cell drawing) — the body rides in bank 2 under FLASH2M. */
#ifdef GT_BANKED
#pragma code-name ("B0CODE")
#define GT_SSET_Z gt_p8_sset_z_impl
static void gt_p8_sset_z_impl(void);
#else
#define GT_SSET_Z gt_p8_sset_z
#endif
#ifdef GT_BANKED
static
#endif
void GT_SSET_Z(void) {
    unsigned char col = resolve_color(gt_a2);
    int x = gt_a0, y = gt_a1;
    if (x < 0 || x > 127 || y < 0 || y > 127) return;
    enter_gram_mode();
    vram[((unsigned int)y << 7) | (unsigned int)x] = col;
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_sset_z(void) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(0);
    gt_p8_sset_z_impl();
    gt_bank(saved_bank);
}
#endif


/* 16-cell-wide/tall sprites are 128px spans — past the 7-bit blit counter
 * (the hardware wraps the width to 0). The asm fast path punts here; split
 * in halves, each half re-entering the fast path. Mirrored halves swap
 * sides so hardware flips stay correct. */
#ifdef GT_BANKED
#pragma code-name ("B0CODE")
#define GT_SPR_WIDE gt_p8_spr_wide_impl
static void gt_p8_spr_wide_impl(void);
#else
#define GT_SPR_WIDE gt_p8_spr_wide
#endif
#ifdef GT_BANKED
static
#endif
void GT_SPR_WIDE(void) {
    int n = gt_a0, x = gt_a1, y = gt_a2, w = gt_a3, h = gt_a4, f = gt_a5;
    if (w >= 16) {
        int nl = (f & 1) ? n + 8 : n;
        int nr = (f & 1) ? n : n + 8;
        gt_p8_spr(nl, x, y, 8, h, f);
        gt_p8_spr(nr, x + 64, y, w - 8, h, f);
        return;
    }
    {
        int nt = (f & 2) ? n + 128 : n;
        int nb = (f & 2) ? n : n + 128;
        gt_p8_spr(nt, x, y, w, 8, f);
        gt_p8_spr(nb, x, y + 64, w, h - 8, f);
    }
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_spr_wide(void) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(0);
    gt_p8_spr_wide_impl();
    gt_bank(saved_bank);
}
#endif

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
void box_raw(unsigned char x, unsigned char y,
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
void hspan_raw(int x0, int x1, int y) {
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
/* FLASH2M: the clip/swap/split fill path is cold — the asm rectfill fast
 * path covers the common case. Rides the same relief bank as the input
 * block (B0 normally, B2 under GT_INPUT_B2) so b0-critical carts get both
 * out of the way with one ladder rung. Callers cross banks only via the
 * fixed stubs (line, the asm punt). */
#ifdef GT_BANKED
#ifdef GT_INPUT_B2
#pragma code-name ("B2CODE")
#else
#pragma code-name ("B0CODE")
#endif
#endif
void fill_clipped_z(void) {
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
void fill_clipped(int x0, int y0, int x1, int y1, unsigned char color) {
    gt_a0 = x0; gt_a1 = y0; gt_a2 = x1; gt_a3 = y1; fc_col = color;
    fill_clipped_z();
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
#endif

/* ---- PICO-8 drawing API ---- */

#ifdef GT_BANKED
#ifdef GT_INPUT_B2
#pragma code-name ("B2CODE")
#else
#pragma code-name ("B0CODE")
#endif
#define GT_CLS gt_p8_cls_impl
static void gt_p8_cls_impl(int c);
#else
#define GT_CLS gt_p8_cls
#endif
#ifdef GT_BANKED
static
#endif
void GT_CLS(int c) {
    /* Edge slivers first, the big 127x127 blit LAST: the caller returns
     * while the big DMA is still in flight, so a cls() at the top of
     * _update() overlaps the whole frame's game logic. */
    unsigned char col = (c < 0) ? p8pal[0] : resolve_color(c);
    box_raw(127, 0, 1, 127, col);
    box_raw(0, 127, 127, 1, col);
    box_raw(127, 127, 1, 1, col);
    box_raw(0, 0, 127, 127, col);
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_cls(int c) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(GT_RELIEF_BANK);
    gt_p8_cls_impl(c);
    gt_bank(saved_bank);
}
#endif

void gt_p8_camera(int x, int y) { gt_cam_x = x; gt_cam_y = y; }
void gt_p8_color(int c) { resolve_color(c); }

#ifdef GT_BANKED
#pragma code-name ("B0CODE")
#define GT_PAL gt_p8_pal_impl
static void gt_p8_pal_impl(int c0, int c1);
#else
#define GT_PAL gt_p8_pal
#endif
#ifdef GT_BANKED
static
#endif
void GT_PAL(int c0, int c1) {
    unsigned char i;
    if (c0 < 0) {                     /* pal() — reset */
        for (i = 0; i < 16; ++i) p8pal[i] = p8pal_rom[i];
        return;
    }
    if (c1 < 0) return;
    p8pal[c0 & 15] = (c1 & 0x100) ? (unsigned char)c1 : p8pal_rom[c1 & 15];
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_pal(int c0, int c1) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(0);
    gt_p8_pal_impl(c0, c1);
    gt_bank(saved_bank);
}
#endif

/* Fallback for the asm fast path in gt_blitq.s (_gt_p8_rectfill_z): handles
 * offscreen/reversed/128-span rects. resolve_color is idempotent, so the asm
 * path having peeked at the color first is harmless. */
#ifdef GT_BANKED
#ifdef GT_INPUT_B2
#pragma code-name ("B2CODE")
#else
#pragma code-name ("B0CODE")
#endif
#define GT_RECTFILL_SLOW gt_p8_rectfill_slow_impl
static void gt_p8_rectfill_slow_impl(void);
#else
#define GT_RECTFILL_SLOW gt_p8_rectfill_slow
#endif
#ifdef GT_BANKED
static
#endif
void GT_RECTFILL_SLOW(void) {
    fc_col = resolve_color(gt_a4);
    gt_a0 -= gt_cam_x;
    gt_a1 -= gt_cam_y;
    gt_a2 -= gt_cam_x;
    gt_a3 -= gt_cam_y;
    fill_clipped_z();
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_rectfill_slow(void) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(GT_RELIEF_BANK);
    gt_p8_rectfill_slow_impl();
    gt_bank(saved_bank);
}
#endif


#ifdef GT_BANKED
#ifdef GT_INPUT_B2
#pragma code-name ("B2CODE")
#else
#pragma code-name ("B0CODE")
#endif
#define GT_RECT_Z gt_p8_rect_z_impl
static void gt_p8_rect_z_impl(void);
#else
#define GT_RECT_Z gt_p8_rect_z
#endif
#ifdef GT_BANKED
static
#endif
void GT_RECT_Z(void) {
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
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_rect_z(void) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(GT_RELIEF_BANK);
    gt_p8_rect_z_impl();
    gt_bank(saved_bank);
}
#endif

void gt_p8_rect(int x0, int y0, int x1, int y1, int c) {
    gt_a0 = x0; gt_a1 = y0; gt_a2 = x1; gt_a3 = y1; gt_a4 = c;
    gt_p8_rect_z();
}

void pset_raw(int x, int y, unsigned char col) {
    if (x < 0 || x > 127 || y < 0 || y > 127) return;
    enter_cpu_mode();
    vram_row[(unsigned char)y][(unsigned char)x] = col;
}

void gt_p8_pset_z(void) {
    /* a pset is a 1x1 FILL through the blit pipeline: switching to CPU mode
     * here would first drain every queued blit's pixels (~16k cycles with a
     * frame clear in flight) — two decorative psets after the fills used to
     * cost more than the entire rest of the frame. Same pixel, queue path.
     * (print/sset still batch in CPU mode where it amortizes; pset_raw stays
     * the internal primitive for line's Bresenham inner loop.) */
    gt_a4 = gt_a2;
    gt_a2 = gt_a0;
    gt_a3 = gt_a1;
    gt_p8_rectfill_z();
}


#ifdef GT_STARFIELD
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
/* non-static: the per-frame loops live in gt_stars.s */
unsigned char star_x[GT_STARS_MAX];   /* column 0..127 */
unsigned char star_row[GT_STARS_MAX]; /* pixel row 0..127 */
unsigned char star_frac[GT_STARS_MAX];/* sub-row, 0..15 (16ths) */
unsigned char star_s[GT_STARS_MAX];   /* speed 8..31 (16ths/frame) */
unsigned char star_col[GT_STARS_MAX]; /* precomputed colour byte */
unsigned char star_n;
void __fastcall__ gt_sf_adv_z(unsigned char mode);
void gt_sf_draw_z(void);

#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_SF_INIT gt_starfield_init_impl
#define GT_SF_MOVE gt_starfield_move_impl
#else
#define GT_SF_INIT gt_starfield_init
#define GT_SF_MOVE gt_starfield_move
#endif
void GT_SF_INIT(int n) {
    unsigned char i, s;
    if (n > GT_STARS_MAX) n = GT_STARS_MAX;
    star_n = (unsigned char)n;
    for (i = 0; i < star_n; ++i) {
#ifdef GT_NUM8
        star_x[i]    = (unsigned char)(gt_p8_rnd(127 << 8) >> 8);
        star_row[i]  = (unsigned char)(gt_p8_rnd(127 << 8) >> 8);
        star_frac[i] = 0;
        s = (unsigned char)(8 + (gt_p8_rnd(24 << 8) >> 8));
#else
        star_x[i]    = (unsigned char)(gt_p8_rnd(128L << 16) >> 16);
        star_row[i]  = (unsigned char)(gt_p8_rnd(128L << 16) >> 16);
        star_frac[i] = 0;
        s = (unsigned char)(8 + (gt_p8_rnd(24L << 16) >> 16));
#endif
        star_s[i]    = s;
        /* colour by speed tier, baked once (pset colour never changes) */
        star_col[i]  = (s < 16) ? p8pal[1] : (s < 24) ? p8pal[13] : p8pal[6];
    }
}

/* the per-star loops moved to gt_stars.s (~86 -> ~30 cycles a star) */
void GT_SF_MOVE(int mode) {
    gt_sf_adv_z(mode == 2 ? 2 : mode == 1 ? 1 : 0);
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_starfield_init(int n) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(2);
    gt_starfield_init_impl(n);
    gt_bank(saved_bank);
}
void gt_starfield_move(int mode) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(2);
    gt_starfield_move_impl(mode);
    gt_bank(saved_bank);
}
#endif

#ifdef GT_BANKED
#pragma code-name ("B0CODE")
#define GT_SF_DRAW gt_starfield_draw_impl
static void gt_starfield_draw_impl(void);
#else
#define GT_SF_DRAW gt_starfield_draw
#endif
#ifdef GT_BANKED
static
#endif
void GT_SF_DRAW(void) {
    enter_cpu_mode();
    gt_sf_draw_z();
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_starfield_draw(void) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(0);
    gt_starfield_draw_impl();
    gt_bank(saved_bank);
}
#endif

#endif /* GT_STARFIELD */

#ifdef GT_FLAKES
/* ---- ambient flake field --------------------------------------------------
 * The draw loop lives in gt_flakes.s (~175 cycles/flake vs ~2,500 for the
 * same loop through cc65 — measured, see the asm header). This C side only
 * fills the asm unit's byte-split state at init time.
 * Reference semantics (newleste snow): x/y 8.8 screen space, 64-entry sine
 * wobble, y wraps at $7FFF, x respawns right at 32767 when px < -4. */
extern unsigned char fl_n, fl_xl[], fl_xh[], fl_yl[], fl_yh[], fl_ph[];
extern unsigned char fl_spdl[], fl_spdh[], fl_adv[], fl_w[], fl_h[], fl_ci[];
extern unsigned char fl_rxl[], fl_rxh[], fl_ry[];
extern signed char fl_sinl[];
extern unsigned char fl_sinh[];
#define GT_FLAKES_MAX 48

#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_FL_INIT gt_flakes_init_impl
#else
#define GT_FL_INIT gt_flakes_init
#endif
void GT_FL_INIT(int n) {
    unsigned char i;
    int v, sp;
    if (n > GT_FLAKES_MAX) n = GT_FLAKES_MAX;
    fl_n = (unsigned char)n;
    for (i = 0; i < 64; ++i) {
        /* flr(sin(i/64) * 256 + 0.5), like the reference table */
#ifdef GT_NUM8
        v = gt_fsin((int)(i << 2));
#else
        v = (int)(gt_fsin((long)i << 10) >> 8);
#endif
        fl_sinl[i] = (signed char)v;
        fl_sinh[i] = (v & 0x8000U) ? 0xFF : 0;
    }
    for (i = 0; i < fl_n; ++i) {
        v = gt_p8_rnd_int(128) << 8;
        fl_xl[i] = (unsigned char)v;
        fl_xh[i] = (unsigned char)((unsigned int)v >> 8);
        v = gt_p8_rnd_int(128) << 8;
        fl_yl[i] = (unsigned char)v;
        fl_yh[i] = (unsigned char)((unsigned int)v >> 8);
        fl_ph[i] = 0;
        /* speed 64 + rnd(5)*256 in 8.8, like the reference */
        sp = 64 + (gt_p8_rnd_int(5) << 8);
        fl_spdl[i] = (unsigned char)sp;
        fl_spdh[i] = (unsigned char)((unsigned int)sp >> 8);
        { int a = sp >> 5; if (a > 12) a = 12; fl_adv[i] = (unsigned char)a; }
        /* reference pas = flr(rnd(1.25)): 0 four times in five, else 1;
         * the ring W/H field wants size+1 */
        fl_w[i] = fl_h[i] = (unsigned char)((gt_p8_rnd_int(5) == 4) ? 2 : 1);
        fl_ci[i]  = (unsigned char)(p8pal[6 + gt_p8_rnd_int(2)] ^ 0xFF);
        fl_rxl[i] = 0xFF; fl_rxh[i] = 0x7F;   /* snow re-enters from the right */
        fl_ry[i]  = 1;                        /* and rerolls its row */
    }
}
/* manual slot setup for the cloud layer: pixel x/y, blit w/h, 8.8 speed,
 * p8 color. No wobble (phase and adv stay zero), keeps its row, respawns
 * at -w when it exits right... by setting respawn-x = -(w<<8). Call after
 * flakes_init has set fl_n high enough (init count covers ALL layers). */
#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_FL_SET gt_flakes_set_impl
#else
#define GT_FL_SET gt_flakes_set
#endif
void GT_FL_SET(int i, int x, int y, int w, int h, int spd8, int col) {
    int v;
    if (i < 0 || i >= GT_FLAKES_MAX) return;
    v = x << 8;
    fl_xl[i] = (unsigned char)v;
    fl_xh[i] = (unsigned char)((unsigned int)v >> 8);
    v = y << 8;
    fl_yl[i] = (unsigned char)v;
    fl_yh[i] = (unsigned char)(((unsigned int)v >> 8) & 127);
    fl_ph[i] = 0;
    fl_spdl[i] = (unsigned char)spd8;
    fl_spdh[i] = (unsigned char)((unsigned int)spd8 >> 8);
    fl_adv[i] = 0;
    fl_w[i] = (unsigned char)w;
    fl_h[i] = (unsigned char)h;
    fl_ci[i] = (unsigned char)(p8pal[col & 15] ^ 0xFF);
    v = (-w) << 8;
    fl_rxl[i] = (unsigned char)v;
    fl_rxh[i] = (unsigned char)((unsigned int)v >> 8);
    fl_ry[i] = 0;
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_flakes_init(int n) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(2);
    gt_flakes_init_impl(n);
    gt_bank(saved_bank);
}
void gt_flakes_set(int i, int x, int y, int w, int h, int spd8, int col) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(2);
    gt_flakes_set_impl(i, x, y, w, h, spd8, col);
    gt_bank(saved_bank);
}
#endif
/* per-flake mode: 0 = respawn+reroll (snow), 1 = respawn keep-row
 * (clouds, set by flakes_set), 2 = wrap at the screen edge (ambient
 * parallax snow that drifts both directions) */
void gt_flakes_mode(int i, int m) {
    if (i >= 0 && i < GT_FLAKES_MAX) fl_ry[i] = (unsigned char)m;
}

/* the 4-piece 128x128 canvas window (gt_flakes.s asm): newleste's map */
extern unsigned char cv_dy, cv_fl;
extern int cv_dx;
#pragma zpsym ("cv_dx")
#pragma zpsym ("cv_dy")
#pragma zpsym ("cv_fl")
void gt_canvas_view_z(void);
void gt_canvas_view(int dx, int dy, int opaque) {
    cv_dx = dx;
    cv_dy = (unsigned char)dy;
    cv_fl = (opaque == 1) ? 0xD7 : 0x57; /* omitted optional arrives as -1 */
    gt_draw_mode = MODE_NONE;
    gt_canvas_view_z();
}

/* the HUD stamina/life bar in one asm call (gt_flakes.s): args ride zp
 * bytes, the emitter writes them directly — no stack marshalling. */
extern unsigned char db_px, db_py, db_v, db_m, db_c, db_c2, db_bg;
#pragma zpsym ("db_px")
#pragma zpsym ("db_py")
#pragma zpsym ("db_v")
#pragma zpsym ("db_m")
#pragma zpsym ("db_c")
#pragma zpsym ("db_c2")
#pragma zpsym ("db_bg")
void gt_dbar_z(void);

/* flakes, CPU-poke draw: for 1x1 fields drawn at the frame TAIL — one
 * mode drain (cheap there: the blitter has had the whole frame), then
 * ~35 cycles a flake instead of ~130 through the ring + per-blit IRQ. */
void gt_flakes_draw2c(int first, int count, int cdx8, int cdy8);
void gt_flakes_draw2_cpu(int first, int count, int cdx8, int cdy8) {
    enter_cpu_mode();
    gt_flakes_draw2c(first, count, cdx8, cdy8);
}

/* follower chain: ease + draw in asm (gt_flakes.s). Coordinates are
 * screen-space (the caller's camera() applies before this). */
void gt_chain_step_draw(int x, int y, int col) {
    gt_a0 = x;
    gt_a1 = y;
    gt_a2 = col & 15;
    gt_chain_z();
}
#endif /* GT_FLAKES */

#ifdef GT_TILES
/* visible-window tile scan in asm (gt_tiles.s): stages QF_SPR entries for
 * every flag&1 tile in the [i0..i1]x[j0..j1] cell window. The port draws
 * animated/special tiles on top from its own list. */
extern unsigned char *tp_map, *tp_fl;
extern unsigned char tp_w, tp_h, tp_stride, tp_sx, tp_sy;
#pragma zpsym ("tp_map")
#pragma zpsym ("tp_fl")
#pragma zpsym ("tp_w")
#pragma zpsym ("tp_h")
#pragma zpsym ("tp_stride")
#pragma zpsym ("tp_sx")
#pragma zpsym ("tp_sy")
void gt_tiles_z(void);
void gt_tiles_draw(unsigned char *map, unsigned char *flags, int lvlw,
                   int i0, int i1, int j0, int j1) {
    if (i1 < i0 || j1 < j0) return;
    tp_map = map + (unsigned int)(j0 * lvlw + i0);
    tp_fl = flags;
    tp_w = (unsigned char)(i1 - i0 + 1);
    tp_h = (unsigned char)(j1 - j0 + 1);
    tp_stride = (unsigned char)(lvlw - (i1 - i0 + 1));
    tp_sx = (unsigned char)(i0 * 8 - gt_cam_x);
    tp_sy = (unsigned char)(j0 * 8 - gt_cam_y);
    gt_tiles_z();
}
#endif /* GT_TILES */

#ifdef GT_BALLS
/* one ball-table physics substep in asm (gt_balls.s): half-velocity
 * integration on the 8.8 core embedded in the port's 16.16 arrays, wall
 * bounces (clamp + per-ball flag), spatial grid rebuild, and a contact-
 * pair scan into `pairs` (i,j 1-based, 0-terminated). Lua resolves the
 * pairs (impulse/merge) and applies bounce rules from the flags. */
extern unsigned char *bp_x, *bp_y, *bp_vx, *bp_vy, *bp_act, *bp_fl, *bp_pairs;
extern unsigned char bp_n;
#pragma zpsym ("bp_x")
#pragma zpsym ("bp_y")
#pragma zpsym ("bp_vx")
#pragma zpsym ("bp_vy")
#pragma zpsym ("bp_act")
#pragma zpsym ("bp_fl")
#pragma zpsym ("bp_pairs")
#pragma zpsym ("bp_n")
void gt_balls_z(void);
void gt_balls_step(long *x, long *y, long *vx, long *vy, int *act,
                   unsigned char *flags, unsigned char *pairs, int n) {
    bp_x = (unsigned char *)x;
    bp_y = (unsigned char *)y;
    bp_vx = (unsigned char *)vx;
    bp_vy = (unsigned char *)vy;
    bp_act = (unsigned char *)act;
    bp_fl = flags;
    bp_pairs = pairs;
    bp_n = (unsigned char)n;
    gt_balls_z();
}
/* per-frame drag on the full 16.16 velocities: v -= (v>>8)*5, which is
 * (v>>6)+(v>>8) to within 3/65536 — the compiled long shifts cost ~500
 * per ball, this ~130. */
void gt_balls_drag_z(void);
void gt_balls_drag(long *vx, long *vy, int *act, int n) {
    bp_vx = (unsigned char *)vx;
    bp_vy = (unsigned char *)vy;
    bp_act = (unsigned char *)act;
    bp_n = (unsigned char)n;
    gt_balls_drag_z();
}
/* one 16x16 sprite per nonzero cell byte, positions from the fixed
 * arrays' int bytes (gt_balls.s). */
void gt_balls_draw_z(void);
void gt_balls_draw(long *x, long *y, unsigned char *cells, int n) {
    bp_x = (unsigned char *)x;
    bp_y = (unsigned char *)y;
    bp_fl = cells;
    bp_n = (unsigned char)n;
    gt_balls_draw_z();
}

/* particle pool integrator (gt_balls.s): x += v and the 31/32-ish damp on
 * every used slot of a 16.16 SoA pool. */
extern unsigned char *pp_x, *pp_y, *pp_vx, *pp_vy, *pp_u;
extern unsigned char pp_n;
#pragma zpsym ("pp_x")
#pragma zpsym ("pp_y")
#pragma zpsym ("pp_vx")
#pragma zpsym ("pp_vy")
#pragma zpsym ("pp_u")
#pragma zpsym ("pp_n")
void gt_parts_step_z(void);
void gt_parts_step(long *x, long *y, long *vx, long *vy, unsigned char *u,
                   int n) {
    pp_x = (unsigned char *)x;
    pp_y = (unsigned char *)y;
    pp_vx = (unsigned char *)vx;
    pp_vy = (unsigned char *)vy;
    pp_u = u;
    pp_n = (unsigned char)n;
    gt_parts_step_z();
}
#endif /* GT_BALLS */

#ifdef GT_POOLMV
/* bulk pool move (gt_poolmv.s): x += sx / y += sy over used slots, with
 * optional particle damping (v -= v>>3 + v>>5). */
extern unsigned char *pm_x, *pm_y, *pm_sx, *pm_sy, *pm_used;
extern unsigned char pm_n, pm_mode;
#pragma zpsym ("pm_x")
#pragma zpsym ("pm_y")
#pragma zpsym ("pm_sx")
#pragma zpsym ("pm_sy")
#pragma zpsym ("pm_used")
#pragma zpsym ("pm_n")
#pragma zpsym ("pm_mode")
void gt_poolmv_z(void);
void gt_pool_move(int *x, int *y, int *sx, int *sy, unsigned char *used,
                  int n, int mode) {
    pm_x = (unsigned char *)x;
    pm_y = (unsigned char *)y;
    pm_sx = (unsigned char *)sx;
    pm_sy = (unsigned char *)sy;
    pm_used = used;
    pm_n = (unsigned char)n;
    pm_mode = (unsigned char)mode;
    gt_poolmv_z();
}

/* bulk 8x8 sprite pass (gt_poolmv.s): used slots with a nonzero cell byte
 * blit at (x>>4, y>>4). */
extern unsigned char *pm_cells;
#pragma zpsym ("pm_cells")
void gt_pool_sprs_z(void);
void gt_pool_sprs(int *x, int *y, unsigned char *used, unsigned char *cells,
                  int n) {
    pm_x = (unsigned char *)x;
    pm_y = (unsigned char *)y;
    pm_used = used;
    pm_cells = cells;
    pm_n = (unsigned char)n;
    gt_pool_sprs_z();
}
#endif /* GT_POOLMV */

#ifdef GT_HITS
/* two-pool AABB overlap scan (gt_hits.s) — pairs of live ordinals out */
extern unsigned char *hs_ax, *hs_ay, *hs_aw, *hs_ah, *hs_au;
extern unsigned char *hs_bx, *hs_by, *hs_bw, *hs_bu, *hs_pairs;
extern unsigned char hs_an, hs_bn, hs_bh, hs_sh;
#pragma zpsym ("hs_ax")
#pragma zpsym ("hs_ay")
#pragma zpsym ("hs_aw")
#pragma zpsym ("hs_ah")
#pragma zpsym ("hs_au")
#pragma zpsym ("hs_an")
#pragma zpsym ("hs_bx")
#pragma zpsym ("hs_by")
#pragma zpsym ("hs_bw")
#pragma zpsym ("hs_bu")
#pragma zpsym ("hs_bn")
#pragma zpsym ("hs_bh")
#pragma zpsym ("hs_sh")
#pragma zpsym ("hs_pairs")
void gt_hits_z(void);
void gt_hit_scan(int *ax, int *ay, unsigned char *aw, unsigned char *ah,
                 unsigned char *au, int an,
                 int *bx, int *by, unsigned char *bw, unsigned char *bu,
                 int bn, int bh, int sh, unsigned char *pairs) {
    hs_ax = (unsigned char *)ax;
    hs_ay = (unsigned char *)ay;
    hs_aw = aw;
    hs_ah = ah;
    hs_au = au;
    hs_an = (unsigned char)an;
    hs_bx = (unsigned char *)bx;
    hs_by = (unsigned char *)by;
    hs_bw = bw;
    hs_bu = bu;
    hs_bn = (unsigned char)bn;
    hs_bh = (unsigned char)(bh - 1);
    hs_sh = (unsigned char)sh;
    hs_pairs = pairs;
    gt_hits_z();
}
#endif /* GT_HITS */

#ifdef GT_CHUNKS
/* 24px atlas-chunk grid renderer (gt_chunks.s) — see the asm header. */
extern unsigned char *ck_grid, *ck_lut, *ck_lut2, *ck_props;
extern unsigned char ck_w, ck_h, ck_stride, ck_x0, ck_y0;
#pragma zpsym ("ck_grid")
#pragma zpsym ("ck_lut")
#pragma zpsym ("ck_lut2")
#pragma zpsym ("ck_props")
#pragma zpsym ("ck_w")
#pragma zpsym ("ck_h")
#pragma zpsym ("ck_stride")
#pragma zpsym ("ck_x0")
#pragma zpsym ("ck_y0")
void gt_chunks_z(void);
void gt_chunks_draw(int *grid, unsigned char *lut, unsigned char *lut2,
                    unsigned char *props, int stride,
                    int cx0, int cy0, int cx1, int cy1) {
    if (cx1 < cx0 || cy1 < cy0) return;
    ck_grid = (unsigned char *)(grid + cy0 * stride + cx0);
    ck_lut = lut;
    ck_lut2 = lut2;
    ck_props = props;
    ck_w = (unsigned char)(cx1 - cx0 + 1);
    ck_h = (unsigned char)(cy1 - cy0 + 1);
    ck_stride = (unsigned char)(stride - (cx1 - cx0 + 1));
    ck_x0 = (unsigned char)(cx0 * 24 - gt_cam_x);
    ck_y0 = (unsigned char)(cy0 * 24 - gt_cam_y);
    gt_chunks_z();
}
#endif /* GT_CHUNKS */

#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_LINE_DIAG line_diag_impl
static void line_diag_impl(int x0, int y0, int x1, int y1, unsigned char col);
#else
#define GT_LINE_DIAG line_diag
#endif
#ifdef GT_BANKED
static
#endif
void GT_LINE_DIAG(int x0, int y0, int x1, int y1, unsigned char col) {
    int dx, dy, sx, sy, e2, errv;
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
#ifdef GT_BANKED
#pragma code-name ("CODE")
static void line_diag(int x0, int y0, int x1, int y1, unsigned char col) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(2);
    line_diag_impl(x0, y0, x1, y1, col);
    gt_bank(saved_bank);
}
#endif

/* axis-aligned lines become blitter fills (the hot case); true diagonals
 * walk Bresenham in the B2 cold body. Rides in B0 with fill_clipped. */
#ifdef GT_BANKED
#ifdef GT_INPUT_B2
#pragma code-name ("B2CODE")
#else
#pragma code-name ("B0CODE")
#endif
#define GT_LINE_Z gt_p8_line_z_impl
static void gt_p8_line_z_impl(void);
#else
#define GT_LINE_Z gt_p8_line_z
#endif
#ifdef GT_BANKED
static
#endif
void GT_LINE_Z(void) {
    unsigned char col = resolve_color(gt_a4);
    int x0, y0, x1, y1;
    x0 = gt_a0 - gt_cam_x; y0 = gt_a1 - gt_cam_y;
    x1 = gt_a2 - gt_cam_x; y1 = gt_a3 - gt_cam_y;
    if (y0 == y1) { fill_clipped(x0, y0, x1, y1, col); return; }
    if (x0 == x1) { fill_clipped(x0, y0, x1, y1, col); return; }
    line_diag(x0, y0, x1, y1, col);
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_line_z(void) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(GT_RELIEF_BANK);
    gt_p8_line_z_impl();
    gt_bank(saved_bank);
}
#endif


/* circle engine contract (gt_circ.s) — shared by banked and flat builds */
extern int cc_x, cc_y;
extern unsigned char cc_r, cc_c;
#pragma zpsym ("cc_x")
#pragma zpsym ("cc_y")
#pragma zpsym ("cc_r")
#pragma zpsym ("cc_c")
void gt_circf_z(void);
void gt_circo_z(void);

#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_CIRCFILL_Z gt_p8_circfill_z_impl
static void gt_p8_circfill_z_impl(void);
#else
#define GT_CIRCFILL_Z gt_p8_circfill_z
#endif
#ifdef GT_BANKED
static
#endif
void GT_CIRCFILL_Z(void) {
    unsigned char col = resolve_color(gt_a3);
    int cx, cy, r;
    cx = gt_a0 - gt_cam_x; cy = gt_a1 - gt_cam_y;
    r = gt_a2;
    if (r < 0) return;
    if (r == 0) { pset_raw(cx, cy, col); return; }
    if (r > 127) r = 127;
    /* the midpoint loop + span staging live in gt_circ.s (~45 cycles a
     * span against ~300 through hspan_raw — cherry's explosion discs) */
    cc_x = cx; cc_y = cy;
    cc_r = (unsigned char)r;
    cc_c = (unsigned char)~col;
    gt_circf_z();
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_circfill_z(void) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(2);
    gt_p8_circfill_z_impl();
    gt_bank(saved_bank);
}
#endif


#ifdef GT_BANKED
#pragma code-name ("B2CODE")
#define GT_CIRC_Z gt_p8_circ_z_impl
static void gt_p8_circ_z_impl(void);
#else
#define GT_CIRC_Z gt_p8_circ_z
#endif
#ifdef GT_BANKED
static
#endif
void GT_CIRC_Z(void) {
    unsigned char col = resolve_color(gt_a3);
    int cx, cy, r;
    cx = gt_a0 - gt_cam_x; cy = gt_a1 - gt_cam_y;
    r = gt_a2;
    if (r < 0) return;
    if (r == 0) { pset_raw(cx, cy, col); return; }
    if (r > 127) r = 127;
    cc_x = cx; cc_y = cy;
    cc_r = (unsigned char)r;
    cc_c = (unsigned char)~col;
    gt_circo_z();
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_circ_z(void) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(2);
    gt_p8_circ_z_impl();
    gt_bank(saved_bank);
}
#endif


#ifdef GT_BANKED
#ifdef GT_INPUT_B2
#pragma code-name ("B2CODE")
#else
#pragma code-name ("B0CODE")
#endif
#define GT_BORDER gt_p8_border_impl
static void gt_p8_border_impl(int c);
#else
#define GT_BORDER gt_p8_border
#endif
#ifdef GT_BANKED
static
#endif
void GT_BORDER(int c) {
    /* fill the overscan ring (visible area is x 1..126, y 7..119) */
    unsigned char col = resolve_color(c);
    fill_clipped(0, 0, 127, 6, col);
    fill_clipped(0, 120, 127, 127, col);
    fill_clipped(0, 7, 0, 119, col);
    fill_clipped(127, 7, 127, 119, col);
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
void gt_p8_border(int c) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(GT_RELIEF_BANK);
    gt_p8_border_impl(c);
    gt_bank(saved_bank);
}
#endif

/* ---- input: latch + two reads per pad (active-low), per the C SDK ----
 * FLASH2M: the block banks to 0 by default; -DGT_INPUT_B2 moves it to
 * bank 2 (a placement-ladder rung — which bank has room is per-cart). */
#ifdef GT_INPUT_B2
#define GT_INPUT_BANK 2
#else
#define GT_INPUT_BANK 0
#endif
#ifdef GT_BANKED
#ifdef GT_INPUT_B2
#pragma code-name ("B2CODE")
#pragma rodata-name ("B2RODATA")
#else
#pragma code-name ("B0CODE")
#pragma rodata-name ("B0RODATA")
#endif
#define GT_UPDATE_INPUTS gt_update_inputs_impl
#define GT_BTN gt_p8_btn_impl
#define GT_BTNP gt_p8_btnp_impl
static void gt_update_inputs_impl(void);
static unsigned char gt_p8_btn_impl(int i, int pl);
static unsigned char gt_p8_btnp_impl(int i, int pl);
#else
#define GT_UPDATE_INPUTS gt_update_inputs
#define GT_BTN gt_p8_btn
#define GT_BTNP gt_p8_btnp
#endif

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

#ifdef GT_BANKED
static
#endif
void GT_UPDATE_INPUTS(void) {
    unsigned char rpt_start, rpt_every;
    /* P8 btnp auto-repeat: 15 frames then every 4 at 30fps; doubled at 60 */
    if (fps30) { rpt_start = 15; rpt_every = 4; }
    else { rpt_start = 30; rpt_every = 8; }
    gt_pad0 = read_pad(0);
    gt_pad1 = read_pad(1);
    gt_rpt0 = rpt_of(0, gt_pad0, rpt_start, rpt_every);
    gt_rpt1 = rpt_of(1, gt_pad1, rpt_start, rpt_every);
}

#ifdef GT_BANKED
static
#endif
unsigned char GT_BTN(int i, int pl) {
    if (i < 0 || i > 7) return 0;
    return ((pl & 1 ? gt_pad1 : gt_pad0) & btn_mask[i]) != 0;
}

#ifdef GT_BANKED
static
#endif
unsigned char GT_BTNP(int i, int pl) {
    if (i < 0 || i > 7) return 0;
    return ((pl & 1 ? gt_rpt1 : gt_rpt0) & btn_mask[i]) != 0;
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
#pragma rodata-name ("RODATA")
void gt_update_inputs(void) {
    unsigned char saved_bank = gt_cur_bank;
    gt_bank(GT_INPUT_BANK);
    gt_update_inputs_impl();
    gt_bank(saved_bank);
}
unsigned char gt_p8_btn(int i, int pl) {
    unsigned char saved_bank = gt_cur_bank;
    unsigned char r;
    gt_bank(GT_INPUT_BANK);
    r = gt_p8_btn_impl(i, pl);
    gt_bank(saved_bank);
    return r;
}
unsigned char gt_p8_btnp(int i, int pl) {
    unsigned char saved_bank = gt_cur_bank;
    unsigned char r;
    gt_bank(GT_INPUT_BANK);
    r = gt_p8_btnp_impl(i, pl);
    gt_bank(saved_bank);
    return r;
}
#endif

/* ---- lifecycle ---- */

/* headroom meter: every pass through the vsync-wait poll loop bumps this.
 * Idle cycles ~= polls * ~40, so tooling can report work-vs-slack per
 * frame (the pace itself pins at 2.0 once a 30fps cart makes rate — this
 * is the number that says HOW MUCH room is left under the lock). */
unsigned long gt_idle_polls;

static void await_vsync(void) {
    gt_frameflag = 1;
    /* pump while waiting: completed blits would otherwise leave the ring
     * idle for the whole vsync spin — this is where queued pixel time hides */
    while (gt_frameflag) { gt_q_pump(); ++gt_idle_polls; }
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
    { extern unsigned int gt_rng_state; gt_rng_state = 0xABCDU; }
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

/* gt.autocls(c): queue the frame clear right after the page flip so its
 * ~16k pixels of blitter time drain inside the fps30 second vsync wait
 * (measured: a full-screen cls is 27% of the whole 30fps budget when the
 * game clears at draw time). -1 = off. */
#ifdef GT_AUTOCLS
int gt_autocls = -1;

void gt_autocls_set(int c) { gt_autocls = c; }
#endif

#ifdef GT_AUTOCLS
static void queue_autocls(void) {
    unsigned char col;
    if (gt_autocls < 0) return;
    col = resolve_color(gt_autocls);
    box_raw(127, 0, 1, 127, col);
    box_raw(0, 127, 127, 1, col);
    box_raw(127, 127, 1, 1, col);
    box_raw(0, 0, 127, 127, col);
}
#else
#define queue_autocls()
#endif

static unsigned char hook_tick_last;

/* monotonic game-frame counter: one tick per completed endframe. The pace
 * instruments difference THIS against gt_ticks (vsyncs) — every ad-hoc
 * per-cart counter (tick/gtime/frames) resets somewhere and lied.
 * Lives in zp (gt_blitq.s): the fixed bank had literally zero bytes to
 * spare when this landed (just-one-boss went 'VECTORS over by 1'). */
extern unsigned int gt_frames;
#pragma zpsym ("gt_frames")

void gt_endframe(void) {
    ++gt_frames;
    /* vsync FIRST, then the drain check: queued blits keep draining DURING
     * the vsync wait, so their pixel time vanishes from the frame budget
     * (a full-screen cls is 16k pixels of blitter time — serializing it
     * before the wait cost fill-heavy carts a whole extra vsync). The drain
     * check after the edge is normally already satisfied; when it isn't,
     * the flip slides a few hundred cycles into vblank, which is where it
     * belongs anyway. */
    await_vsync();
    await_drawing();
    flip_pages();
    queue_autocls();             /* the NEW draw page clears during the wait */
    gt_time_tick();
    if (gt_frame_hook) {
        /* The sequencer is a 60 Hz clock: when a heavy frame spans extra
         * vsyncs, step it once per ELAPSED vsync (capped) or envelopes
         * stretch and notes hang on loud phases — audible as distortion
         * during slowdown. gt_ticks counts real vsyncs via the NMI. */
        unsigned char steps = (unsigned char)(gt_ticks - hook_tick_last);
        if (steps > 6) steps = 6;
        if (steps < 1) steps = 1;
        while (steps--) gt_frame_hook();
    }
    hook_tick_last = (unsigned char)gt_ticks;
    if (fps30) {                 /* 30fps mode: burn the second vsync */
        await_vsync();           /* (pumps: the autocls drains in here) */
        gt_time_tick();
        if (gt_frame_hook) gt_frame_hook(); /* keep music at 60 Hz in 30fps mode */
        hook_tick_last = (unsigned char)gt_ticks;
    }
}
