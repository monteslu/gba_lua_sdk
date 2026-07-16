// build-gba.mjs — build a gbalua game to a .gba ROM.
//
// Pipeline: Lua --(gbalua compiler)--> GBA C, bundled with the gba_api.c runtime
// + the sprite art, then compiled/linked to a .gba by the romdev GBA toolchain
// (arm-none-eabi-gcc + libtonc, all WASM: cc1-arm -> as -> ld -> objcopy).
//
// TWO BACKENDS for the C->ROM step (same toolchain code either way, so the ROM
// bytes are identical):
//   local (default) — `import { buildGbaC } from "romdev-platform-gba"` (the
//     package's own public entry since 0.11.0 — driver + WASM toolchain in one
//     dep, the same pipeline the romdev server runs) and build IN-PROCESS.
//   mcp — POST the sources to a running romdev server (default
//     http://127.0.0.1:7331/mcp). Still useful because the server keeps warm
//     toolchain workers (faster for rapid rebuilds).
// Force one with GBALUA_BACKEND=local|mcp.

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { compile, formatDiagnostics } from "./index.js";
import {
  sheetAssetsHeader, mapAssetHeader, mode7AssetHeader,
  alienAssetsHeader, mapStubHeader, mode7StubHeader,
} from "./asset-headers.mjs";
import { buildSoundbank } from "./soundbank.mjs";
import { aseToRgba } from "./ase-import.mjs";
import { tmxToRgba, listTmxImages } from "./tmx-import.mjs";
import { encodePng } from "./png-encode.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SDK_DIR = path.resolve(__dirname, "..", "gba-sdk");
const MCP_URL = process.env.ROMDEV_URL || "http://127.0.0.1:7331/mcp";

// The in-process backend: romdev-platform-gba's public entry (a hard dep, so
// it resolves unless the install is broken). Imported lazily so the mcp
// backend still works even if the platform package is somehow absent.
async function resolvePlatformGba() {
  try {
    const { buildGbaC, parseBuildLog } = await import("romdev-platform-gba");
    return { buildGbaC, parseBuildLog };
  } catch {
    return null;
  }
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

// Asset headers: image bytes -> generated C headers, via the browser-safe
// shared module (compiler/asset-headers.mjs) so CLI and web builds emit
// IDENTICAL text. We do NOT use encodeArt's GBA `tiles` palette — that stage
// emits a broken placeholder palette (romdev bug: "no master palette for gba").
//
// --sheet/--map/--mode7 accept .png natively, plus IMPORTS from the formats
// artists actually use: Aseprite (.ase/.aseprite, frame 0 flattened) and
// Tiled (.tmx, layers composited; tileset images read relative to the map).
// Imports normalize to PNG bytes, then take the exact same path as a PNG.
async function loadImageAsPng(filePath) {
  const abs = path.resolve(filePath);
  const ext = path.extname(abs).toLowerCase();
  if (ext === ".ase" || ext === ".aseprite") {
    const { width, height, rgba } = aseToRgba(new Uint8Array(await readFile(abs)));
    return encodePng(rgba, width, height);
  }
  if (ext === ".tmx") {
    const tmxText = await readFile(abs, "utf8");
    const images = {};
    for (const src of listTmxImages(tmxText)) {
      images[src.split("/").pop()] = new Uint8Array(await readFile(path.resolve(path.dirname(abs), src)));
    }
    const { width, height, rgba } = tmxToRgba(tmxText, images);
    return encodePng(rgba, width, height);
  }
  return readFile(abs);                         // .png (or anything decodePng reads)
}

async function convertSheet(_sid, imgPath, varPrefix) {
  return sheetAssetsHeader(await loadImageAsPng(imgPath), path.basename(imgPath), varPrefix);
}

async function convertMap(imgPath) {
  return mapAssetHeader(await loadImageAsPng(imgPath), path.basename(imgPath));
}

async function convertMode7(imgPath) {
  return mode7AssetHeader(await loadImageAsPng(imgPath), path.basename(imgPath));
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
    throw new Error("gbalua: compile failed\n" + formatDiagnostics(errs));
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
  let soundbankPath = null;    // a .bin on disk (the default bank, or --soundbank)
  let soundbankBytes = null;   // a bank built in-memory from --music modules
  if (usesSound) {
    sources["gba_sound.c"] = await rd("gba_sound.c");
    maxmod = true;
    if (opts.musicPaths?.length) {
      // --music song.xm [--music two.mod ...] -> compile a custom soundbank.
      // music(n) plays the nth --music module (soundbank position = module id).
      const modules = [];
      for (const p of opts.musicPaths) {
        modules.push({ name: path.basename(p), bytes: new Uint8Array(await readFile(path.resolve(p))) });
      }
      soundbankBytes = buildSoundbank(modules).bin;
    } else if (opts.soundbankPath) {
      // --soundbank bank.bin -> link a prebuilt Maxmod soundbank as-is.
      soundbankPath = path.resolve(opts.soundbankPath);
    } else {
      // the default soundbank (MOD_CHIPTUNE = music 0). The toolchain auto-emits
      // the .incbin stub for a binaryInclude named "soundbank.bin".
      soundbankPath = path.resolve(SDK_DIR, "..", "assets", "soundbank.bin");
    }
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
    : mapStubHeader();

  // --mode7 plane.png -> an 8bpp affine background (mode7/mode7_cam). Generated
  // into gba_mode7_asset.h, always present (empty stub if no --mode7).
  includes["gba_mode7_asset.h"] = opts.mode7Path
    ? await convertMode7(path.resolve(opts.mode7Path))
    : mode7StubHeader();

  // ---- backend dispatch ------------------------------------------------------
  const forced = process.env.GBALUA_BACKEND;   // "local" | "mcp" | unset
  const platform = forced === "mcp" ? null : await resolvePlatformGba();
  if (forced === "local" && !platform) {
    throw new Error("gbalua: GBALUA_BACKEND=local but romdev-platform-gba didn't import — reinstall deps (`npm i`).");
  }
  return platform
    ? buildLocal({ platform, sources, includes, maxmod, soundbankPath, soundbankBytes, outPath })
    : buildMcp({ sources, includes, maxmod, soundbankPath, soundbankBytes, outPath });
}

// ---- local backend: run the WASM toolchain in-process (no server) -----------
// buildGbaC comes from romdev-platform-gba's public entry (0.11.0+): the
// package vendors THE build driver, and romdevtools itself imports it from
// there — one pipeline, so ROM bytes are byte-identical to the MCP path by
// construction. binaryIncludes travel as Uint8Array (the native in-process
// contract — no base64 round-trip to get wrong). Warm-up note: each CLI
// invocation compiles the tool WASM once (cc1-arm is ~38 MB), so a one-shot
// build pays a small startup cost the warm MCP server doesn't; the bytes are
// the same either way.
async function buildLocal({ platform, sources, includes, maxmod, soundbankPath, soundbankBytes, outPath }) {
  const { buildGbaC, parseBuildLog } = platform;

  const binaryIncludes = {};
  if (maxmod && (soundbankBytes || soundbankPath)) {
    binaryIncludes["soundbank.bin"] = soundbankBytes ?? new Uint8Array(await readFile(soundbankPath));
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
async function buildMcp({ sources, includes, maxmod, soundbankPath, soundbankBytes, outPath }) {
  const init = await rpc(null, {
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "gbalua", version: "1" } },
  });
  if (!init.sidOut) {
    throw new Error(`gbalua: romdev-platform-gba didn't import AND no romdev server at ${MCP_URL}. Reinstall deps (\`npm i\`), or start the server / set ROMDEV_URL.`);
  }
  const sid = init.sidOut;
  await rpc(sid, { jsonrpc: "2.0", method: "notifications/initialized" });

  const buildExtra = {};
  if (maxmod && (soundbankBytes || soundbankPath)) {
    buildExtra.maxmod = true;
    // the MCP build tool takes soundbanks by path; a --music-built bank gets
    // written next to the ROM so the server can read it.
    let bankPath = soundbankPath;
    if (soundbankBytes) {
      bankPath = path.resolve(outPath + ".soundbank.bin");
      await mkdir(path.dirname(bankPath), { recursive: true });
      await writeFile(bankPath, soundbankBytes);
    }
    buildExtra.binaryIncludePaths = { "soundbank.bin": bankPath };
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
