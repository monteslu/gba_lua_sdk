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
#define gt_p8_srand GT_M(gt_p8_srand)
#define gt_p8_time  GT_M(gt_p8_time)
#define gt_time_tick GT_M(gt_time_tick)

#include "gt_fixed.h"
#include "gt_sintab.h"

#ifdef GT_NUM8
/* 8.8 mode: the turn fraction IS the low byte — the table index is free.
 * The ROM table stays 16.16; entries shift to 8.8 on the way out. */
int gt_fsin(int turns) {
    return (int)(gt_sintab[(unsigned char)turns] >> 8);
}

int gt_fcos(int turns) {
    return -(int)(gt_sintab[(unsigned char)(turns + 0x40)] >> 8);
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
int gt_fatan2(int dx, int dy) {
    /* same octant-folded approximation as the 16.16 version below, with the
     * constants rescaled to 8.8 (0.125 -> 32, 0.04345 -> 11, 1.0 -> 256) */
    unsigned char swap = 0, mirror = 0, negate = 0;
    int mx = dx, my = -dy;
    int ax, ay, r, a;
    if (dx == 0 && dy == 0) return 0xC0;
    if (mx < 0) { mirror = 1; ax = -mx; } else ax = mx;
    if (my < 0) { negate = 1; ay = -my; } else ay = my;
    if (ay > ax) { swap = 1; r = gt_fdiv(ax, ay); }
    else         {           r = gt_fdiv(ay, ax); }
    a = gt_fmul(r, 32 + gt_fmul(11, 256 - r));
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
    return (int)(((unsigned long)(s & 0xFFU) * (unsigned int)n) >> 8);
#else
    return (int)(((unsigned long)s * (unsigned int)n) >> 16);
#endif
}

#ifdef GT_NUM8
int gt_p8_rnd(int x) {
    unsigned int s = gt_rng_next();
    if (x <= 0) return 0;
    /* fraction in [0,1) from 8 random bits: rnd(x) = frac * x */
    return gt_fmul((int)(s & 0xFFU), x);
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
