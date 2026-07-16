// gba_win.c — hardware WINDOWS: rectangular clipping regions, FREE in the PPU.
//
// A window is a screen rectangle where you choose which layers (BG0-3 + sprites +
// blending) are visible. The GBA has two rect windows (WIN0, WIN1). The registers:
//   REG_WIN0H/WIN0V — win0 edges: H = (left<<8)|right, V = (top<<8)|bottom.
//   REG_WININ       — layers visible INSIDE win0 (low byte) and win1 (high byte).
//   REG_WINOUT      — layers visible OUTSIDE all windows (low byte).
//   DCNT_WIN0/WIN1  — enable each window in DISPCNT.
// The classic uses: a spotlight/iris (reveal a box, hide the rest), a HUD panel
// that only shows certain layers, or clipping blending to a region.
//
// gbalua verbs (layer ids match gba_fx: 0..2 tiles, 3 text/HUD, 4 sprites):
//   window(x0,y0,x1,y1)          — SPOTLIGHT: show everything inside the box, hide
//                                  everything outside. The one-call reveal/iris.
//   window_inside(x0,y0,x1,y1, layers) — general win0: `layers` bitmask picks what
//                                  shows inside the box; outside shows nothing.
//   window_outside(layers)       — what shows OUTSIDE the window(s) (default none).
//   window_off()                 — disable windowing (full screen back to normal).
//
// `layers` is a bitmask: bit0=BG0 bit1=BG1 bit2=BG2 bit3=text(BG3) bit4=sprites.
// gbalua exposes the handy constant ALL (=31) and per-name bits via win_layer().

#include "gba_api.h"

// gbalua layer bitmask (bit L) -> GBA WIN_* bits. Our text layer is BG3 (bit 3),
// sprites are bit 4. The GBA bits happen to line up 1:1 (WIN_BG0..WIN_OBJ), so the
// low 5 bits pass through; we just mask to them and always keep WIN_BLD on inside
// so blending (fade/blend) still works within a window.
static inline u16 win_layers(int mask) { return (u16)(mask & 0x1F); }

// clamp a screen coordinate to the valid window-edge range. GBA window edges are
// bytes; the right/bottom edge is EXCLUSIVE and a value > screen size (or a right
// <= left) is treated specially by hardware, so clamp to [0,240]/[0,160].
static inline int clampx(int x) { return x < 0 ? 0 : x > 240 ? 240 : x; }
static inline int clampy(int y) { return y < 0 ? 0 : y > 160 ? 160 : y; }

// set WIN0's rectangle from a (x0,y0)-(x1,y1) box (inclusive-ish; right/bottom are
// the exclusive hardware edges). Enables WIN0 in DISPCNT.
static void set_win0_rect(int x0, int y0, int x1, int y1)
{
    int l = clampx(x0), r = clampx(x1), t = clampy(y0), b = clampy(y1);
    if (r < l) r = l;
    if (b < t) b = t;
    REG_WIN0H = (u16)((l << 8) | r);
    REG_WIN0V = (u16)((t << 8) | b);
    REG_DISPCNT |= DCNT_WIN0;
}

// window(x0,y0,x1,y1): SPOTLIGHT. Everything shows inside the box; nothing outside.
// The go-to reveal/iris/peek effect. (Blending stays enabled inside so a fade or
// blend still applies within the spotlight.)
void gba_window(int x0, int y0, int x1, int y1)
{
    set_win0_rect(x0, y0, x1, y1);
    REG_WININ  = (u16)(WIN_ALL | WIN_BLD);   // inside win0: all layers + blend
    REG_WINOUT = 0;                          // outside: nothing (hidden)
}

// window_inside(x0,y0,x1,y1, layers): define win0 as a box showing only `layers`
// inside it; outside shows nothing (use window_outside to change that). For a HUD
// panel, a minimap box, a masked reveal of specific layers.
void gba_window_inside(int x0, int y0, int x1, int y1, int layers)
{
    set_win0_rect(x0, y0, x1, y1);
    REG_WININ  = (u16)(win_layers(layers) | WIN_BLD);
    REG_WINOUT = REG_WINOUT;   // leave the outside as-is (starts at 0 = hidden)
}

// window_outside(layers): choose which layers are visible OUTSIDE the window(s).
// Default is none (hidden). Pass ALL to show the full scene outside and use the
// window only to OVERRIDE a region (e.g. hide a layer inside a box).
void gba_window_outside(int layers)
{
    REG_WINOUT = (u16)(win_layers(layers) | WIN_BLD);
}

// window_obj(layers): the OBJ WINDOW — sprites flagged with spr_window() become a
// SHAPED mask, and `layers` picks what shows THROUGH that sprite silhouette (a
// sprite-shaped spotlight/reveal, e.g. a torch or a keyhole). Everything outside
// the sprite shapes follows window_outside(). Enables DCNT_WINOBJ.
void gba_window_obj(int layers)
{
    // the OBJ-window layer-select is the HIGH byte of REG_WINOUT (== REG_WINOBJCNT).
    REG_WINOBJCNT = (u8)(win_layers(layers) | WIN_BLD);
    REG_DISPCNT  |= DCNT_WINOBJ;
}

// window_off(): disable all windowing — the whole screen renders normally again.
void gba_window_off(void)
{
    REG_DISPCNT &= ~(DCNT_WIN0 | DCNT_WIN1 | DCNT_WINOBJ);
}
