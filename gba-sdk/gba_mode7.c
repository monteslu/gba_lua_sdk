// gba_mode7.c — the GBA's signature effect: an AFFINE background (BG2) you can
// rotate, scale, and scroll as one flat plane. This is the "Mode 7" look —
// F-Zero / Mario Kart ground planes, spinning menus, a map that zooms and turns.
//
// Regular BGs (gba_bg.c) only scroll. An AFFINE bg additionally runs every pixel
// through a 2x2 matrix (pa,pb,pc,pd) + a reference point (dx,dy), so the hardware
// can rotate/scale the whole layer for FREE. The catch vs regular BGs:
//   * it lives on BG2 in Mode 1 (BG0/1 regular + BG2 affine) — we use Mode 1 so a
//     regular HUD/text layer can still sit on top.
//   * tiles are 8bpp (256 colors, 1 byte/pixel); the map is 1 byte per cell.
//   * the map is SQUARE: 16/32/64/128 tiles a side (128..1024 px). BG_WRAP makes
//     it tile infinitely — essential for an endless ground plane.
//
// The affine map data comes from the build: --mode7 plane.png is converted to
// 8bpp tiles + a 256-color palette + a square map (see gba_mode7_asset.h).
//
// API (Lua):
//   mode7()                       — show the bundled affine plane (call once).
//   mode7_cam(x, y, angle, zoom)  — per frame: place the camera over the plane.
//        x,y   = world position the screen CENTERS on (pixels, 16.16 or int).
//        angle = rotation in PICO-8 turns (16.16; 0..1 == one full turn).
//        zoom  = 16.16 scale (1.0 = 1:1, 2.0 = zoomed in 2x, 0.5 = out).
//   mode7_off()                   — hide the affine layer, back to normal.

#include "gba_api.h"
#include "gba_mode7_asset.h"   // GBA_HAS_MODE7 + (if 1) m7_tiles/m7_map/m7_pal/m7_side/m7_size

#if GBA_HAS_MODE7

// affine BG2 uses charblock 1 for its 8bpp tiles (charblock 0 is the regular
// tile layers') and screenblock 20 for its map — both clear of the regular BG
// screenblocks (28..31) and OBJ VRAM (0x06010000).
#define M7_CBB   1
#define M7_SBB   20

// BG_AFF_* size flag from the map side (tiles): 16->16x16, 32->32x32, etc.
static u16 m7_size_flag(void)
{
    switch (m7_side) {
        case 16:  return BG_AFF_16x16;
        case 32:  return BG_AFF_32x32;
        case 64:  return BG_AFF_64x64;
        default:  return BG_AFF_128x128;   // 128
    }
}

static int m7_ready;

// mode7(): load the affine plane onto BG2 and switch to Mode 1 (so BG0/1 and the
// text/HUD layer can still draw on top). Call once (usually in _init).
void gba_mode7(void)
{
    // 8bpp tiles into charblock 1 (16 words = 64 bytes per 8bpp tile).
    memcpy32(&tile_mem[M7_CBB][0], m7_tiles, m7_ntiles * 16);
    // the affine bg shares the 256-color BG palette (bank 0 spans all 256).
    memcpy32(pal_bg_mem, m7_pal, 256 / 2);
    // the 1-byte-per-cell affine map goes into the screenblock as raw bytes.
    memcpy32(&se_mem[M7_SBB][0], m7_map, (m7_side * m7_side) / 4);

    // BG2CNT: charblock 1, screenblock 20, 8bpp is implicit for affine, WRAP on
    // (endless plane), priority 2 (behind the HUD/text at 0, with room for BG0/1).
    REG_BG2CNT = BG_CBB(M7_CBB) | BG_SBB(M7_SBB) | BG_WRAP | BG_PRIO(2) | m7_size_flag();

    // Mode 1: BG0/1 regular + BG2 affine. Keep OBJ on so sprites composite over it.
    REG_DISPCNT = DCNT_MODE1 | DCNT_BG2 | DCNT_OBJ | DCNT_OBJ_1D;
    m7_ready = 1;

    // start centered, unrotated, 1:1.
    gba_mode7_cam(0, 0, 0, 1 << 16);
}

// mode7_cam(x, y, angle, zoom): place the camera over the plane. We rotate/scale
// about the plane point (x,y) and pin it to the SCREEN CENTER (120,80), so moving
// (x,y) pans the world, angle spins it, zoom scales it — all in hardware.
void gba_mode7_cam(long x, long y, long angle, long zoom)
{
    if (!m7_ready) return;
    BG_AFFINE bgaff;
    AFF_SRC_EX asx;

    // texture anchor: the world point under the screen center, in .8 fixed. Our
    // x/y arrive as 16.16 (or plain int promoted) — convert 16.16 -> 24.8.
    asx.tex_x = (s32)(x >> 8);
    asx.tex_y = (s32)(y >> 8);
    // screen anchor = the display center (that texel lands here).
    asx.scr_x = 120;
    asx.scr_y = 80;
    // zoom: bigger zoom = see LESS of the plane (more magnified). The affine P is
    // an INVERSE map (screen->texture), so the per-pixel step = 1/zoom. Convert
    // 16.16 zoom -> an 8.8 step of 1/zoom. Guard against 0.
    long z = zoom > 0 ? zoom : (1 << 16);
    // (1/zoom) in 8.8 = (1<<24)/zoom_16.16.  Clamp to a sane range.
    s32 step = (s32)(((long)1 << 24) / z);
    if (step < 1) step = 1;
    asx.sx = (s16)step;
    asx.sy = (s16)step;
    // angle: PICO-8 turns (16.16) -> libtonc's [0,0xFFFF] CCW angle. Low 16 bits
    // of the .16 fraction ARE the 0..1 turn scaled to 0..0xFFFF.
    asx.alpha = (u16)(angle & 0xFFFF);

    bg_rotscale_ex(&bgaff, &asx);            // compute pa/pb/pc/pd + dx/dy
    REG_BG_AFFINE[2] = bgaff;                 // BG2's affine slot (index 2)
}

void gba_mode7_off(void)
{
    m7_ready = 0;
    REG_DISPCNT &= ~DCNT_BG2;
}

#else  // no --mode7 asset: the verbs are safe no-ops so a game still links.

void gba_mode7(void) {}
void gba_mode7_cam(long x, long y, long angle, long zoom) { (void)x; (void)y; (void)angle; (void)zoom; }
void gba_mode7_off(void) {}

#endif
