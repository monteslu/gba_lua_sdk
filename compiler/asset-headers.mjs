// asset-headers.mjs — PNG bytes -> the generated C asset headers the runtime
// #includes. BROWSER-SAFE (pure JS, takes Uint8Array, no fs) — shared by the
// gbalua CLI (build-gba.mjs) and the web IDE build worker, so the header TEXT
// (and therefore the ROM bytes) is identical no matter where the build runs.

import { pngToSheet, pngToTilemap, pngToAffineMap } from "./png-tiles.mjs";

/**
 * Sprite-sheet header (gba_assets.h): 4bpp tiles in 16x16 sprite-block order
 * + 16-color BGR555 palette.
 * @param {Uint8Array} pngBytes
 * @param {string} srcName - shows in the generated comment (e.g. "sheet.png")
 * @param {string} varPrefix - names the C symbols
 */
export function sheetAssetsHeader(pngBytes, srcName = "sheet.png", varPrefix = "sheet") {
  const { words, pal } = pngToSheet(pngBytes);
  let h = `// generated from ${srcName} (self-contained PNG->GBA 4bpp)\n`;
  h += `#ifndef GBA_ASSETS_H\n#define GBA_ASSETS_H\n\n`;
  h += `static const unsigned int ${varPrefix}_tiles[${words.length}] = {${words.map((w) => w >>> 0).join(",")}};\n`;
  h += `static const unsigned short ${varPrefix}_pal[16] = {${pal.join(",")}};\n`;
  h += `#define GBA_SHEET_TILES ${varPrefix}_tiles\n`;
  h += `#define GBA_SHEET_TILES_WORDS ${words.length}\n`;
  h += `#define GBA_SHEET_HAS_PAL 1\n`;
  h += `#define GBA_SHEET_PAL ${varPrefix}_pal\n`;
  h += `\n#endif\n`;
  return h;
}

/** Background tilemap header (gba_map_asset.h): deduped tiles + map + palette. */
export function mapAssetHeader(pngBytes, srcName = "map.png") {
  const { tileWords, map, pal, cols, rows } = pngToTilemap(pngBytes);
  let h = `// generated from ${srcName} (PNG->GBA tilemap)\n`;
  h += `#ifndef GBA_MAP_ASSET_H\n#define GBA_MAP_ASSET_H\n#define GBA_HAS_MAP 1\n\n`;
  h += `static const unsigned int map_tiles[${tileWords.length}] = {${tileWords.map((w) => w >>> 0).join(",")}};\n`;
  h += `#define map_ntiles ${tileWords.length / 8}\n`;
  h += `static const unsigned short map_data[${map.length}] = {${map.join(",")}};\n`;
  h += `static const unsigned short map_pal[16] = {${pal.join(",")}};\n`;
  h += `#define map_cols ${cols}\n#define map_rows ${rows}\n`;
  h += `\n#endif\n`;
  return h;
}

/**
 * Mode-7 affine background header (gba_mode7_asset.h): 8bpp tiles + 256-color
 * palette + a square 1-byte-per-cell map packed 4 cells/u32 for memcpy32.
 */
export function mode7AssetHeader(pngBytes, srcName = "plane.png") {
  const { tileWords, map, pal, side } = pngToAffineMap(pngBytes);
  const mapWords = [];
  for (let i = 0; i < map.length; i += 4) {
    mapWords.push(((map[i] | (map[i + 1] << 8) | (map[i + 2] << 16) | (map[i + 3] << 24)) >>> 0));
  }
  let h = `// generated from ${srcName} (PNG->GBA Mode-7 affine bg)\n`;
  h += `#ifndef GBA_MODE7_ASSET_H\n#define GBA_MODE7_ASSET_H\n#define GBA_HAS_MODE7 1\n\n`;
  h += `static const unsigned int m7_tiles[${tileWords.length}] = {${tileWords.map((w) => w >>> 0).join(",")}};\n`;
  h += `#define m7_ntiles ${tileWords.length / 16}\n`;              // 8bpp = 16 words/tile
  h += `static const unsigned int m7_map[${mapWords.length}] = {${mapWords.join(",")}};\n`;
  h += `static const unsigned short m7_pal[256] = {${pal.join(",")}};\n`;
  h += `#define m7_side ${side}\n`;
  h += `\n#endif\n`;
  return h;
}

// ---- the stub/fallback headers used when no asset is supplied ---------------

/** No sheet given: fall back to the built-in alien sprite. */
export function alienAssetsHeader() {
  return `// no --sheet given: fall back to the built-in alien sprite.
#ifndef GBA_ASSETS_H
#define GBA_ASSETS_H
#include "alien_sprite.h"
#define GBA_SHEET_TILES alien_tiles
#define GBA_SHEET_TILES_WORDS (sizeof(alien_tiles)/4)
#define GBA_SHEET_HAS_PAL 0
#endif
`;
}

export function mapStubHeader() {
  return `#ifndef GBA_MAP_ASSET_H\n#define GBA_MAP_ASSET_H\n#define GBA_HAS_MAP 0\n#endif\n`;
}

export function mode7StubHeader() {
  return `#ifndef GBA_MODE7_ASSET_H\n#define GBA_MODE7_ASSET_H\n#define GBA_HAS_MODE7 0\n#endif\n`;
}
