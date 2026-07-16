// build-gba.mjs — build a gba-lua game to a .gba ROM.
//
// Pipeline: Lua --(gba-lua compiler)--> GBA C, bundled with the gba_api.c runtime
// + the sprite art, then compiled/linked to a .gba by the romdev GBA toolchain
// (arm-none-eabi-gcc + libtonc, all WASM: cc1-arm -> as -> ld -> objcopy).
//
// TWO BACKENDS for the C->ROM step (same toolchain code either way, so the ROM
// bytes are identical):
//   local (default when available) — import romdevtools' buildGbaC() and run the
//     WASM toolchain IN-PROCESS. No server needed. Resolved from, in order:
//     $ROMDEVTOOLS (path to the romdevtools package dir), a normal npm install
//     of `romdevtools`, or a sibling ../romdev/packages/romdevtools checkout.
//   mcp — POST the sources to a running romdev server (default
//     http://127.0.0.1:7331/mcp). The original path; still useful because the
//     server keeps warm toolchain workers (faster for rapid rebuilds).
// Force one with GBALUA_BACKEND=local|mcp.

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import path from "node:path";
import { compile, formatDiagnostics } from "./index.js";
import { pngToSheet, pngToTilemap, pngToAffineMap } from "./png-tiles.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SDK_DIR = path.resolve(__dirname, "..", "gba-sdk");
const MCP_URL = process.env.ROMDEV_URL || "http://127.0.0.1:7331/mcp";

// Locate the romdevtools package for the in-process (no-server) backend.
// Returns its package dir, or null (-> fall back to the MCP server).
function resolveRomdevtools() {
  // 1. explicit env override (a checkout or an installed package dir)
  const envDir = process.env.ROMDEVTOOLS;
  if (envDir && existsSync(path.join(envDir, "src", "toolchains", "gba-c", "gba-c.js"))) return envDir;
  // 2. a normal npm install of `romdevtools`
  try {
    const require = createRequire(import.meta.url);
    return path.dirname(require.resolve("romdevtools/package.json"));
  } catch { /* not installed */ }
  // 3. cliemu-workspace convenience: a sibling romdev checkout next to this repo
  const sibling = path.resolve(__dirname, "..", "..", "romdev", "packages", "romdevtools");
  if (existsSync(path.join(sibling, "src", "toolchains", "gba-c", "gba-c.js"))) return sibling;
  return null;
}

async function rpc(sid, body) {
  const headers = { "Content-Type": "application/json", "Accept": "application/json, text/event-stream" };
  if (sid) headers["mcp-session-id"] = sid;
  const r = await fetch(MCP_URL, { method: "POST", headers, body: JSON.stringify(body) });
  const sidOut = r.headers.get("mcp-session-id");
  const text = await r.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* notification / sse */ }
  return { sidOut, json, text };
}

// call an MCP tool, returning the parsed result object.
async function callTool(sid, name, args) {
  const { json } = await rpc(sid, {
    jsonrpc: "2.0", id: 7, method: "tools/call", params: { name, arguments: args },
  });
  const text = json?.result?.content?.[0]?.text;
  if (!text) throw new Error(`${name}: no result`);
  return JSON.parse(text);
}

// Reorder a row-major tile array (tilesAcross wide) into consecutive 16x16
// SPRITE blocks. Each sprite = a 2x2 tile block; GBA 1D mapping wants its 4
// tiles as NW,NE,SW,SE consecutive. Sprites are numbered left-to-right,
// top-to-bottom across the sheet's 16x16 grid. Each tile is 8 u32 words.
function reorderToSpriteBlocks(rowTiles, tilesAcross, tilesDown) {
  const W = 8; // words per tile
  const tileAt = (tx, ty) => rowTiles.slice((ty * tilesAcross + tx) * W, (ty * tilesAcross + tx) * W + W);
  const spCols = Math.max(1, tilesAcross >> 1);   // 16px sprite columns
  const spRows = Math.max(1, tilesDown >> 1);
  const out = [];
  for (let sr = 0; sr < spRows; sr++)
    for (let sc = 0; sc < spCols; sc++) {
      const tx = sc * 2, ty = sr * 2;
      out.push(...tileAt(tx, ty), ...tileAt(tx + 1, ty), ...tileAt(tx, ty + 1), ...tileAt(tx + 1, ty + 1));
    }
  return out.length ? out : rowTiles;
}

// Convert a PNG to GBA 4bpp tiles + palette via romdev's encodeArt, and emit a C
// header the runtime #includes. `varPrefix` names the C symbols (e.g. "sheet").
// Returns the header text. tiles are `unsigned int[]` (4bpp, 8 words/tile), pal
// is `unsigned short[16]` (BGR555). For a tilemap (stage:'tilemap') we also emit
// the map as `unsigned short[]` + its cols/rows.
async function convertSheet(_sid, pngPath, varPrefix) {
  // Self-contained PNG->4bpp (compiler/png-tiles.mjs): builds the palette from the
  // image's OWN colors. We do NOT use encodeArt's GBA `tiles` palette — that stage
  // emits a broken placeholder palette (romdev bug: "no master palette for gba").
  const buf = await readFile(pngPath);
  const { words, pal } = pngToSheet(buf);
  let h = `// generated from ${path.basename(pngPath)} (self-contained PNG->GBA 4bpp)\n`;
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

// Convert a background PNG to a tilemap header (deduped tiles + map + palette).
async function convertMap(pngPath) {
  const buf = await readFile(pngPath);
  const { tileWords, map, pal, cols, rows } = pngToTilemap(buf);
  let h = `// generated from ${path.basename(pngPath)} (PNG->GBA tilemap)\n`;
  h += `#ifndef GBA_MAP_ASSET_H\n#define GBA_MAP_ASSET_H\n#define GBA_HAS_MAP 1\n\n`;
  h += `static const unsigned int map_tiles[${tileWords.length}] = {${tileWords.map((w) => w >>> 0).join(",")}};\n`;
  h += `#define map_ntiles ${tileWords.length / 8}\n`;
  h += `static const unsigned short map_data[${map.length}] = {${map.join(",")}};\n`;
  h += `static const unsigned short map_pal[16] = {${pal.join(",")}};\n`;
  h += `#define map_cols ${cols}\n#define map_rows ${rows}\n`;
  h += `\n#endif\n`;
  return h;
}

// Convert a PNG to a Mode-7 AFFINE background header: 8bpp tiles + 256-color
// palette + a square 1-byte-per-cell map. The map bytes are packed 4-per-u32 so
// the runtime can memcpy32 them straight into the screenblock.
async function convertMode7(pngPath) {
  const buf = await readFile(pngPath);
  const { tileWords, map, pal, side } = pngToAffineMap(buf);
  // pack the 1-byte map cells into u32 words (4 cells/word, little-endian).
  const mapWords = [];
  for (let i = 0; i < map.length; i += 4) {
    mapWords.push(((map[i] | (map[i + 1] << 8) | (map[i + 2] << 16) | (map[i + 3] << 24)) >>> 0));
  }
  let h = `// generated from ${path.basename(pngPath)} (PNG->GBA Mode-7 affine bg)\n`;
  h += `#ifndef GBA_MODE7_ASSET_H\n#define GBA_MODE7_ASSET_H\n#define GBA_HAS_MODE7 1\n\n`;
  h += `static const unsigned int m7_tiles[${tileWords.length}] = {${tileWords.map((w) => w >>> 0).join(",")}};\n`;
  h += `#define m7_ntiles ${tileWords.length / 16}\n`;              // 8bpp = 16 words/tile
  h += `static const unsigned int m7_map[${mapWords.length}] = {${mapWords.join(",")}};\n`;
  h += `static const unsigned short m7_pal[256] = {${pal.join(",")}};\n`;
  h += `#define m7_side ${side}\n`;
  h += `\n#endif\n`;
  return h;
}

function emptyMode7Header() {
  return `#ifndef GBA_MODE7_ASSET_H\n#define GBA_MODE7_ASSET_H\n#define GBA_HAS_MODE7 0\n#endif\n`;
}

// the fallback gba_assets.h when no --sheet: use the built-in alien.
function alienAssetsHeader() {
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

/**
 * Build `entryLua` (a main.lua path) to a .gba at `outPath`.
 * opts.sheetPath: a PNG converted to a sprite sheet (sheet_tiles/sheet_pal),
 *   auto-loaded so spr(n) indexes real art. opts.mapPath: (future) a tilemap PNG.
 * Returns { ok, outPath, issues, log }.
 */
export async function buildGba(entryLua, outPath, opts = {}) {
  const src = await readFile(entryLua, "utf8");
  const res = compile(src, path.basename(entryLua), { target: "gba" });
  const warnings = res.diagnostics.filter((d) => d.severity === "warning");
  if (warnings.length) process.stderr.write(formatDiagnostics(warnings) + "\n");
  if (!res.ok) {
    const errs = res.diagnostics.filter((d) => d.severity === "error");
    throw new Error("gba-lua: compile failed\n" + formatDiagnostics(errs));
  }

  // the runtime sources + headers that ship with the SDK
  const rd = (f) => readFile(path.join(SDK_DIR, f), "utf8");
  const apiC = await rd("gba_api.c");
  const mathC = await rd("gba_math.c");
  const bgC = await rd("gba_bg.c");
  const textC = await rd("gba_text.c");
  const fxC = await rd("gba_fx.c");   // hardware color effects (blend + fade)
  const m7C = await rd("gba_mode7.c");   // Mode-7 affine background
  const winC = await rd("gba_win.c");   // hardware windows (clip regions)
  const animC = await rd("gba_anim.c");   // animation helpers (frame cycling)
  const hwC = await rd("gba_hw.c");   // SRAM save/load + free-running timer
  const moreC = await rd("gba_more.c");   // DMA + 16-bit bitmap + second affine BG
  const apiH = await rd("gba_api.h");
  const mathH = await rd("gba_math.h");
  const alienH = await rd("alien_sprite.h");
  const sintabH = await rd("gba_sintab.h");
  const fontH = await rd("gba_font.h");   // baked 8x8 HUD font (sprite-based text)

  // does the game use sound? (the emitted C calls gba_music/gba_sfx). If so we
  // link maxmod + the soundbank; otherwise we skip all of it (smaller ROM, no
  // maxmod init cost). GBA_HAVE_SOUND must reach BOTH main.c and gba_api.c, so
  // it rides a generated header both include (like gba_assets.h).
  const usesSound = /\bgba_music\b|\bgba_sfx\b/.test(res.c);

  const sources = { "main.c": res.c, "gba_api.c": apiC, "gba_math.c": mathC, "gba_bg.c": bgC, "gba_text.c": textC, "gba_fx.c": fxC, "gba_mode7.c": m7C, "gba_win.c": winC, "gba_anim.c": animC, "gba_hw.c": hwC, "gba_more.c": moreC };
  const includes = { "gba_api.h": apiH, "gba_math.h": mathH, "alien_sprite.h": alienH, "gba_sintab.h": sintabH, "gba_font.h": fontH };

  // per-build feature-flag header (every TU includes gba_api.h -> gba_config.h).
  includes["gba_config.h"] =
    `#ifndef GBA_CONFIG_H\n#define GBA_CONFIG_H\n${usesSound ? "#define GBA_HAVE_SOUND 1\n" : ""}#endif\n`;

  // sound: link maxmod + the soundbank when the game uses music()/sfx().
  let maxmod = false;
  let soundbankPath = null;
  if (usesSound) {
    sources["gba_sound.c"] = await rd("gba_sound.c");
    // the default soundbank (MOD_CHIPTUNE = music 0). A game can override with
    // its own soundbank later. The toolchain auto-emits the .incbin stub for a
    // binaryInclude named "soundbank.bin" when maxmod is on.
    maxmod = true;
    soundbankPath = path.resolve(SDK_DIR, "..", "assets", "soundbank.bin");
  }

  // Asset conversion: --sheet foo.png -> real 4bpp sprite tiles, generated into
  // gba_assets.h (which the runtime always includes). No --sheet -> the header
  // falls back to the built-in alien. gba_assets.h is generated EVERY build so
  // both main.c and gba_api.c (separate TUs) see the same asset.
  includes["gba_assets.h"] = opts.sheetPath
    ? await convertSheet(null, path.resolve(opts.sheetPath), "sheet")
    : alienAssetsHeader();

  // --map level.png -> a background tilemap (deduped tiles + map) for map_show().
  // Generated into gba_map_asset.h, always present (empty stub if no --map).
  includes["gba_map_asset.h"] = opts.mapPath
    ? await convertMap(path.resolve(opts.mapPath))
    : `#ifndef GBA_MAP_ASSET_H\n#define GBA_MAP_ASSET_H\n#define GBA_HAS_MAP 0\n#endif\n`;

  // --mode7 plane.png -> an 8bpp affine background (mode7/mode7_cam). Generated
  // into gba_mode7_asset.h, always present (empty stub if no --mode7).
  includes["gba_mode7_asset.h"] = opts.mode7Path
    ? await convertMode7(path.resolve(opts.mode7Path))
    : emptyMode7Header();

  // ---- backend dispatch ------------------------------------------------------
  const forced = process.env.GBALUA_BACKEND;   // "local" | "mcp" | unset
  const toolsDir = forced === "mcp" ? null : resolveRomdevtools();
  if (forced === "local" && !toolsDir) {
    throw new Error("gba-lua: GBALUA_BACKEND=local but romdevtools not found — set $ROMDEVTOOLS, `npm i romdevtools`, or keep a sibling romdev checkout.");
  }
  return toolsDir
    ? buildLocal({ toolsDir, sources, includes, maxmod, soundbankPath, outPath })
    : buildMcp({ sources, includes, maxmod, soundbankPath, outPath });
}

// ---- local backend: run the WASM toolchain in-process (no server) -----------
// Imports the SAME buildGbaC() the romdev server uses, so ROM bytes are
// byte-identical to the MCP path by construction. binaryIncludes travel as
// Uint8Array (the native in-process contract — no base64 round-trip to get
// wrong). Warm-up note: each CLI invocation compiles the tool WASM once
// (cc1-arm is ~38 MB), so a one-shot build pays a small startup cost the warm
// MCP server doesn't; the bytes are the same either way.
async function buildLocal({ toolsDir, sources, includes, maxmod, soundbankPath, outPath }) {
  const toolUrl = pathToFileURL(path.join(toolsDir, "src", "toolchains", "gba-c", "gba-c.js")).href;
  const parseUrl = pathToFileURL(path.join(toolsDir, "src", "toolchains", "parse-errors.js")).href;
  const [{ buildGbaC }, { parseBuildLog }] = await Promise.all([import(toolUrl), import(parseUrl)]);

  const binaryIncludes = {};
  if (maxmod && soundbankPath) {
    binaryIncludes["soundbank.bin"] = new Uint8Array(await readFile(soundbankPath));
  }

  const r = await buildGbaC({
    sources, headers: includes, binaryIncludes,
    runtime: "libtonc", maxmod,
  });
  const issues = parseBuildLog(r.log || "");
  const log = (r.log || "").slice(-4000);
  if (!r.ok || !r.binary) return { ok: false, outPath: null, issues, log };

  const abs = path.resolve(outPath);
  await mkdir(path.dirname(abs), { recursive: true });
  await writeFile(abs, r.binary);
  return { ok: true, outPath: abs, issues, log };
}

// ---- mcp backend: POST the sources to a running romdev server ---------------
async function buildMcp({ sources, includes, maxmod, soundbankPath, outPath }) {
  const init = await rpc(null, {
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "gba-lua", version: "1" } },
  });
  if (!init.sidOut) {
    throw new Error(`gba-lua: no local romdevtools found AND no romdev server at ${MCP_URL}. Install romdevtools (or set $ROMDEVTOOLS), or start the server / set ROMDEV_URL.`);
  }
  const sid = init.sidOut;
  await rpc(sid, { jsonrpc: "2.0", method: "notifications/initialized" });

  const buildExtra = {};
  if (maxmod && soundbankPath) {
    buildExtra.maxmod = true;
    buildExtra.binaryIncludePaths = { "soundbank.bin": soundbankPath };
  }
  const b = await rpc(sid, {
    jsonrpc: "2.0", id: 2, method: "tools/call",
    params: {
      name: "build",
      arguments: {
        output: "rom", platform: "gba", language: "c", runtime: "libtonc",
        sources, includes, outputPath: outPath, ...buildExtra,
      },
    },
  });
  const t = JSON.parse(b.json.result.content[0].text);
  return { ok: !!t.ok, outPath: t.outputPath, issues: t.issues || [], log: t.logTail || "" };
}
