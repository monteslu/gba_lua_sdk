// png.test.js — the browser-safe asset pipeline: PNG encode -> decode round-trip,
// tile conversion, and the no-Node-APIs guarantee.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import zlib from "node:zlib";
import { encodePng } from "../compiler/png-encode.mjs";
import { decodePng, inflate, pngToSheet, pngToTilemap } from "../compiler/png-tiles.mjs";
import { sheetAssetsHeader, mode7AssetHeader } from "../compiler/asset-headers.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// a synthetic 16x16 RGBA image: 4 solid 8x8 quadrants + transparent corner pixel.
function testImage() {
  const w = 16, h = 16;
  const rgba = new Uint8Array(w * h * 4);
  const put = (x, y, r, g, b, a = 255) => {
    const o = (y * w + x) * 4;
    rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = b; rgba[o + 3] = a;
  };
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      if (x < 8 && y < 8) put(x, y, 255, 0, 0);
      else if (x >= 8 && y < 8) put(x, y, 0, 255, 0);
      else if (x < 8) put(x, y, 0, 0, 255);
      else put(x, y, 255, 255, 0);
    }
  put(0, 0, 0, 0, 0, 0); // transparent pixel
  return { w, h, rgba };
}

test("encodePng -> decodePng round-trips exactly", () => {
  const { w, h, rgba } = testImage();
  const png = encodePng(rgba, w, h);
  const dec = decodePng(png);
  assert.equal(dec.width, w);
  assert.equal(dec.height, h);
  assert.deepEqual(Array.from(dec.rgba), Array.from(rgba));
});

test("own inflate matches node:zlib on real deflate output", () => {
  // compress varied data with REAL zlib (dynamic huffman blocks) and check our
  // decoder reproduces it — this exercises the non-stored code paths.
  const data = new Uint8Array(50000);
  for (let i = 0; i < data.length; i++) data[i] = (i * 7 + ((i / 100) | 0)) & 0xff;
  const forms = [
    zlib.deflateSync(data),                        // default (dynamic blocks)
    zlib.deflateSync(data, { level: 0 }),          // stored blocks
    zlib.deflateSync(data, { strategy: zlib.constants.Z_FIXED }), // fixed codes
  ];
  for (const compressed of forms) {
    assert.deepEqual(Array.from(inflate(new Uint8Array(compressed))), Array.from(data));
  }
});

test("decodePng reads zlib-compressed PNGs (the wild kind)", async () => {
  // examples ship real-world PNGs written by image editors — decode one.
  const buf = await readFile(path.join(__dirname, "..", "examples", "starfall", "shmup_sheet.png"));
  const dec = decodePng(new Uint8Array(buf));
  assert.ok(dec.width % 8 === 0 && dec.height % 8 === 0);
  const { words, pal } = pngToSheet(new Uint8Array(buf));
  assert.ok(words.length > 0);
  assert.equal(pal.length, 16);
});

test("pngToSheet: palette from image colors, index 0 transparent", () => {
  const { w, h, rgba } = testImage();
  const png = encodePng(rgba, w, h);
  const { words, pal, tilesAcross, tilesDown } = pngToSheet(png);
  assert.equal(tilesAcross, 2);
  assert.equal(tilesDown, 2);
  assert.equal(words.length, 4 * 8);        // one 16x16 sprite = 4 tiles * 8 words
  assert.equal(pal[0], 0);                  // slot 0 = transparent
  // 4 quadrant colors -> palette entries 1..4 (in scan order: red, green, blue, yellow)
  const bgr = (r, g, b) => (r >> 3) | ((g >> 3) << 5) | ((b >> 3) << 10);
  assert.deepEqual(pal.slice(1, 5), [bgr(255, 0, 0), bgr(0, 255, 0), bgr(0, 0, 255), bgr(255, 255, 0)]);
  // first tile row: pixel 0 transparent (0), pixels 1-7 red (1) -> word 0x11111110
  assert.equal(words[0] >>> 0, 0x11111110);
});

test("pngToTilemap dedups identical tiles", () => {
  const { w, h, rgba } = testImage();
  // make all 4 quadrants the same color -> 1 unique tile (+ empty tile 0)
  const flat = new Uint8Array(rgba.length).fill(255);
  const png = encodePng(flat, w, h);
  const { tileWords, map } = pngToTilemap(png);
  assert.equal(tileWords.length, 2 * 8);    // empty tile + one unique tile
  assert.deepEqual(map, [1, 1, 1, 1]);
});

test("asset headers are deterministic text", () => {
  const { w, h, rgba } = testImage();
  const png = encodePng(rgba, w, h);
  const a = sheetAssetsHeader(png, "x.png", "sheet");
  const b = sheetAssetsHeader(png, "x.png", "sheet");
  assert.equal(a, b);
  assert.match(a, /#define GBA_SHEET_HAS_PAL 1/);
  // mode7 requires square power-of-2 tile sides; 16x16 px = 2x2 tiles -> rejected
  assert.throws(() => mode7AssetHeader(png, "x.png"), /16\/32\/64\/128/);
});

test("browser-safe modules import no Node built-ins", async () => {
  for (const f of ["png-tiles.mjs", "png-encode.mjs", "asset-headers.mjs"]) {
    const src = await readFile(path.join(__dirname, "..", "compiler", f), "utf8");
    assert.ok(!/from\s+["']node:/.test(src), `${f} imports a node: module`);
    assert.ok(!/\bBuffer\./.test(src), `${f} uses Buffer`);
  }
});
