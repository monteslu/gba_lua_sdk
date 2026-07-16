// gba_math.c — the 16.16 fixed-point math runtime for gba-lua.
//
// PICO-8 number model: 16.16 fixed point. On the ARM7TDMI these are cheap —
// hardware multiply + fast divide — so fmul/fdiv are plain C with a 64-bit
// intermediate (NO asm, unlike the GameTank's hand-tuned 6502 versions). sin/cos
// are a 256-entry table (PICO-8 screen-space-inverted); atan2/rnd/time reuse the
// portable gt-lua logic. The emitter inlines fixed *,/,% directly; these back the
// math BUILTINS (sin/cos/sqrt/atan2/rnd/t) the emitter calls as gba_f*.

#include "gba_math.h"
#include "gba_sintab.h"   // gba_sintab[256], 16.16, P8-inverted

typedef long fx;   // 16.16

fx gba_fmul(fx a, fx b) { return (fx)(((long long)a * b) >> 16); }
fx gba_fdiv(fx a, fx b) { if (b == 0) return a < 0 ? (fx)0x80000000 : (fx)0x7FFFFFFF; return (fx)((((long long)a) << 16) / b); }

fx gba_fsin(fx turns) { return gba_sintab[(unsigned char)(((unsigned long)turns >> 8) & 0xFF)]; }
fx gba_fcos(fx turns) { return -gba_sintab[(unsigned char)((((unsigned long)turns + 0x4000UL) >> 8) & 0xFF)]; }

// integer sqrt of a 16.16 value -> 16.16 (Newton's method, a few iterations).
fx gba_fsqrt(fx x) {
    if (x <= 0) return 0;
    // sqrt(x) in 16.16 = sqrt(x_raw * 65536) = sqrt(x_raw) << 8 (x_raw is the int).
    // Do it in 64-bit: result r with r*r ~= x<<16.
    unsigned long long v = ((unsigned long long)(unsigned long)x) << 16;
    unsigned long long r = v, last;
    if (r == 0) return 0;
    // initial guess
    unsigned long long g = 1;
    while (g * g < v) g <<= 1;
    r = g;
    do { last = r; r = (r + v / r) >> 1; } while (r < last);
    return (fx)last;
}

// atan2 -> PICO-8 turns [0,1) in 16.16. Reuses the gt-lua first-octant approx.
fx gba_fatan2(fx dx, fx dy) {
    unsigned char swap = 0, mirror = 0, negate = 0;
    fx mx = dx, my = -dy;
    fx ax, ay, r, a;
    if (dx == 0 && dy == 0) return 0xC000L;
    if (mx < 0) { mirror = 1; ax = -mx; } else ax = mx;
    if (my < 0) { negate = 1; ay = -my; } else ay = my;
    if (ay > ax) { swap = 1; r = gba_fdiv(ax, ay); }
    else         {           r = gba_fdiv(ay, ax); }
    a = gba_fmul(r, 0x2000L + gba_fmul(0x0B20L, 0x10000L - r));
    if (swap) a = 0x4000L - a;
    if (mirror) a = 0x8000L - a;
    if (negate) a = -a;
    return a & 0xFFFFL;
}

// ---- rng (16-bit xorshift) ----
static unsigned int rng_state = 0xABCDu;
static unsigned int rng_next(void) {
    unsigned int x = rng_state;
    x ^= x << 7; x ^= x >> 9; x ^= x << 8;
    rng_state = x ? x : 0xABCDu;
    return rng_state;
}

// rnd(x): frac in [0,1) from 16 random bits, scaled by x. 16.16.
fx gba_rnd(fx x) {
    unsigned int s = rng_next();
    if (x <= 0) return 0;
    return gba_fmul((fx)s, x);
}
void gba_srand(fx seed) {
    rng_state = (unsigned int)(seed >> 16) ^ (unsigned int)seed;
    if (rng_state == 0) rng_state = 0xABCDu;
}

// ---- t()/time(): seconds since boot, advanced each frame ----
static fx time_acc = 0;
static unsigned char time_rem = 0;
// frame counter since boot (advanced with time). The animation helpers time off
// this; ticks() also reads it. Reset on run()/reset via gba_time_reset().
static unsigned int frame_no = 0;
void gba_time_tick(void) {
    time_acc += 1092L;                 // 1/60 s in 16.16 = 1092 + 16/60
    time_rem += 16;
    if (time_rem >= 60) { time_rem -= 60; time_acc += 1; }
    frame_no++;
}
fx gba_time(void) { return time_acc; }
unsigned int gba_ticks(void) { return frame_no; }
void gba_time_reset(void) { time_acc = 0; time_rem = 0; frame_no = 0; }
