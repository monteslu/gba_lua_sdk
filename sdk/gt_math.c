/* gt_math.c — PICO-8 math library on 16.16 fixed point:
 * turns-based trig (256-step ROM table, screen-space-inverted sin),
 * xorshift rnd/srand, and t()/time() as an exact 1/60s accumulator.
 *
 * Banked build (-DGT_BANKED): this whole cold-path unit is exiled from the
 * always-mapped FIXED bank ($C000-$FFFF) into game bank 1 ($8000-$BFFF) to
 * reclaim ~2.2 KB of fixed-bank space (code + the 1 KB sine table) after the
 * quarter-square multiply tables filled it. Callers reach these functions
 * through fixed-bank far-call stubs in sdk/gt_math_stubs.s that own the plain
 * public names (gt_fsin ...) and jump here; the impls are renamed with an
 * _impl suffix so the stub name and the impl name don't collide. Only CODE and
 * RODATA (incl. the sine table) move — DATA/BSS (gt_time_acc, gt_rng,
 * gt_time_rem) live in RAM, which is reachable from any bank, so they keep
 * their names.
 *
 * The rodata-name pragma is set BEFORE including gt_sintab.h so the 1 KB table
 * lands in B1RODATA too, not just the function code. gt_fmul/gt_fdiv (called by
 * gt_fatan2/gt_p8_rnd) stay in the FIXED bank, so an impl in bank 1 calls them
 * with a plain jsr — the fixed window is always mapped. gt_math functions never
 * call each other, so there are no bank1->bank1 intra-unit calls to bridge. */
#ifdef GT_BANKED
#pragma code-name ("B1CODE")
#pragma rodata-name ("B1RODATA")
#define GT_M(name) name##_impl
#else
#define GT_M(name) name
#endif

#define gt_fsin     GT_M(gt_fsin)
#define gt_fcos     GT_M(gt_fcos)
#define gt_fatan2   GT_M(gt_fatan2)
#define gt_p8_rnd   GT_M(gt_p8_rnd)
#define gt_p8_rnd_int GT_M(gt_p8_rnd_int)
#define gt_p8_srand GT_M(gt_p8_srand)
#define gt_p8_time  GT_M(gt_p8_time)
#define gt_time_tick GT_M(gt_time_tick)

#include "gt_fixed.h"
/* The 16.16 sine table (1 KB of longs) is only used by the non-N8 path below.
 * The canonical N8 build reads the 512-byte 8.8 table instead, so it doesn't
 * pay for the long table. */
#ifndef GT_NUM8
#include "gt_sintab.h"
#endif

#ifdef GT_NUM8
/* 8.8 mode: the turn fraction IS the low byte — the table index is free.
 * Read from a NATIVE 8.8 table (int16) so each call is one 2-byte indexed load,
 * not a long-table index (*4) + 32-bit >>8. gt_sintab8 is gt_sintab >> 8. */
#include "gt_sintab8.h"
int gt_fsin(int turns) {
    return gt_sintab8[(unsigned char)turns];
}

int gt_fcos(int turns) {
    return -gt_sintab8[(unsigned char)(turns + 0x40)];
}
#else
long gt_fsin(long turns) {
    /* index = top 8 bits of the turn fraction */
    return gt_sintab[(unsigned char)(((unsigned long)turns >> 8) & 0xFF)];
}

long gt_fcos(long turns) {
    /* cos(x) = -p8sin(x + 0.25) */
    return -gt_sintab[(unsigned char)((((unsigned long)turns + 0x4000UL) >> 8) & 0xFF)];
}
#endif

#ifdef GT_NUM8
#include "gt_atantab.h"
int gt_fatan2(int dx, int dy) {
    /* octant-folded atan2. The angle polynomial (two gt_fmul, ~1200 cyc) became
     * a 256-byte table (gt_atantab); the ratio, which used to cost a full 24-round
     * gt_fdiv (~1350 cyc), now uses gt_ratio8 — an 8-round unsigned divide that
     * yields exactly the 8-bit table index (measured error vs full divide:
     * 1/256 turn = 1.4 deg). Only cheap ops left. */
    unsigned char swap = 0, mirror = 0, negate = 0;
    int mx = dx, my = -dy;
    unsigned int ax, ay, big;
    int a;
    unsigned char r;
    if (dx == 0 && dy == 0) return 0xC0;
    if (mx < 0) { mirror = 1; ax = (unsigned int)(-mx); } else ax = (unsigned int)mx;
    if (my < 0) { negate = 1; ay = (unsigned int)(-my); } else ay = (unsigned int)my;
    /* gt_ratio8 needs both operands in 0..127 (8-bit divide). dx/dy arrive in 8.8
     * fixed (a pixel delta of 1 is 256), so ax/ay can be 16-bit. The angle only
     * depends on the RATIO, so scale both down by the same power of two until the
     * larger fits a byte — the ratio (and thus the angle) is preserved. */
    big = (ax > ay) ? ax : ay;
    while (big > 127u) { ax >>= 1; ay >>= 1; big >>= 1; }
    /* gt_ratio8(min, max) = (min<<8)/max in 0..255 (min<=max); equal -> 255. */
    if (ay > ax) { swap = 1; r = (unsigned char)gt_ratio8((int)ax, (int)ay); }
    else         {           r = (unsigned char)gt_ratio8((int)ay, (int)ax); }
    a = gt_atantab[r];
    if (swap) a = 0x40 - a;
    if (mirror) a = 0x80 - a;
    if (negate) a = -a;
    return a & 0xFF;
}
#else
long gt_fatan2(long dx, long dy) {
    /* PICO-8 convention: angle in turns [0,1), consistent with the inverted
     * sin — anchors: atan2(1,0)=0, atan2(0,-1)=0.25, atan2(-1,0)=0.5,
     * atan2(0,1)=0.75, atan2(1,1)=0.875, atan2(0,0)=0.75.
     * Equivalent to math-space atan2(-dy, dx)/2pi normalized to [0,1).
     * First-octant arctan via the classic approximation
     *   atan(r) ~ r*(pi/4 + 0.273*(1-r))  ->  turns: r*(0.125+0.04345*(1-r))
     * (max error ~0.0006 turns), quadrant-folded. */
    unsigned char swap = 0, mirror = 0, negate = 0;
    long mx = dx, my = -dy;          /* screen space -> math space */
    long ax, ay, r, a;
    if (dx == 0 && dy == 0) return 0xC000L;
    if (mx < 0) { mirror = 1; ax = -mx; } else ax = mx;
    if (my < 0) { negate = 1; ay = -my; } else ay = my;
    if (ay > ax) { swap = 1; r = gt_fdiv(ax, ay); }
    else         {           r = gt_fdiv(ay, ax); }
    a = gt_fmul(r, 0x2000L + gt_fmul(0x0B20L, 0x10000L - r));
    if (swap) a = 0x4000L - a;
    if (mirror) a = 0x8000L - a;
    if (negate) a = -a;
    return a & 0xFFFFL;
}
#endif

/* ---- rnd / srand: 16-bit xorshift in asm (gt_blitq.s) ----
 * An explosion spawns ~250 rnd() calls in one frame; the old 32-bit
 * xorshift walked cc65's long-shift loops for ~700 cycles per call.
 * gt_rng_next is ~40 cycles; full 65535-value orbit, never yields 0. */
extern unsigned int gt_rng_state;
unsigned int __fastcall__ gt_rng_next(void);

/* rnd consumed as an integer with an integral range — the emitter routes
 * flr(rnd(n))/int-context rnd here: one 16x32 runtime multiply instead of
 * the full fixed multiply. Bit-identical to flr(rnd(n)) by construction. */
int gt_p8_rnd_int(int n) {
    unsigned int s = gt_rng_next();
    if (n <= 0) return 0;
#ifdef GT_NUM8
    /* frac(8bit)*n >> 8 == the 8.8 fixed multiply of raw ints. Route through the
     * zp fmul entry (like gt_p8_rnd) — nothing between here and the call touches
     * fa/fb — dropping the C-stack marshalling from every flr(rnd(n)). */
    fa = (int)(s & 0xFFU);
    fb = n;
    return gt_fmul_zp();
#else
    /* (s*n) >> 16 == the 16.16 fixed multiply of raw ints — the asm
     * quarter-square core (~300 cycles); the C long multiply this
     * replaces was a 32-iteration shift loop (~1.7k) that ate a third
     * of the measured kill frame */
    return (int)gt_fmul((long)s, (long)n);
#endif
}

#ifdef GT_NUM8
int gt_p8_rnd(int x) {
    unsigned int s = gt_rng_next();
    if (x <= 0) return 0;
    /* fraction in [0,1) from 8 random bits: rnd(x) = frac * x. Route through the
     * zp fmul entry (operands in fa/fb) instead of the cdecl gt_fmul — nothing
     * between the stage and the call touches fa/fb, so it's safe, and it drops
     * the C-stack marshalling from every spawn/particle rnd(). */
    fa = (int)(s & 0xFFU);
    fb = x;
    return gt_fmul_zp();
}

void gt_p8_srand(int seed) {
    gt_rng_state = (unsigned int)seed;
    if (gt_rng_state == 0) gt_rng_state = 0xABCDU;
}
#else
long gt_p8_rnd(long x) {
    unsigned int s = gt_rng_next();
    if (x <= 0) return 0;
    /* fraction in [0,1) from 16 random bits, scaled: rnd(x) = frac * x */
    return gt_fmul((long)s, x);
}

void gt_p8_srand(long seed) {
    gt_rng_state = (unsigned int)(seed >> 16) ^ (unsigned int)seed;
    if (gt_rng_state == 0) gt_rng_state = 0xABCDU;
}
#endif

/* ---- t()/time(): seconds since boot, advanced by gt_endframe ---- */
#ifdef GT_NUM8
int gt_time_acc = 0;
static unsigned char gt_time_rem = 0;

void gt_time_tick(void) {
    /* 1/60 s in 8.8 = 4 + 16/60 exactly (wraps at 128 s — document it) */
    gt_time_acc += 4;
    gt_time_rem += 16;
    if (gt_time_rem >= 60) { gt_time_rem -= 60; gt_time_acc += 1; }
}

int gt_p8_time(void) { return gt_time_acc; }
#else
long gt_time_acc = 0;
static unsigned char gt_time_rem = 0;

void gt_time_tick(void) {
    /* 1/60 s in 16.16 = 1092 + 16/60 exactly */
    gt_time_acc += 1092L;
    gt_time_rem += 16;
    if (gt_time_rem >= 60) { gt_time_rem -= 60; gt_time_acc += 1; }
}

long gt_p8_time(void) { return gt_time_acc; }
#endif
