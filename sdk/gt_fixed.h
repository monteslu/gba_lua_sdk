/* gt_fixed.h — 16.16 fixed-point runtime with PICO-8 semantics.
 * Numbers are signed 32-bit (C long): 16 integer bits, 16 fraction bits.
 * Overflow wraps; division by zero saturates to +/-0x7FFF.FFFF (P8 manual). */
#ifndef GT_FIXED_H
#define GT_FIXED_H

#ifdef GT_NUM8
/* 8.8 mode (--num8): fixed is 8.8 in a 16-bit int — range +-127.996, steps
 * of 1/256. Same public names, int signatures; the emitter never touches the
 * zp fa/fb fastcall (that unit is 16.16 asm and isn't linked). min/max/mid/
 * abs/sgn are scale-invariant, so the int helpers serve both kinds. */
int  gt_fmul(int a, int b);
int  gt_fdiv(int a, int b);

/* zp fastcall for the hot 8.8 multiply (gt_fixed8_asm.s): operands staged in
 * the zp ints fa/fb, argless call. Divide has no zp entry in 8.8 (it's C). */
extern int fa, fb;
#pragma zpsym ("fa")
#pragma zpsym ("fb")
int gt_fmul_zp(void);
int  gt_fsqrt(int x);
int  gt_ffmod(int a, int b);
int  gt_fsin(int turns);
int  gt_fcos(int turns);
int  gt_fatan2(int dx, int dy);
int  gt_p8_rnd(int x);
void gt_p8_srand(int seed);
int  gt_p8_time(void);
int  gt_ifdiv(int a, int b);
int  gt_ifmod(int a, int b);
int  gt_absi(int x);
int  gt_sgni(int x);
int  gt_mini(int a, int b);
int  gt_maxi(int a, int b);
int  gt_midi(int a, int b, int c);
#else

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
#endif /* GT_NUM8 */

void gt_time_tick(void);

#endif
