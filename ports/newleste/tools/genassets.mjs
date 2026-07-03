#!/usr/bin/env node
// genassets.mjs — asset/map generator for the newleste GameTank port.
//
// Reads carts/newleste-base.p8 (plain-text PICO-8 cart, GPL-3.0) and emits:
//   1. ports/newleste/gfx.bin — 8192-byte 4bpp sheet (two pixels/byte, LOW
//      nibble = left pixel, matching gt_sheet_load and carts/*-extract).
//      The original 128x128 __gfx__ plus DERIVED cells authored into free
//      sheet rows (the GameTank blitter has no flip bit, so every flipped
//      draw the cart performs needs a pre-mirrored cell; pal() cannot
//      recolor loaded sprites, so the blue-hair player needs recolored
//      cells):
//        cells 64-70  player sprites 1-7 mirrored (red hair)
//        cells 72-78  player sprites 1-7 with hair recolored 8->12 (blue)
//        cells 80-86  blue-hair sprites mirrored
//        cells 88-90  fly-fruit wings 12/13/14 mirrored
//        cell  91     side spring (cell 8) mirrored
//        cells 92-95  floor spring (cell 9) squashed by 1..4 px (the cart
//                     draws this with sspr(72,0,8,8-delta,x,y+delta))
//   2. the body of map_init() spliced into ports/newleste/main.lua between
//      the "-- @gen-map-begin" / "-- @gen-map-end" markers: __map__ tiles
//      (cols 0-63 x rows 0-15 -> m[row*64+col+1], RLE'd into for-loops)
//      and __gff__ sprite flags (fl[tile+1]).
//
// Run from the repo root:  node ports/newleste/tools/genassets.mjs

import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "..", "..", "..");
const CART = path.join(REPO, "carts", "newleste-base.p8");
const OUT_GFX = path.join(HERE, "..", "gfx.bin");
const MAIN_LUA = path.join(HERE, "..", "main.lua");

const text = readFileSync(CART, "utf8").split(/\r?\n/);

function section(name) {
  const start = text.indexOf(`__${name}__`);
  if (start === -1) return [];
  const lines = [];
  for (let i = start + 1; i < text.length; i++) {
    if (/^__\w+__$/.test(text[i])) break;
    lines.push(text[i]);
  }
  return lines;
}

// ---- __gfx__ -> 128x128 pixel grid -----------------------------------------
const gfx = Array.from({ length: 128 }, () => new Uint8Array(128));
section("gfx").forEach((line, y) => {
  if (y >= 128) return;
  for (let x = 0; x < Math.min(line.length, 128); x++) {
    gfx[y][x] = parseInt(line[x], 16) || 0;
  }
});

const cellPx = (n) => [(n % 16) * 8, (n >> 4) * 8]; // -> [x, y]

function copyCell(src, dst, fn) {
  const [sx, sy] = cellPx(src);
  const [dx, dy] = cellPx(dst);
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      const v = fn(gfx, sx, sy, x, y);
      gfx[dy + y][dx + x] = v;
    }
  }
}

const mirror = (g, sx, sy, x, y) => g[sy + y][sx + (7 - x)];
const plain = (g, sx, sy, x, y) => g[sy + y][sx + x];
const blue = (g, sx, sy, x, y) => {
  const v = g[sy + y][sx + x];
  return v === 8 ? 12 : v;
};
const blueMirror = (g, sx, sy, x, y) => {
  const v = g[sy + y][sx + (7 - x)];
  return v === 8 ? 12 : v;
};

// player sprites 1-7: mirrored, blue, blue+mirrored
for (let s = 1; s <= 7; s++) {
  copyCell(s, 63 + s, mirror);     // 64-70
  copyCell(s, 71 + s, blue);       // 72-78
  copyCell(s, 79 + s, blueMirror); // 80-86
}
// fly-fruit wings mirrored
copyCell(12, 88, mirror);
copyCell(13, 89, mirror);
copyCell(14, 90, mirror);
// side spring mirrored
copyCell(8, 91, mirror);
// floor spring squashed by delta=1..4: top (8-delta) source rows drawn at
// y+delta (rows above stay transparent)
for (let d = 1; d <= 4; d++) {
  copyCell(9, 91 + d, (g, sx, sy, x, y) => (y < d ? 0 : g[sy + (y - d)][sx + x]));
}

// pack: two pixels/byte, LOW nibble = left pixel
const bin = Buffer.alloc(8192);
for (let y = 0; y < 128; y++) {
  for (let x = 0; x < 128; x += 2) {
    bin[(y * 128 + x) >> 1] = (gfx[y][x] & 15) | ((gfx[y][x + 1] & 15) << 4);
  }
}
writeFileSync(OUT_GFX, bin);

// ---- __map__ -> m[] assignments ---------------------------------------------
// Only cols 0-63 hold level data (level 1: cols 0-15, level 2: cols 16-63).
const MAP_W = 64, MAP_H = 16;
const mapLines = section("map");
const tiles = new Uint8Array(MAP_W * MAP_H);
let nonzero = 0;
for (let y = 0; y < MAP_H; y++) {
  const line = mapLines[y] ?? "";
  for (let x = 0; x < MAP_W; x++) {
    const v = parseInt(line.slice(x * 2, x * 2 + 2), 16) || 0;
    tiles[y * MAP_W + x] = v;
    if (v) nonzero++;
  }
}
// anything beyond col 63 must be empty, or the port's 64-wide array is wrong
for (let y = 0; y < MAP_H; y++) {
  const line = mapLines[y] ?? "";
  for (let x = MAP_W; x * 2 < line.length; x++) {
    if (parseInt(line.slice(x * 2, x * 2 + 2), 16)) {
      throw new Error(`map tile outside col 0-63 at (${x},${y}) — widen MAP_W`);
    }
  }
}

// ---- __gff__ -> fl[] assignments ----------------------------------------------
const gffLines = section("gff");
const flags = new Uint8Array(64);
const gff0 = gffLines[0] ?? "";
for (let s = 0; s < 64; s++) {
  flags[s] = parseInt(gff0.slice(s * 2, s * 2 + 2), 16) || 0;
}

// ---- emit the map_init() body, RLE runs -> for loops -------------------------
const out = [];
out.push("  -- __map__ cols 0-63 x rows 0-15 -> m[row*64+col+1] (generated)");
let i = 0;
const flat = [];
for (let idx = 0; idx < MAP_W * MAP_H; idx++) flat.push(tiles[idx]);
while (i < flat.length) {
  const v = flat[i];
  if (v === 0) { i++; continue; }
  let j = i;
  while (j + 1 < flat.length && flat[j + 1] === v) j++;
  const runLen = j - i + 1;
  if (runLen >= 3) {
    out.push(`  for i = ${i + 1}, ${j + 1} do m[i] = ${v} end`);
  } else {
    for (let k = i; k <= j; k++) out.push(`  m[${k + 1}] = ${v}`);
  }
  i = j + 1;
}
out.push("  -- __gff__ sprite flags -> fl[tile+1] (generated)");
i = 0;
while (i < 64) {
  const v = flags[i];
  if (v === 0) { i++; continue; }
  let j = i;
  while (j + 1 < 64 && flags[j + 1] === v) j++;
  if (j - i + 1 >= 3) {
    out.push(`  for i = ${i + 1}, ${j + 1} do fl[i] = ${v} end`);
  } else {
    for (let k = i; k <= j; k++) out.push(`  fl[${k + 1}] = ${v}`);
  }
  i = j + 1;
}

// ---- splice into main.lua -----------------------------------------------------
const BEGIN = "-- @gen-map-begin";
const END = "-- @gen-map-end";
let main = readFileSync(MAIN_LUA, "utf8");
const b = main.indexOf(BEGIN);
const e = main.indexOf(END);
if (b === -1 || e === -1 || e < b) {
  throw new Error(`markers ${BEGIN} / ${END} not found in main.lua`);
}
main = main.slice(0, b + BEGIN.length) + "\n" + out.join("\n") + "\n  " +
  main.slice(e);
writeFileSync(MAIN_LUA, main);

console.log(`gfx.bin: 8192 bytes (derived cells 64-95 authored)`);
console.log(`map: ${nonzero} non-zero tiles -> ${out.length} generated lines`);
console.log(`flags: [${Array.from(flags).join(",")}]`);
