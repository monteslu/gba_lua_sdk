// gba_fx.c — hardware color effects: alpha blending + brightness fade.
//
// The GBA's blend unit is FREE (it runs in the PPU, no per-pixel CPU cost) and
// composites layers as they're drawn. Three registers drive it:
//   REG_BLDCNT   — which layers are the "top" (source A) + "bottom" (source B)
//                  blend targets, and the mode (alpha / fade-white / fade-black).
//   REG_BLDALPHA — the two alpha coefficients (eva/evb, 0..16 == 0.0..1.0) used
//                  in alpha mode: out = top*eva + bot*evb.
//   REG_BLDY     — the fade strength (ey, 0..16 == 0.0..1.0) for fade modes.
//
// gbalua exposes this as two friendly verbs:
//   blend(layer, alpha)  — make a layer semi-transparent over what's behind it.
//   fade(amount, [white]) — darken (or whiten) the WHOLE screen; the transition
//                           workhorse (level wipes, hit flashes, menu dims).
// Both take PICO-8-style 0.0..1.0 amounts as 16.16 fixed from the emitter.

#include "gba_api.h"

// gbalua layer ids -> BLDCNT layer bits. 0..2 = tile BGs, 3 = the text/HUD
// layer (BG3), 4 = sprites (OBJ). Anything else -> nothing (safe no-op target).
static u16 layer_bld_bit(int layer)
{
    switch (layer) {
        case 0: return BLD_BG0;
        case 1: return BLD_BG1;
        case 2: return BLD_BG2;
        case 3: return BLD_BG3;
        case 4: return BLD_OBJ;   // sprites
        default: return 0;
    }
}

// 16.16 fixed 0.0..1.0 -> a 0..16 blend coefficient (GBA weights are 5-bit but
// saturate at 16 == 1.0; values 17..31 just clamp to full). Rounds to nearest.
static int fx_coeff(long amount16)
{
    long c = (amount16 * 16 + (1 << 15)) >> 16;   // *16, round, drop the .16 frac
    if (c < 0) c = 0;
    if (c > 16) c = 16;
    return (int)c;
}

// blend(layer, alpha): draw `layer` at `alpha` opacity (0.0 = invisible-ish,
// 1.0 = solid) over everything behind it. The classic GBA see-through effect —
// glass, ghosts, shadows, a dimmed UI panel over the game. `layer` is a gbalua
// layer id (0..2 tiles, 3 text, 4 sprites). alpha arrives as 16.16 fixed.
//
// Hardware: the layer is the "top" target at weight eva=alpha; EVERYTHING else
// (the other layers + backdrop) is the "bottom" target at weight evb=(1-alpha),
// so the result is a true cross-fade of this layer with the scene under it.
void gba_blend(int layer, long alpha)
{
    u16 top = layer_bld_bit(layer);
    if (!top) { REG_BLDCNT = BLD_OFF; return; }
    // bottom = every OTHER blendable target (all layers + sprites + backdrop)
    // minus the top layer, so the top blends against whatever's actually behind.
    u16 bot = (BLD_ALL | BLD_BACKDROP) & ~top;
    int eva = fx_coeff(alpha);
    int evb = 16 - eva;
    REG_BLDCNT   = BLD_BUILD(top, bot, 1);   // mode 1 = standard alpha blend
    REG_BLDALPHA = BLDA_BUILD(eva, evb);
}

// fade(amount, white): fade the WHOLE screen toward black (white=0) or white
// (white!=0). amount 0.0 = no fade (normal), 1.0 = fully black/white. The go-to
// transition: fade out at level end, flash white on a hit, dim for a pause menu.
// amount arrives as 16.16 fixed. amount<=0 turns the blend unit off entirely.
void gba_fade(long amount, int white)
{
    int ey = fx_coeff(amount);
    if (ey <= 0) { REG_BLDCNT = BLD_OFF; return; }
    // fade EVERYTHING that's visible (all BG layers + sprites + backdrop).
    u16 targets = BLD_ALL | BLD_BACKDROP;
    // mode 2 = fade to white, mode 3 = fade to black (BLD_WHITE/BLD_BLACK bits).
    int mode = white ? 2 : 3;
    REG_BLDCNT = BLD_BUILD(targets, 0, mode);
    REG_BLDY   = BLDY_BUILD(ey);
}

// blend_off(): turn off all color effects (blend + fade) — back to normal.
void gba_blend_off(void)
{
    REG_BLDCNT   = BLD_OFF;
    REG_BLDALPHA = 0;
    REG_BLDY     = 0;
}

// ---- mosaic (hardware pixelate — FREE in the PPU) --------------------------
// The PPU can shrink each layer's effective resolution by repeating a block of
// bh x bv (BG) or oh x ov (sprite) pixels — the classic pixelate / dissolve /
// heat-shimmer / hit-flash effect. mosaic(n) is a friendly square shortcut;
// mosaic2(bh,bv) sets BG and sprite grid independently in x/y. Size 0 = off
// (1:1). Enabling it also needs the mosaic BIT on each affected layer — done
// here for all BG layers + sprites so the one verb "just works".
static int mosaic_on;
void gba_mosaic2(int bh, int bv)
{
    if (bh < 0) bh = 0; if (bh > 15) bh = 15;
    if (bv < 0) bv = 0; if (bv > 15) bv = 15;
    // REG_MOSAIC: BG grid (bh,bv) + OBJ grid (same, for a unified look).
    REG_MOSAIC = MOS_BUILD(bh, bv, bh, bv);
    int want = (bh || bv);
    if (want != mosaic_on) {
        mosaic_on = want;
        // toggle the mosaic bit on all 4 BG layers (harmless on disabled ones).
        for (int L = 0; L < 4; L++) {
            if (want) (&REG_BG0CNT)[L] |= BG_MOSAIC;
            else      (&REG_BG0CNT)[L] &= ~BG_MOSAIC;
        }
        // sprites: the per-OBJ ATTR0_MOSAIC bit is set by gba_spr* when mosaic
        // is on (see spr_mosaic below); nothing global to toggle for OBJ.
    }
}
void gba_mosaic(int n) { gba_mosaic2(n, n); }
int  gba_mosaic_active(void) { return mosaic_on; }   // spr code queries this

// ---- backdrop + forced blank ----------------------------------------------
// backdrop(color): the color shown wherever NO layer draws (the void behind
// everything; also a blend/fade target). PICO-8 index 0..15 -> the P8 palette,
// or a raw BGR555 for >15. It's just BG palette entry 0.
void gba_backdrop(int color)
{
    extern const unsigned short GBA_P8_PAL15[16];   // defined in gba_api.c
    pal_bg_mem[0] = (color >= 0 && color < 16) ? GBA_P8_PAL15[color] : (COLOR)color;
}

// screen_off()/screen_on(): DCNT_BLANK instantly blanks the display (white) at
// ZERO draw cost — the right way to hide a mid-frame VRAM rebuild / do an instant
// cut. Toggles only the force-blank bit, leaving the mode/layers intact.
void gba_screen_off(void) { REG_DISPCNT |= DCNT_BLANK; }
void gba_screen_on(void)  { REG_DISPCNT &= ~DCNT_BLANK; }

// ---- runtime palette ------------------------------------------------------
// pal(idx, r,g,b): set BG palette color `idx` (0..255) to an 8-bit RGB (0..255
// per channel, quantized to the GBA's 5-bit BGR555). Palette swap (team colors,
// day/night), palette CYCLING (animated water/lava by rotating a few entries
// each frame), full-screen mood shifts — all near-free. spr_col = the OBJ palette.
void gba_pal(int idx, int r, int g, int b)
{
    if (idx < 0 || idx > 255) return;
    pal_bg_mem[idx] = RGB15(r >> 3, g >> 3, b >> 3);
}
void gba_spr_col(int idx, int r, int g, int b)
{
    if (idx < 0 || idx > 255) return;
    pal_obj_mem[idx] = RGB15(r >> 3, g >> 3, b >> 3);
}

// ---- HBlank raster: per-scanline backdrop gradient -------------------------
// The signature GBA trick: change a video register on every scanline via an
// HBlank IRQ. hgradient() drives the BACKDROP color (BG palette 0) per line from
// a 160-entry table — instant sky gradients, sunset skies, underwater tint bands,
// a fire glow behind a HUD. The IRQ reads one table entry per line (cheap). The
// table is an array of BGR555 colors (use gt.rgb / a color(...) helper); a game
// fills it in Lua and passes it once.
// the table is a gbalua `array` (int, holding raw BGR555 color values 0..0x7FFF
// — a game fills it with rgb()/color numbers). NULL = off.
static const int *hgrad_table;

// HBlank ISR: REG_VCOUNT is the line ABOUT to be drawn after this HBlank; write
// its backdrop color. Kept tiny (it runs 160x/frame). Set as an II_HBLANK handler.
static void hgrad_isr(void)
{
    unsigned vc = REG_VCOUNT;
    if (vc < 160 && hgrad_table) pal_bg_mem[0] = (COLOR)(hgrad_table[vc] & 0x7FFF);
}

// hgradient(table): install a 160-color per-line backdrop gradient. `table` is an
// array of raw BGR555 colors (fill with rgb()/color numbers). Pass the same array
// each frame (or nil/0 to turn it off). Enables the HBlank IRQ once.
void gba_hgradient(const int *table)
{
    hgrad_table = table;
    if (table) {
        irq_add(II_HBLANK, hgrad_isr);
        REG_DISPSTAT |= DSTAT_HBL_IRQ;
    } else {
        REG_DISPSTAT &= ~DSTAT_HBL_IRQ;
        irq_delete(II_HBLANK);
    }
}
