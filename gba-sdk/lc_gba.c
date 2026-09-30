// lc_gba.c - the GBA platform layer for luacretro's dynamic tier (real PICO-8
// carts compiled to native ARM).
//
// Implements luacretro's runtime/lc_plat.h with libtonc: the 128x128 PICO-8
// screen is shown 1:1 in the middle of mode 4's 240x160 8bpp bitmap (page
// flipped at vblank, colours through BG palette 0-15 which follow PICO-8's
// screen palette), the keypad maps to PICO-8 buttons, cartdata lives in
// battery SRAM, and the synthesizer feeds DirectSound A (timer 0 + DMA1).
// The big runtime buffers live in EWRAM (LC_BIGDATA=.sbss).

#include <tonc.h>
#include "lc.h"
#include "lc_p8.h"
#include "lc_plat.h"

#ifndef GBALUA_ARENA
#define GBALUA_ARENA (120 * 1024)
#endif
#ifndef GBALUA_VSLOTS
#define GBALUA_VSLOTS 1536
#endif
#ifndef GBALUA_AUDIO
#define GBALUA_AUDIO 1
#endif

#define OX 56
#define OY 16

// ---- video --------------------------------------------------------------------------

#define C15(r, g, b) ((u16)(((r) >> 3) | (((g) >> 3) << 5) | (((b) >> 3) << 10)))
static const u16 P8RGB15[32] = {
  C15(0, 0, 0), C15(29, 43, 83), C15(126, 37, 83), C15(0, 135, 81),
  C15(171, 82, 54), C15(95, 87, 79), C15(194, 195, 199), C15(255, 241, 232),
  C15(255, 0, 77), C15(255, 163, 0), C15(255, 236, 39), C15(0, 228, 54),
  C15(41, 173, 255), C15(131, 118, 156), C15(255, 119, 168), C15(255, 204, 170),
  C15(41, 24, 20), C15(17, 29, 53), C15(66, 33, 54), C15(18, 83, 89),
  C15(116, 47, 41), C15(73, 51, 59), C15(162, 136, 121), C15(243, 239, 125),
  C15(190, 18, 80), C15(255, 108, 36), C15(168, 231, 46), C15(0, 181, 67),
  C15(6, 90, 181), C15(117, 70, 101), C15(255, 110, 89), C15(255, 157, 129),
};

// one PICO-8 byte (two 4bpp pixels, low nibble left) -> one mode-4 halfword
static u16 pair16[256];
static int back_page;

static u16 *page_ptr(int p) { return (u16 *)(p ? 0x0600A000 : 0x06000000); }

IWRAM_CODE void lc_plat_present(const uint8_t *screen, const uint8_t *pal, uint8_t mode) {
  (void)mode;
  u16 *dst = page_ptr(back_page) + (OY * 240 + OX) / 2;
  for (int y = 0; y < 128; y++) {
    const uint8_t *src = screen + y * 64;
    u16 *d = dst + y * 120;
    for (int x = 0; x < 64; x++) d[x] = pair16[src[x]];
  }
  extern void gbalua_audio_frame(void);
  VBlankIntrWait();
  // palette and page flip together, inside vblank
  for (int i = 0; i < 16; i++) {
    uint8_t p = pal[i];
    pal_bg_mem[i] = P8RGB15[(p & 0x80) ? 16 + (p & 15) : (p & 15)];
  }
  REG_DISPCNT = DCNT_MODE4 | DCNT_BG2 | (back_page ? DCNT_PAGE : 0);
  back_page ^= 1;
  gbalua_audio_frame();
}

void lc_plat_vsync(void) {
  extern void gbalua_audio_frame(void);
  VBlankIntrWait();
  gbalua_audio_frame();
}

// ---- input ----------------------------------------------------------------------------

uint8_t lc_plat_buttons(int player) {
  if (player != 0) return 0;
  u16 k = ~REG_KEYINPUT & KEY_MASK;
  uint8_t r = 0;
  if (k & KEY_LEFT) r |= 1;
  if (k & KEY_RIGHT) r |= 2;
  if (k & KEY_UP) r |= 4;
  if (k & KEY_DOWN) r |= 8;
  if (k & (KEY_B | KEY_L)) r |= 16;     // O
  if (k & (KEY_A | KEY_R)) r |= 32;     // X
  if (k & KEY_START) r |= 64;           // pause
  return r;
}

// ---- audio: DirectSound A, 8-bit signed, double buffered per frame --------------------

#if GBALUA_AUDIO
#ifndef LC_P8SND_RATE
#define LC_P8SND_RATE 22050
#endif
// 13379 Hz is 224 samples per GBA frame exactly (16.78 MHz / 1254 per sample,
// 280896 cycles per frame).
#define OUT_RATE 13379
#define OUT_N 224
EWRAM_BSS static s8 abuf[2][OUT_N];
EWRAM_BSS static int16_t sbuf[512];
static int abuf_cur;
static u32 src_frac;

static void audio_init(void) {
  REG_SNDSTAT = SSTAT_ENABLE;
  REG_SNDDSCNT = SDS_DMG100 | SDS_A100 | SDS_AR | SDS_AL | SDS_ATMR0 | SDS_ARESET;
  REG_TM0D = 65536 - 1254;
  REG_TM0CNT = TM_ENABLE;
}

IWRAM_CODE void gbalua_audio_frame(void) {
  // restart DMA on the buffer filled last frame, then fill the other one
  REG_DMA1CNT = 0;
  REG_DMA1SAD = (u32)abuf[abuf_cur];
  REG_DMA1DAD = (u32)&REG_FIFO_A;
  REG_DMA1CNT = DMA_DST_FIXED | DMA_REPEAT | DMA_32 | DMA_AT_SPECIAL | DMA_ENABLE;
  abuf_cur ^= 1;
  s8 *out = abuf[abuf_cur];
#if LC_P8SND_RATE == OUT_RATE
  lc_p8_audio_fill(sbuf, OUT_N);
  for (int i = 0; i < OUT_N; i++) out[i] = (s8)(sbuf[i] >> 8);
#else
  // resample LC_P8SND_RATE -> 13379 Hz, nearest sample
  u32 step = (u32)(((u64)LC_P8SND_RATE << 16) / OUT_RATE);
  u32 need = (u32)((src_frac + step * OUT_N) >> 16);
  if (need > 512) need = 512;
  lc_p8_audio_fill(sbuf, (int)need);
  u32 pos = src_frac & 0xffff;
  for (int i = 0; i < OUT_N; i++) {
    u32 si = pos >> 16;
    out[i] = (s8)(sbuf[si < need ? si : need - 1] >> 8);
    pos += step;
  }
  src_frac = pos - (need << 16);
#endif
}
#else
static void audio_init(void) {}
void gbalua_audio_frame(void) {}
#endif

// ---- cartdata in SRAM ------------------------------------------------------------------

// A string the emulators scan for to pick 32 KB battery SRAM.
const char gbalua_save_type[] __attribute__((used)) = "SRAM_V113";

#define SRAM_BASE ((volatile u8 *)0x0E000000)

int lc_plat_cartdata_load(const char *id, uint8_t *data256) {
  volatile u8 *s = SRAM_BASE;
  if (s[0] != 'L' || s[1] != 'C') return 0;
  for (int i = 0; i < 64; i++) {
    if ((char)s[2 + i] != id[i]) return 0;
    if (!id[i]) break;
  }
  for (int i = 0; i < 256; i++) data256[i] = s[66 + i];
  return 1;
}

void lc_plat_cartdata_save(const char *id, const uint8_t *data256) {
  volatile u8 *s = SRAM_BASE;
  s[0] = 'L';
  s[1] = 'C';
  int i = 0;
  for (; i < 63 && id[i]; i++) s[2 + i] = (u8)id[i];
  for (; i < 64; i++) s[2 + i] = 0;
  for (int k = 0; k < 256; k++) s[66 + k] = data256[k];
}

// ---- misc --------------------------------------------------------------------------------

uint32_t lc_plat_seed(void) {
#ifdef GBALUA_SEED
  return GBALUA_SEED;
#else
  return REG_VCOUNT * 2654435761u ^ REG_TM0D;
#endif
}

void lc_plat_datetime(int out[6]) {
  out[0] = 2024; out[1] = 1; out[2] = 1; out[3] = 12; out[4] = 0; out[5] = 0;
}

void lc_plat_log(const char *s, size_t len) { (void)s; (void)len; }

_Noreturn void lc_plat_fatal(const char *msg) {
  lc_p8mem[P8_SCRMAP] = 0x60;
  for (int i = 0; i < 16; i++) lc_p8mem[P8_SCREENPAL + i] = (uint8_t)i;
  lc_p8mem[P8_COLORMASK] = 0xff;
  lc_p8_reset_drawstate();
  lc_p8_cls(0);
  uint32_t n = 0;
  while (msg[n]) n++;
  lc_p8_print((const uint8_t *)"runtime error", 13, 1, 0, 0, 1, 8);
  lc_p8_print((const uint8_t *)msg, n, 1, 0, 8, 1, 7);
  for (;;) lc_plat_present(lc_p8_screenbuf(), lc_p8mem + P8_SCREENPAL, 0);
}

// ---- entry ---------------------------------------------------------------------------------

EWRAM_BSS static uint64_t arena[GBALUA_ARENA / 8];
EWRAM_BSS static uint64_t vstack[GBALUA_VSLOTS];
extern char __bss_end__[];    // IWRAM: the C stack grows down to here

int main(void) {
  char base;
  irq_init(NULL);
  irq_add(II_VBLANK, NULL);
  for (int b = 0; b < 256; b++) pair16[b] = (u16)((b & 15) | ((b >> 4) << 8));
  // border: palette index 16, black, on both pages
  pal_bg_mem[16] = 0;
  for (int p = 0; p < 2; p++) {
    u16 *pg = page_ptr(p);
    for (int i = 0; i < 240 * 160 / 2; i++) pg[i] = 0x1010;
  }
  REG_DISPCNT = DCNT_MODE4 | DCNT_BG2;
  back_page = 1;
  for (u32 i = 0; i < LC_P8_MEMSIZE; i++) lc_p8mem[i] = 0;
  audio_init();
  size_t cstack = (size_t)(&base - __bss_end__) - 256;   // leave the IRQ stack
  lc_p8_run(arena, sizeof arena, vstack, GBALUA_VSLOTS, &base, cstack);
}
