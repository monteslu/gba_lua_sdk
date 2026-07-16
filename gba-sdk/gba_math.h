// gba_math.h — 16.16 fixed-point math runtime (see gba_math.c).
#ifndef GBA_MATH_H
#define GBA_MATH_H

long gba_fmul(long a, long b);
long gba_fdiv(long a, long b);
long gba_fsin(long turns);
long gba_fcos(long turns);
long gba_fsqrt(long x);
long gba_fatan2(long dx, long dy);
long gba_rnd(long x);
void gba_srand(long seed);
void gba_time_tick(void);
long gba_time(void);
unsigned int gba_ticks(void);   // frame counter since boot (animation timing)
void gba_time_reset(void);      // reset time + frame counter (run()/reset)

#endif
