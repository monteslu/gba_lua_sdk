// import.test.js — the Aseprite (.ase) and Tiled (.tmx) importers, against
// files synthesized to the real specs (no fixtures to rot).
import { test } from "node:test";
import assert from "node:assert/strict";
import zlib from "node:zlib";
import { aseToRgba } from "../compiler/ase-import.mjs";
import { tmxToRgba, listTmxImages } from "../compiler/tmx-import.mjs";
import { encodePng } from "../compiler/png-encode.mjs";
import { buildSoundbank } from "../compiler/soundbank.mjs";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ---- build a tiny real .ase in memory (32bpp RGBA, 1 layer, 1 raw cel) ------
function u16(v) { return [v & 0xff, (v >> 8) & 0xff]; }
function u32(v) { return [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >>> 24) & 0xff]; }

function makeAse({ w = 8, h = 8, celType = 0, secondLayerHidden = false } = {}) {
  // cel pixels: solid red, top-left pixel transparent
  const px = [];
  for (let i = 0; i < w * h; i++) px.push(255, 0, 0, i === 0 ? 0 : 255);
  let celPixels = new Uint8Array(px);
  if (celType === 2) celPixels = new Uint8Array(zlib.deflateSync(celPixels));

  const layerChunk = (visible) => {
    const data = [
      ...u16(visible ? 1 : 0), ...u16(0), ...u16(0),   // flags, type normal, child level
      ...u16(0), ...u16(0), ...u16(0),                 // default w/h, blend normal
      255, 0, 0, 0,                                    // opacity + 3 reserved
      ...u16(5), ...[..."layer"].map((c) => c.charCodeAt(0)),
    ];
    return [...u32(6 + data.length), ...u16(0x2004), ...data];
  };
  const celChunk = (pixels) => {
    const data = [
      ...u16(secondLayerHidden ? 1 : 0),               // layer index (hidden layer test puts cel on layer 1)
      ...u16(0), ...u16(0),                            // x, y
      255,                                             // opacity
      ...u16(celType),                                 // type
      0, 0, 0, 0, 0, 0, 0,                             // z-index + reserved
      ...u16(w), ...u16(h), ...pixels,
    ];
    return [...u32(6 + data.length), ...u16(0x2005), ...data];
  };

  const chunks = [...layerChunk(true)];
  if (secondLayerHidden) chunks.push(...layerChunk(false));
  chunks.push(...celChunk(celPixels));
  const nChunks = secondLayerHidden ? 3 : 2;

  const frame = [
    ...u32(16 + chunks.length),                        // frame bytes
    ...u16(0xf1fa), ...u16(nChunks), ...u16(100), 0, 0, ...u32(nChunks),
    ...chunks,
  ];
  const header = new Uint8Array(128);
  const hdr = [
    ...u32(128 + frame.length), ...u16(0xa5e0), ...u16(1),   // size, magic, frames
    ...u16(w), ...u16(h), ...u16(32),                        // w, h, 32bpp
    ...u32(1),                                               // flags: layer opacity valid
    ...u16(100), ...u32(0), ...u32(0),
    0,                                                       // transparent index
    0, 0, 0, ...u16(0), 1, 1,
  ];
  header.set(hdr, 0);
  return new Uint8Array([...header, ...frame]);
}

test("aseToRgba: raw cel, transparency, dimensions", () => {
  const { width, height, rgba, frames } = aseToRgba(makeAse());
  assert.equal(width, 8); assert.equal(height, 8); assert.equal(frames, 1);
  assert.equal(rgba[3], 0);                       // top-left transparent
  assert.deepEqual(Array.from(rgba.slice(4, 8)), [255, 0, 0, 255]);
});

test("aseToRgba: zlib-compressed cel decodes the same", () => {
  const a = aseToRgba(makeAse({ celType: 0 }));
  const b = aseToRgba(makeAse({ celType: 2 }));
  assert.deepEqual(Array.from(b.rgba), Array.from(a.rgba));
});

test("aseToRgba: cel on a hidden layer draws nothing", () => {
  const { rgba } = aseToRgba(makeAse({ secondLayerHidden: true }));
  assert.ok(rgba.every((v) => v === 0));
});

// ---- .tmx ---------------------------------------------------------------------
function makeTilesetPng() {
  // 16x8 tileset: tile 0 solid green, tile 1 solid blue
  const w = 16, h = 8, rgba = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 4;
      if (x < 8) { rgba[o + 1] = 255; } else { rgba[o + 2] = 255; }
      rgba[o + 3] = 255;
    }
  return encodePng(rgba, w, h);
}

const TMX = (data, encoding = "csv") => `<?xml version="1.0" encoding="UTF-8"?>
<map version="1.10" orientation="orthogonal" renderorder="right-down" width="2" height="2" tilewidth="8" tileheight="8">
 <tileset firstgid="1" name="t" tilewidth="8" tileheight="8" tilecount="2" columns="2">
  <image source="tiles.png" width="16" height="8"/>
 </tileset>
 <layer id="1" name="ground" width="2" height="2">
  <data encoding="${encoding}">${data}</data>
 </layer>
</map>`;

test("tmxToRgba: csv layer + tile lookup", () => {
  const { width, height, rgba, cols, rows } = tmxToRgba(TMX("1,2,2,1"), { "tiles.png": makeTilesetPng() });
  assert.equal(width, 16); assert.equal(height, 16);
  assert.equal(cols, 2); assert.equal(rows, 2);
  const at = (x, y) => Array.from(rgba.slice((y * width + x) * 4, (y * width + x) * 4 + 4));
  assert.deepEqual(at(0, 0), [0, 255, 0, 255]);   // gid 1 = green
  assert.deepEqual(at(8, 0), [0, 0, 255, 255]);   // gid 2 = blue
  assert.deepEqual(at(0, 8), [0, 0, 255, 255]);
  assert.deepEqual(at(8, 8), [0, 255, 0, 255]);
});

test("tmxToRgba: base64+zlib layer decodes the same as csv", () => {
  const gids = new Uint8Array(16);
  for (const [i, g] of [1, 2, 2, 1].entries()) gids[i * 4] = g;
  const b64 = zlib.deflateSync(gids).toString("base64");
  const a = tmxToRgba(TMX("1,2,2,1"), { "tiles.png": makeTilesetPng() });
  const tmx = TMX(b64, "base64").replace('encoding="base64"', 'encoding="base64" compression="zlib"');
  const b = tmxToRgba(tmx, { "tiles.png": makeTilesetPng() });
  assert.deepEqual(Array.from(b.rgba), Array.from(a.rgba));
});

test("tmxToRgba: gid 0 stays transparent; external tileset rejected", () => {
  const { rgba } = tmxToRgba(TMX("0,0,0,1"), { "tiles.png": makeTilesetPng() });
  assert.equal(rgba[3], 0);
  assert.throws(
    () => tmxToRgba('<map orientation="orthogonal" width="1" height="1" tilewidth="8" tileheight="8"><tileset firstgid="1" source="ext.tsx"/></map>'),
    /Embed Tileset/);
});

test("listTmxImages finds tileset sources", () => {
  assert.deepEqual(listTmxImages(TMX("1,1,1,1")), ["tiles.png"]);
});

// ---- soundbank ------------------------------------------------------------------
test("buildSoundbank reproduces the SDK default bank from music.xm", async () => {
  const xm = new Uint8Array(await readFile(path.join(__dirname, "..", "assets", "music.xm")));
  const bank = await readFile(path.join(__dirname, "..", "assets", "soundbank.bin"));
  const { bin } = buildSoundbank([{ name: "chiptune.xm", bytes: xm }]);
  assert.deepEqual(Array.from(bin), Array.from(new Uint8Array(bank)));
});

test("browser-safe importer modules use no Node built-ins", async () => {
  for (const f of ["ase-import.mjs", "tmx-import.mjs", "soundbank.mjs"]) {
    const src = await readFile(path.join(__dirname, "..", "compiler", f), "utf8");
    assert.ok(!/from\s+["']node:/.test(src), `${f} imports a node: module`);
  }
});

// ---- xm-write ------------------------------------------------------------------
test("writeXm produces a module romdev-maxmod compiles (deterministic)", async () => {
  const { writeXm, NOTE } = await import("../compiler/xm-write.mjs");
  const grid = [];
  for (let r = 0; r < 16; r++) {
    grid.push([
      r % 4 === 0 ? { note: NOTE["A4"], inst: 1, vol: 50 } : 0,
      0,
      r === 0 ? { note: NOTE["A2"], inst: 2 } : 0,
      r % 2 ? { note: NOTE["C5"], inst: 3, vol: 20 } : 0,
    ]);
  }
  const a = writeXm({ title: "t", patterns: [grid] });
  const b = writeXm({ title: "t", patterns: [grid] });
  assert.deepEqual(Array.from(a), Array.from(b));           // deterministic
  const { buildSoundbank } = await import("../compiler/soundbank.mjs");
  const { bin } = buildSoundbank([{ name: "t.xm", bytes: a }]);
  assert.ok(bin.length > 1000);                             // real MAS soundbank out
});
