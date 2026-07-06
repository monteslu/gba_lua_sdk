/* gt_fixed.c — 16.16 fixed-point core, PICO-8 semantics.
 * Written as plain C first (cc65 compiles it correctly); the hot routines
 * (fmul, fdiv) are the designated targets for hand-written 65C02 replacements
 * once profiling says so. */
#include "gt_fixed.h"

#ifdef GT_NUM8
/* ---- 8.8 mode: fixed is a 16-bit int, 8 fraction bits ------------------- */

/* GT_NUM8_ASM: gt_fmul is hand-tuned 65C02 in gt_fixed8_asm.s (quarter-square
 * partials; bit-identical FLOOR semantics to this C reference, which is kept
 * for provenance and host-side validation). */
#define GT_NUM8_ASM 1

#ifndef GT_NUM8_ASM
int gt_fmul(int a, int b) {
    /* (a*b) >> 8 through a 32-bit intermediate; wraps like the 16.16 core */
    return (int)(((long)a * b) >> 8);
}
#endif

int gt_fdiv(int a, int b) {
    long q;
    if (b == 0) return (a < 0) ? (int)0x8001 : 0x7FFF;   /* P8 saturates */
    q = ((long)a << 8) / b;
    return (int)q;
}

int gt_fsqrt(int x) {
    /* Newton on 8.8: two refinements from an 8-bit integer seed */
    int res, t;
    unsigned char i;
    if (x <= 0) return 0;
    res = (x >= 256) ? (x >> 1) : 256;
    for (i = 0; i < 8; ++i) {
        t = gt_fdiv(x, res);
        res = (res + t) >> 1;
        if (res <= 0) { res = 1; break; }
    }
    return res;
}

int gt_ffmod(int a, int b) {
    /* floored modulo, sign of divisor: masking the fraction bits of the
     * quotient IS floor toward -inf in two's complement 8.8 (the exact
     * parallel of the 16.16 version below) */
    int q;
    if (b == 0) return 0;
    q = gt_fdiv(a, b) & (int)0xFF00;
    return a - gt_fmul(q, b);
}

#else /* !GT_NUM8: the 16.16 core */

/* GT_FIXED_ASM: gt_fmul and gt_fdiv are provided by hand-tuned 65C02 in
 * gt_fixed_asm.s (bit-identical PICO-8 semantics; a fixed-mul statement drops
 * from ~9.3K to ~2.8K cycles, ~3.3x, measured on the fmul microbench).
 * Defined by default; #undef it to fall back to these C references (kept below
 * for provenance and host-side validation). */
#define GT_FIXED_ASM 1

#ifndef GT_FIXED_ASM
long gt_fmul(long a, long b) {
    /* (a*b) >> 16 via four 16x16 partial products on magnitudes.
     * Wraps on overflow like the hardware (P8 wraps too; exact bit-equality
     * at overflow edges is not guaranteed by the sign-magnitude split). */
    unsigned char neg = 0;
    unsigned long ua, ub, res;
    unsigned int ah, al, bh, bl;
    if (a < 0) { ua = (unsigned long)-a; neg ^= 1; } else ua = (unsigned long)a;
    if (b < 0) { ub = (unsigned long)-b; neg ^= 1; } else ub = (unsigned long)b;
    ah = (unsigned int)(ua >> 16); al = (unsigned int)(ua & 0xFFFF);
    bh = (unsigned int)(ub >> 16); bl = (unsigned int)(ub & 0xFFFF);
    res  = ((unsigned long)ah * bh) << 16;
    res += (unsigned long)ah * bl;
    res += (unsigned long)al * bh;
    res += ((unsigned long)al * bl) >> 16;
    return neg ? -(long)res : (long)res;
}

long gt_fdiv(long a, long b) {
    /* q = (a << 16) / b by restoring division over the 48-bit dividend.
     * P8: dividing by zero saturates (manual: 0x7fff.ffff / -0x7fff.ffff). */
    unsigned char neg = 0;
    unsigned char i;
    unsigned long ua, ub, q, r;
    if (b == 0) return (a < 0) ? (long)0x80000001L : (long)0x7FFFFFFFL;
    if (a < 0) { ua = (unsigned long)-a; neg ^= 1; } else ua = (unsigned long)a;
    if (b < 0) { ub = (unsigned long)-b; neg ^= 1; } else ub = (unsigned long)b;
    q = 0; r = 0;
    for (i = 0; i < 48; ++i) {
        r <<= 1;
        if (i < 32) r |= (ua >> (31 - i)) & 1;
        q <<= 1;
        if (r >= ub) { r -= ub; q |= 1; }
    }
    return neg ? -(long)q : (long)q;
}
#endif /* !GT_FIXED_ASM */

/* FLASH2M: sqrt/ffmod are cold, loop-heavy bodies (spawn-time math, and
 * ffmod is the documented 19k-cycle footgun ports avoid) — they ride in
 * bank 0; fixed stubs bank-switch. gt_cur_bank lives in gt_bank.s. */
#ifdef GT_BANKED
extern unsigned char gt_cur_bank;
extern void __fastcall__ gt_bank(unsigned char b);
#pragma code-name ("B0CODE")
#define GT_FSQRT gt_fsqrt_impl
#define GT_FFMOD gt_ffmod_impl
static long gt_fsqrt_impl(long x);
static long gt_ffmod_impl(long a, long b);
#else
#define GT_FSQRT gt_fsqrt
#define GT_FFMOD gt_ffmod
#endif
#ifdef GT_BANKED
static
#endif
long GT_FSQRT(long x) {
    /* canonical bit-by-bit integer sqrt of the raw bits, then scale:
     * sqrt(bits/2^16)*2^16 == sqrt(bits)*2^8. One Newton step recovers the
     * low fraction bits. sqrt of negative = 0 (P8). */
    unsigned long v, res, bit, t;
    if (x <= 0) return 0;
    v = (unsigned long)x;
    res = 0;
    bit = 0x40000000UL;
    while (bit > v) bit >>= 2;
    while (bit) {
        if (v >= res + bit) { v -= res + bit; res = (res >> 1) + bit; }
        else res >>= 1;
        bit >>= 2;
    }
    res <<= 8;
    if (res) {
        t = (unsigned long)gt_fdiv(x, (long)res);
        res = (res + t) >> 1;
    }
    return (long)res;
}

#ifdef GT_BANKED
static
#endif
long GT_FFMOD(long a, long b) {
    /* floored modulo: a - flr(a/b)*b, result takes the divisor's sign.
     * Masking the fraction bits of the quotient IS floor toward -inf in
     * two's complement 16.16. */
    long q;
    if (b == 0) return 0;
    q = gt_fdiv(a, b) & (long)0xFFFF0000L;
    return a - gt_fmul(q, b);
}
#ifdef GT_BANKED
#pragma code-name ("CODE")
long gt_fsqrt(long x) {
    unsigned char saved_bank = gt_cur_bank;
    long r;
    gt_bank(0);
    r = gt_fsqrt_impl(x);
    gt_bank(saved_bank);
    return r;
}
long gt_ffmod(long a, long b) {
    unsigned char saved_bank = gt_cur_bank;
    long r;
    gt_bank(0);
    r = gt_ffmod_impl(a, b);
    gt_bank(saved_bank);
    return r;
}
#endif
#endif /* !GT_NUM8 */

int gt_ifdiv(int a, int b) {
    int q, r;
    if (b == 0) return (a < 0) ? -32767 : 32767;
    q = a / b;             /* C truncates toward zero */
    r = a - q * b;
    if (r != 0 && ((r < 0) != (b < 0))) --q;  /* correct to floor */
    return q;
}

int gt_ifmod(int a, int b) {
    int r;
    if (b == 0) return 0;
    r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) r += b;
    return r;
}

int  gt_absi(int x)  { return x < 0 ? -x : x; }
int  gt_sgni(int x)  { return x < 0 ? -1 : 1; }
int  gt_mini(int a, int b)  { return a < b ? a : b; }
int  gt_maxi(int a, int b)  { return a > b ? a : b; }
#ifndef GT_NUM8
long gt_absf(long x) { return x < 0 ? -x : x; }
int  gt_sgnf(long x) { return x < 0 ? -1 : 1; }
long gt_minf(long a, long b) { return a < b ? a : b; }
long gt_maxf(long a, long b) { return a > b ? a : b; }
#endif

int gt_midi(int a, int b, int c) {
    int t;
    if (a > b) { t = a; a = b; b = t; }
    if (b > c) { b = c; }
    return a > b ? a : b;
}

#ifndef GT_NUM8
long gt_midf(long a, long b, long c) {
    long t;
    if (a > b) { t = a; a = b; b = t; }
    if (b > c) { b = c; }
    return a > b ? a : b;
}
#endif
