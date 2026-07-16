// gba_more.c — parity odds & ends: DMA bulk moves, a 16-bit direct-color bitmap
// mode, and a second affine (rotate/scale) BG layer independent of Mode 7.
//
// These round out the C-SDK surface for games that outgrow the PICO-8-style core:
//   dma_copy/dma_fill — hardware DMA3 block moves (scrolling buffers, streaming).
//   mode15 / pset15 / cls15 / flip15 — a 16-bit BGR555 framebuffer (true color).
//   abg_* — a rotate/scale tile background on BG2 (not the bundled Mode-7 plane).

#include "gba_api.h"

// ---- DMA bulk moves (DMA3) -------------------------------------------------
// dma(dst, src, n): copy n WORDS (the array element size) from src to dst using
// DMA3 — far faster than a CPU loop for big buffers. Both are gbalua arrays
// (int/16.16 => 32-bit words, or array8 => the runtime passes the byte pointer;
// count is in the caller's element units, so it "just works" for either type).
// dma_fill(dst, value, n): fill n words of dst with `value`.
//
// The Lua `array` type is 32-bit (int); `array8` is 8-bit. To keep one simple,
// well-defined verb we DMA in 32-bit units: for `array` n is the element count;
// for `array8`, pass a word count (n = bytes/4). Games mostly dma() same-typed
// arrays, where the element count is exactly right.
void gba_dma(void *dst, const void *src, int n)
{
    if (n <= 0) return;
    dma3_cpy(dst, src, (u32)n * 4);          // n 32-bit words
}
void gba_dma_fill(void *dst, int value, int n)
{
    if (n <= 0) return;
    dma3_fill(dst, (u32)value, (u32)n * 4);
}

// ---- Mode 5 : 16-bit direct-color bitmap -----------------------------------
// A 160x128 true-color (BGR555) framebuffer — plasmas, gradients, photo blits
// beyond the 16-color indexed path. Kept SINGLE-buffered on the front page: it
// sidesteps the Mode-4 frame harness's page flip entirely (which the 8bpp core
// owns), so there's no page fighting. Colors are raw BGR555; rgb15() builds one.
#define M5W 160
#define M5H 128
static u16 *const M5_MEM = (u16 *)0x06000000;   // Mode 5 front page

// switch into the 16-bit bitmap mode. After this, use pset15/cls15 (the PICO-8
// 8bpp cls/pset/spr path is a different mode — don't mix within a frame). Sets
// gba_bitmap16_mode so the frame harness leaves the display registers alone.
extern int gba_bitmap16_mode;
void gba_mode15(void)
{
    // Mode 5's BG2 is affine-transformed — reset the BG2 matrix to identity so a
    // leftover Mode-7 / affine-BG transform doesn't skew the framebuffer.
    REG_BG_AFFINE[2] = bg_aff_default;
    REG_DISPCNT = DCNT_MODE5 | DCNT_BG2;   // front page (DCNT_PAGE clear)
    gba_bitmap16_mode = 1;
}
// build a 16-bit BGR555 color from 0..255 components (quantized to 5 bits each).
int gba_rgb15(int r, int g, int b)
{
    return RGB15(r >> 3, g >> 3, b >> 3);
}
void gba_cls15(int color)
{
    u32 v = (u16)color | ((u32)(u16)color << 16);
    for (int i = 0; i < (M5W * M5H) / 2; i++) ((u32 *)M5_MEM)[i] = v;
}
void gba_pset15(int x, int y, int color)
{
    if ((unsigned)x >= M5W || (unsigned)y >= M5H) return;
    M5_MEM[y * M5W + x] = (u16)color;
}
// fill a w x h rectangle in the 16-bit bitmap — the fast way to paint blocks
// (a coarse plasma, tiles, gradients) without a per-pixel Lua loop.
void gba_fillrect15(int x, int y, int w, int h, int color)
{
    if (w <= 0 || h <= 0) return;
    int x1 = x + w, y1 = y + h;
    if (x < 0) x = 0; if (y < 0) y = 0;
    if (x1 > M5W) x1 = M5W; if (y1 > M5H) y1 = M5H;
    u16 c = (u16)color;
    for (int yy = y; yy < y1; yy++) {
        u16 *row = &M5_MEM[yy * M5W];
        for (int xx = x; xx < x1; xx++) row[xx] = c;
    }
}
// present: single-buffered, so drawing already shows. Kept as a no-op verb so
// game code can call flip15() harmlessly and stay portable if buffering changes.
void gba_flip15(void) { }

// ---- second affine BG (BG2 rotate/scale, not the Mode-7 plane) --------------
// A general affine tile layer the game controls directly: load a tileset + an
// affine (1-byte-per-cell) map, then set a per-frame rotate/scale/scroll. Unlike
// gba_mode7 (which shows the bundled --mode7 plane), this takes the game's own
// tiles/map, so you can spin a logo, a menu, or a second scaled world.
//
// Affine BGs use 8bpp tiles and a square map (16/32/64/128 tiles per side). The
// game supplies tile pixels + palette + a map. To keep ONE simple verb, tiles and
// palette come in as 8bpp bytes and BGR555 halfwords packed into gbalua arrays;
// the map is an array8 of tile indices. Tiles -> char-block 0, map -> screen-block
// 8 (past the text/BG char-blocks). Call abg_setup once, then abg_cam each frame.
//
// abg_setup(tiles, ntiles, map, msize, pal):
//   tiles = array8 of 8bpp pixels (ntiles * 64 bytes, one 8x8 tile each)
//   map   = array8 of msize*msize tile indices
//   pal   = array of up to 256 BGR555 colors (0 = keep the current BG palette)
static int abg_msize;      // map size in tiles (16/32/64/128), 0 = not set up
void gba_abg_setup(const unsigned char *tiles, int ntiles,
                   const unsigned char *map, int msize,
                   const int *pal)
{
    if (pal) for (int i = 0; i < 256; i++) pal_bg_mem[i] = (u16)(pal[i] & 0x7FFF);
    // tiles: 8bpp, 64 bytes/tile, into char-block 0 (write as bytes; VRAM needs
    // 16-bit stores, so pack pairs).
    volatile u16 *tdst = (u16 *)tile_mem[0];
    for (int i = 0; i + 1 < ntiles * 64; i += 2)
        tdst[i >> 1] = (u16)(tiles[i] | (tiles[i + 1] << 8));
    // affine map -> screen-block 8 (1 byte per cell), packed as 16-bit stores.
    volatile u16 *mdst = (u16 *)se_mem[8];
    int cells = msize * msize;
    for (int i = 0; i + 1 < cells; i += 2)
        mdst[i >> 1] = (u16)(map[i] | (map[i + 1] << 8));
    abg_msize = msize;
    int szbits = msize <= 16 ? 0 : msize <= 32 ? 1 : msize <= 64 ? 2 : 3;
    REG_BG2CNT = BG_CBB(0) | BG_SBB(8) | BG_8BPP | BG_WRAP | (szbits << 14);
    REG_DISPCNT = (REG_DISPCNT & ~DCNT_MODE_MASK) | DCNT_MODE1 | DCNT_BG2;
}
// abg_cam(x, y, angle, zoom): place the affine camera. x,y = world point pinned
// to the screen center (16.16); angle = PICO-8 turns (16.16); zoom = 16.16 scale
// (1.0 normal, >1 zooms in). Same proven bg_rotscale_ex path as gba_mode7_cam.
void gba_abg_cam(long x, long y, long angle, long zoom)
{
    if (!abg_msize) return;
    BG_AFFINE bgaff;
    AFF_SRC_EX asx;
    asx.tex_x = (s32)(x >> 8);         // 16.16 world point -> 24.8
    asx.tex_y = (s32)(y >> 8);
    asx.scr_x = 120;                   // pin it to the display center
    asx.scr_y = 80;
    long z = zoom > 0 ? zoom : (1 << 16);
    s32 step = (s32)(((long)1 << 24) / z);   // per-pixel step = 1/zoom, in 8.8
    if (step < 1) step = 1;
    asx.sx = (s16)step;
    asx.sy = (s16)step;
    asx.alpha = (u16)(angle & 0xFFFF); // turns(16.16) -> [0,0xFFFF]
    bg_rotscale_ex(&bgaff, &asx);
    REG_BG_AFFINE[2] = bgaff;          // BG2's affine slot
}
void gba_abg_off(void)
{
    REG_DISPCNT &= ~DCNT_BG2;
    abg_msize = 0;
}
