// gba_hw.c — hardware odds & ends: SRAM save/load + a free-running timer.
//
// SAVE: the cart's battery-backed SRAM (0x0E000000, 64 KB) persists across power
// cycles — high scores, unlocks, progress. SRAM is 8-bit-write ONLY (a 16/32-bit
// store there corrupts), so we copy byte-by-byte. A gbalua game keeps its state
// in an array8 and calls save(slot, arr)/load(slot, arr); each slot is a fixed
// 1 KB region so slots never collide.
//
// TIMER: t()/ticks() are frame-granular. A hardware timer (Timer 3, 1024-cycle
// prescaler ≈ 16.4 kHz) gives sub-frame timing for rhythm games + a real profiler.

#include "gba_api.h"

// ---- SRAM save / load ------------------------------------------------------
#define SAVE_SLOT_BYTES 1024              // per-slot budget (16 slots in 16 KB)
#define SAVE_MAGIC      0x5A              // slot[0] marker: "this slot was written"

// save(slot, arr, n): write n bytes of array8 `arr` into SRAM slot. Byte-wise
// (SRAM is 8-bit-only). Stamps a magic byte so load() can tell a written slot
// from blank SRAM. n is clamped to the slot budget (minus the 1 magic byte).
void gba_save(int slot, const unsigned char *arr, int n)
{
    if (slot < 0) return;
    volatile unsigned char *dst = sram_mem + slot * SAVE_SLOT_BYTES;
    if (n < 0) n = 0;
    if (n > SAVE_SLOT_BYTES - 2) n = SAVE_SLOT_BYTES - 2;
    dst[0] = SAVE_MAGIC;
    dst[1] = (unsigned char)n;            // stored length (0..254)
    for (int i = 0; i < n; i++) dst[2 + i] = arr[i];
}

// load(slot, arr, n): read up to n bytes from SRAM slot into `arr`. Returns the
// number of bytes restored, or 0 if the slot was never written (no magic). Lets a
// game do `if load(0, st, 64) > 0 then ...restored... else ...fresh... end`.
int gba_load(int slot, unsigned char *arr, int n)
{
    if (slot < 0) return 0;
    volatile unsigned char *src = sram_mem + slot * SAVE_SLOT_BYTES;
    if (src[0] != SAVE_MAGIC) return 0;   // never saved
    int len = src[1];
    if (len > n) len = n;
    if (len > SAVE_SLOT_BYTES - 2) len = SAVE_SLOT_BYTES - 2;
    for (int i = 0; i < len; i++) arr[i] = src[2 + i];
    return len;
}

// ---- free-running timer ----------------------------------------------------
// Uses Timer 3 (leaves Timer 0/1 for maxmod's sample clock). 1024-cycle prescaler
// so one tick ≈ 61 ns; the 16-bit counter wraps every ~4 ms — fine for measuring a
// routine or sub-frame phase. timer_start resets + runs it; timer_read samples it.
void gba_timer_start(void)
{
    REG_TM3CNT = 0;                       // stop
    REG_TM3D   = 0;                       // reload value 0
    REG_TM3CNT = TM_FREQ_1024 | TM_ENABLE;
}
int gba_timer_read(void)
{
    return (int)REG_TM3D;                 // current 16-bit count
}
