// test/gfx.test.js — the .gtg sprite-sheet conversion core (compiler/gfx.mjs).
// Verifies our .gtg bytes are the official GameTank format: 128x128 8bpp
// quadrants, top-down row-major, CAPTURE-palette indices, color 0 transparent.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  encodePng, decodePng, rgbaToGtg, gtgToPng, p8GfxToGtg, toGtg, gtgNames,
  QUADRANT, QUADRANT_BYTES,
} from "../compiler/gfx.mjs";
import { GT_CAPTURE_PALETTE, nearestColorByte } from "../compiler/gt_palette.js";

// build an RGBA buffer from a (x,y)->[r,g,b,a] function
function makeRgba(w, h, fn) {
  const rgba = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const [r, g, b, a] = fn(x, y);
    const o = (y * w + x) * 4;
    rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = b; rgba[o + 3] = a ?? 255;
  }
  return rgba;
}

test("a .gtg quadrant is exactly 16384 bytes (128x128, 1 byte/px)", () => {
  const rgba = makeRgba(128, 128, () => [200, 100, 50]);
  const { quadrants } = rgbaToGtg(128, 128, rgba);
  assert.equal(quadrants.length, 1);
  assert.equal(quadrants[0].length, QUADRANT_BYTES);
  assert.equal(QUADRANT_BYTES, 16384);
  assert.equal(QUADRANT, 128);
});

test("transparent pixels (low alpha) become color 0", () => {
  const rgba = makeRgba(128, 128, (x) => [255, 0, 0, x < 64 ? 255 : 0]);
  const { quadrants } = rgbaToGtg(128, 128, rgba);
  const q = quadrants[0];
  assert.notEqual(q[0], 0, "opaque red pixel should be nonzero");
  assert.equal(q[64], 0, "transparent pixel should be color 0");
});

test("rows are top-down row-major (pixel (x,y) -> byte y*128+x)", () => {
  // put a unique opaque color only at (5, 3); it must land at byte 3*128+5
  const rgba = makeRgba(128, 128, (x, y) =>
    (x === 5 && y === 3) ? [255, 0, 255, 255] : [0, 0, 0, 0]);
  const { quadrants } = rgbaToGtg(128, 128, rgba);
  const q = quadrants[0];
  assert.notEqual(q[3 * 128 + 5], 0);
  // and nowhere else
  let nonzero = 0;
  for (const b of q) if (b) nonzero++;
  assert.equal(nonzero, 1);
});

test("256x256 source splits into 4 quadrants in NW,NE,SW,SE order", async () => {
  // each quadrant a distinct solid color so we can identify it
  const rgba = makeRgba(256, 256, (x, y) => {
    if (x < 128 && y < 128) return [255, 0, 0];   // NW red
    if (x >= 128 && y < 128) return [0, 255, 0];  // NE green
    if (x < 128 && y >= 128) return [0, 0, 255];  // SW blue
    return [255, 255, 0];                          // SE yellow
  });
  const { quadrants } = rgbaToGtg(256, 256, rgba);
  assert.equal(quadrants.length, 4);
  // each source region maps to its own nearest-CAPTURE byte; the four must be
  // distinct and consistent (the GameTank palette is muted, so we compare the
  // resolved byte against nearestColorByte of the same source color, not raw RGB).
  assert.equal(quadrants[0][0], nearestColorByte(255, 0, 0), "quad 0 = NW red region");
  assert.equal(quadrants[1][0], nearestColorByte(0, 255, 0), "quad 1 = NE green region");
  assert.equal(quadrants[2][0], nearestColorByte(0, 0, 255), "quad 2 = SW blue region");
  assert.equal(quadrants[3][0], nearestColorByte(255, 255, 0), "quad 3 = SE yellow region");
  const bytes = new Set([quadrants[0][0], quadrants[1][0], quadrants[2][0], quadrants[3][0]]);
  assert.equal(bytes.size, 4, "the four quadrants are four distinct colors");
});

test("gtgNames follows the official name/_1/_2/_3 convention", () => {
  assert.deepEqual(gtgNames("hero.gtg", 1), ["hero.gtg"]);
  assert.deepEqual(gtgNames("hero", 4), ["hero.gtg", "hero_1.gtg", "hero_2.gtg", "hero_3.gtg"]);
});

test("PNG encode -> decode round-trips exact RGB", () => {
  const rgb = Buffer.alloc(16 * 16 * 3);
  for (let i = 0; i < rgb.length; i++) rgb[i] = (i * 37) & 255;
  const png = encodePng(16, 16, rgb);
  const { width, height, rgba } = decodePng(png);
  assert.equal(width, 16); assert.equal(height, 16);
  for (let p = 0; p < 16 * 16; p++) {
    assert.equal(rgba[p * 4], rgb[p * 3]);
    assert.equal(rgba[p * 4 + 1], rgb[p * 3 + 1]);
    assert.equal(rgba[p * 4 + 2], rgb[p * 3 + 2]);
  }
});

test("gtg -> png -> gtg is visually lossless (only same-RGB index swaps)", () => {
  // a gradient of real palette colors
  const src = Buffer.alloc(QUADRANT_BYTES);
  for (let i = 0; i < QUADRANT_BYTES; i++) src[i] = i & 255;
  const { width, height, rgba } = decodePng(gtgToPng(src));
  const { quadrants } = rgbaToGtg(width, height, rgba);
  const back = quadrants[0];
  for (let i = 0; i < QUADRANT_BYTES; i++) {
    const a = GT_CAPTURE_PALETTE[src[i]], b = GT_CAPTURE_PALETTE[back[i]];
    assert.deepEqual(b, a, `pixel ${i} changed color`);
  }
});

test("PICO-8 __gfx__ imports to a single quadrant via P8_PALETTE", () => {
  // a tiny cart: 2 rows, uses indices 0 (transparent) and 8
  const p8 = "__gfx__\n08080808\n80808080\n";
  const { quadrants, width, height } = p8GfxToGtg(p8);
  assert.equal(quadrants.length, 1);
  assert.equal(width, 128); assert.equal(height, 128);
  const q = quadrants[0];
  assert.equal(q[0], 0, "index 0 -> transparent");
  assert.notEqual(q[1], 0, "index 8 -> a color");
});

test("toGtg dispatches by content: PNG, p8, raw .gtg", () => {
  const png = encodePng(8, 8, Buffer.alloc(8 * 8 * 3, 100));
  assert.equal(toGtg(png, "x.png").quadrants[0].length, QUADRANT_BYTES);
  const p8 = Buffer.from("__gfx__\n11111111\n");
  assert.equal(toGtg(p8, "x.p8").quadrants.length, 1);
  const raw = Buffer.alloc(QUADRANT_BYTES, 7);
  assert.equal(toGtg(raw, "x.gtg").quadrants[0], raw);
});

test("oversized image is rejected", () => {
  const rgba = makeRgba(300, 100, () => [0, 0, 0]);
  assert.throws(() => rgbaToGtg(300, 100, rgba), /exceeds one 256x256/);
});
