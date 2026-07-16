// gba_bg.c — hardware tiled backgrounds (Mode 0). The real game path.
//
// 4 BG layers, each a tilemap over an 8x8 tileset, scrolled by hardware. This is
// how scrolling GBA games work — the CPU never repaints the background, it just
// writes two scroll registers. Tilemaps up to 512x512 px; the camera scrolls a
// 240x160 window over them.
//
// VRAM layout (we own it, the user never sees charblocks/screenblocks):
//   charblock 0 (0x06000000, 16 KB) — shared tile data for all 4 layers,
//     each layer gets a 4 KB (128-tile) slice: layer L tiles at 128*L.
//   screenblocks 28..31 (2 KB each) — one 32x32 map per layer (layer L -> sbb 28+L).
// This keeps all BG data below OBJ VRAM (0x06010000) and clear of the sprites.

#include "gba_api.h"
#include "gba_map_asset.h"   // GBA_HAS_MAP + (if 1) map_tiles/map_data/map_pal/map_cols/map_rows

#define BG_CBB_SHARED   0            // all layers share charblock 0 for tiles
#define BG_TILES_PER_LAYER 128       // 128 4bpp tiles (4 KB) per layer slot
#define BG_SBB_BASE     28           // screenblocks 28,29,30,31 for layers 0..3

// per-layer camera scroll + a parallax factor (256 = 1:1). The camera moves all
// layers; each layer's actual scroll = camera * factor/256 (+ its own offset).
static int cam_x, cam_y;
static int layer_factor[4] = { 256, 256, 256, 256 };
static int layer_ox[4], layer_oy[4];   // per-layer fixed offset (HUD/parallax)
static u16 layer_size[4];               // BG_REG_* size flag (default 32x32)
static u8  bg_mode_active;              // 1 once any tile layer is set up

// screenblock pointer for a layer's map, and its tile base.
static inline SCR_ENTRY *layer_map(int layer) { return se_mem[BG_SBB_BASE + layer]; }
static inline int layer_tile_base(int layer) { return BG_TILES_PER_LAYER * layer; }

// ensure the display is in a tiled mode with this layer's REG_BGxCNT set up.
static void ensure_bg_mode(void)
{
    if (bg_mode_active) return;
    bg_mode_active = 1;
    // Mode 0 = 4 regular tiled BGs. Keep OBJ on (sprites composite over the tiles)
    // + 1D object mapping. (This REPLACES the Mode-4 bitmap DISPCNT for tile games;
    // a bitmap game keeps the Mode-4 path — see gba_screen_mode.)
    REG_DISPCNT = DCNT_MODE0 | DCNT_OBJ | DCNT_OBJ_1D;
}

void gba_tileset(int layer, const unsigned int *tiles, int ntiles, const unsigned short *pal)
{
    if (layer < 0 || layer > 3) return;
    ensure_bg_mode();
    // copy tiles into this layer's slice of the shared charblock (4bpp = 8 words/tile).
    if (ntiles > BG_TILES_PER_LAYER) ntiles = BG_TILES_PER_LAYER;
    memcpy32(&tile_mem[BG_CBB_SHARED][layer_tile_base(layer)], tiles, ntiles * 8);
    // palette: 16 colors into this layer's BG palbank (we use palbank = layer).
    if (pal) memcpy32(&pal_bg_mem[16 * layer], pal, 16 / 2);
    // configure REG_BGxCNT: shared charblock, this layer's screenblock, 4bpp,
    // default priority = layer + 1, so priority 0 is RESERVED for the text layer
    // (BG3) which must draw in FRONT of the game's tiles. Game layers thus use
    // priority 1..3 (still correctly ordered among themselves).
    layer_size[layer] = BG_REG_32x32;
    (&REG_BG0CNT)[layer] = BG_CBB(BG_CBB_SHARED) | BG_SBB(BG_SBB_BASE + layer)
                         | BG_4BPP | BG_PRIO(layer + 1) | layer_size[layer];
    REG_DISPCNT |= (DCNT_BG0 << layer);
}

void gba_tilemap(int layer, const unsigned short *map, int cols, int rows)
{
    if (layer < 0 || layer > 3) return;
    ensure_bg_mode();
    // pick the hardware BG size that holds the map (32/64 in each axis).
    u16 size = BG_REG_32x32;
    if (cols > 32 && rows > 32) size = BG_REG_64x64;
    else if (cols > 32)         size = BG_REG_64x32;
    else if (rows > 32)         size = BG_REG_32x64;
    layer_size[layer] = size;
    (&REG_BG0CNT)[layer] = (((&REG_BG0CNT)[layer]) & ~BG_SIZE3) | size;

    // Write the map into the screenblock(s). A regular BG's screenblocks are
    // 32x32 SEs each; a 64-wide map uses 2 side-by-side SBBs, 64-tall uses 2
    // stacked. We translate (col,row) -> the right SBB + local index, adding the
    // layer's palbank into each SE. cols/rows beyond the hw size are ignored.
    int hw_cols = (size == BG_REG_64x32 || size == BG_REG_64x64) ? 64 : 32;
    int hw_rows = (size == BG_REG_32x64 || size == BG_REG_64x64) ? 64 : 32;
    SCR_ENTRY *base = layer_map(layer);
    u16 palbank = SE_PALBANK(layer);
    for (int ry = 0; ry < rows && ry < hw_rows; ry++) {
        for (int rx = 0; rx < cols && rx < hw_cols; rx++) {
            // SBB math: each 32x32 block is 0x400 SEs; blocks laid out
            // [TL][TR] / [BL][BR]. Index within a block = (ry&31)*32 + (rx&31).
            int block = (rx >> 5) + (ry >> 5) * (hw_cols >> 5);
            SCR_ENTRY *dst = base + block * 0x400 + (ry & 31) * 32 + (rx & 31);
            u16 tile = map[ry * cols + rx];
            // map entry: low 10 bits tile id (offset into the layer's tile slice),
            // bits 10/11 flip, 12-15 palbank. We add the layer's tile base + palbank.
            *dst = ((tile & 0x03FF) + layer_tile_base(layer)) | (tile & SE_FLIP_MASK) | palbank;
        }
    }
}

void gba_layer_show(int layer, int on)
{
    if (layer < 0 || layer > 3) return;
    if (on) REG_DISPCNT |= (DCNT_BG0 << layer);
    else    REG_DISPCNT &= ~(DCNT_BG0 << layer);
}

void gba_layer_priority(int layer, int prio)
{
    if (layer < 0 || layer > 3) return;
    (&REG_BG0CNT)[layer] = (((&REG_BG0CNT)[layer]) & ~BG_PRIO_MASK) | BG_PRIO(prio & 3);
}

// apply the camera (+per-layer factor/offset) to the hardware scroll registers.
static void apply_scroll(void)
{
    for (int L = 0; L < 4; L++) {
        int sx = (cam_x * layer_factor[L]) >> 8;
        int sy = (cam_y * layer_factor[L]) >> 8;
        (&REG_BG0HOFS)[L * 2]     = (u16)(sx + layer_ox[L]);
        (&REG_BG0HOFS)[L * 2 + 1] = (u16)(sy + layer_oy[L]);
    }
}

void gba_camera(int x, int y) { cam_x = x; cam_y = y; apply_scroll(); }

// parallax(layer, factor): how much this layer follows the camera. factor is a
// 16.16 fixed multiplier (1.0 = locked to camera, 0.5 = half speed = distant
// background, 0 = fixed HUD). Stored as .8 (factor>>8) for the integer scroll math.
void gba_layer_parallax(int layer, long factor)
{
    if (layer < 0 || layer > 3) return;
    layer_factor[layer] = (int)(factor >> 8);   // 16.16 -> .8
    apply_scroll();
}

void gba_layer_scroll(int layer, int x, int y)
{
    if (layer < 0 || layer > 3) return;
    // direct scroll for one layer (bypasses the camera): store as its offset with
    // a zero camera factor so the camera won't also move it.
    layer_factor[layer] = 0;
    layer_ox[layer] = x;
    layer_oy[layer] = y;
    apply_scroll();
}

int gba_mget(int layer, int col, int row)
{
    if (layer < 0 || layer > 3) return 0;
    int hw_cols = (layer_size[layer] == BG_REG_64x32 || layer_size[layer] == BG_REG_64x64) ? 64 : 32;
    int block = (col >> 5) + (row >> 5) * (hw_cols >> 5);
    SCR_ENTRY se = layer_map(layer)[block * 0x400 + (row & 31) * 32 + (col & 31)];
    return ((se & SE_ID_MASK) - layer_tile_base(layer)) & 0x03FF;
}

void gba_mset(int layer, int col, int row, int tile)
{
    if (layer < 0 || layer > 3) return;
    int hw_cols = (layer_size[layer] == BG_REG_64x32 || layer_size[layer] == BG_REG_64x64) ? 64 : 32;
    int block = (col >> 5) + (row >> 5) * (hw_cols >> 5);
    layer_map(layer)[block * 0x400 + (row & 31) * 32 + (col & 31)]
        = ((tile & 0x03FF) + layer_tile_base(layer)) | SE_PALBANK(layer);
}

// map_show(layer): display the build-bundled tilemap (--map level.png) on a
// layer — loads its tiles + palette + map and enables it. One call (in _init).
void gba_map_show(int layer)
{
#if GBA_HAS_MAP
    gba_tileset(layer, map_tiles, map_ntiles, map_pal);
    gba_tilemap(layer, map_data, map_cols, map_rows);
    gba_layer_show(layer, 1);
#else
    (void)layer;   // no --map given; nothing to show.
#endif
}

// reset BG state (called from gba_init)
void gba_bg_reset(void)
{
    cam_x = cam_y = 0;
    bg_mode_active = 0;
    for (int i = 0; i < 4; i++) { layer_factor[i] = 256; layer_ox[i] = layer_oy[i] = 0; layer_size[i] = BG_REG_32x32; }
}
