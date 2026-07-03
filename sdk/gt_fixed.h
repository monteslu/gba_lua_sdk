/* gt_fixed.h — 16.16 fixed-point runtime with PICO-8 semantics.
 * Numbers are signed 32-bit (C long): 16 integer bits, 16 fraction bits.
 * Overflow wraps; division by zero saturates to +/-0x7FFF.FFFF (P8 manual). */
#ifndef GT_FIXED_H
#define GT_FIXED_H

long gt_fmul(long a, long b);
long gt_fdiv(long a, long b);

/* zero-page fastcall ABI for the two hot 16.16 ops (gt_fixed_asm.s). The
 * emitter, at a multiply/divide whose operands don't themselves contain a
 * fixed mul/div, stores the operands straight into the zp longs fa/fb and
 * calls the argless entry — dropping cc65's per-call C-stack marshalling
 * (the `jsr pusheax` that spills the first arg). Nested/mixed sites still use
 * the cdecl gt_fmul/gt_fdiv above (the zp slots would collide). */
extern long fa, fb;
#pragma zpsym ("fa")
#pragma zpsym ("fb")
long gt_fmul_zp(void);          /* returns fa*fb  (16.16), sign of fa^fb */
long gt_fdiv_zp(void);          /* returns fa/fb  (16.16), /0 saturates  */

long gt_fsqrt(long x);
long gt_ffmod(long a, long b);      /* floored modulo, sign of divisor */
int  gt_ifdiv(int a, int b);        /* flr(a/b) for ints */
int  gt_ifmod(int a, int b);        /* floored modulo for ints */

int  gt_absi(int x);
long gt_absf(long x);
int  gt_sgni(int x);                /* sgn(0) == 1, per PICO-8 */
int  gt_sgnf(long x);
int  gt_mini(int a, int b);
int  gt_maxi(int a, int b);
int  gt_midi(int a, int b, int c);
long gt_minf(long a, long b);
long gt_maxf(long a, long b);
long gt_midf(long a, long b, long c);

long gt_fsin(long turns);
long gt_fcos(long turns);
long gt_fatan2(long dx, long dy);
long gt_p8_rnd(long x);
void gt_p8_srand(long seed);
long gt_p8_time(void);

#endif
