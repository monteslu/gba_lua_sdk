#!/usr/bin/env node
// gtlua CLI - compile a .lua game to a GameTank .gtr cartridge.
//
//   gtlua build <main.lua> [--sheet sheet.gtg] [-o game.gtr]
//   gtlua c <main.lua>                     print the generated C (debugging)
//
// This is a thin NODE adapter over the environment-agnostic build pipeline in
// compiler/build.js: it resolves the cc65 toolchain (native binaries or the
// bundled WASM worker) and builds a `env` object of node fs/path/crypto +
// tool-runner primitives, then calls the shared build().
//
// Toolchain resolution (first hit wins):
//   $GTLUA_CC65_HOME/bin, <sdk repo>/tools/cc65/bin, then PATH.
// Build cc65 into tools/ with: scripts/install_tools.sh

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { compile, formatDiagnostics } from "../compiler/index.js";
import { build } from "../compiler/build.js";

const REPO = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const SDK = path.join(REPO, "sdk");

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

// The toolchain object gives each tool as an argv PREFIX (array) so execTool
// can splat it: native cc65 is ["/path/cc65"], the WASM backend is
// for wasm, run()/runLink() route the tool through the persistent worker via
// execTool -> runToolSync (no per-tool process spawn). Everything stays sync.
function nativeToolchain(home) {
  return {
    kind: "native",
    cc65: [path.join(home, "bin", "cc65")],
    ca65: [path.join(home, "bin", "ca65")],
    ld65: [path.join(home, "bin", "ld65")],
    lib: path.join(home, "lib", "none.lib"),
    asminc: path.join(home, "asminc"),
  };
}

// The bundled-WASM backend (romdev-toolchain-cc65). Zero native install. Tools
// run in ONE persistent worker thread that holds the WASM for the whole build
// (compiler/wasm_worker.js), driven synchronously via Atomics so the build
// orchestrator stays sync. `kind:"wasm"` makes execTool dispatch to
// runToolSync instead of spawning a process per tool (12x faster - the old
// per-tool `node` spawn + full share-tree re-mount was ~85 ms of pure overhead
// each). lib/asminc still resolve out of the installed package's share tree for
// callers that read tc.lib / tc.asminc directly.
function wasmToolchain() {
  const share = path.join(REPO, "node_modules", "romdev-toolchain-cc65", "share", "cc65");
  return {
    kind: "wasm",
    cc65: ["cc65"], ca65: ["ca65"], ld65: ["ld65"],   // tool name; execTool routes by kind
    lib: path.join(share, "lib", "none.lib"),
    asminc: path.join(share, "asminc"),
  };
}

function wasmToolchainInstalled() {
  return existsSync(path.join(REPO, "node_modules", "romdev-toolchain-cc65", "wasm", "cc65.js"));
}

// Selection order (first hit wins), with explicit override via GTLUA_TOOLCHAIN:
//   GTLUA_TOOLCHAIN=native|wasm  -> force that backend
//   otherwise: native if GTLUA_CC65_HOME / tools/cc65 / PATH cc65 is present,
//   else the bundled WASM if installed. So a `npm install` clone "just builds"
//   with zero native tools, and a source clone with cc65 on PATH uses native.
function findToolchain() {
  const forced = process.env.GTLUA_TOOLCHAIN;
  if (forced === "wasm") {
    if (!wasmToolchainInstalled()) fail("GTLUA_TOOLCHAIN=wasm but romdev-toolchain-cc65 is not installed (run: npm install).");
    return wasmToolchain();
  }

  const findNative = () => {
    const candidates = [];
    if (process.env.GTLUA_CC65_HOME) candidates.push(process.env.GTLUA_CC65_HOME);
    candidates.push(path.join(REPO, "tools", "cc65"));
    for (const home of candidates) {
      if (existsSync(path.join(home, "bin", "cc65"))) return nativeToolchain(home);
    }
    // fall back to PATH (cc65 --print-target-path locates lib/asminc)
    const probe = spawnSync("cc65", ["--version"], { encoding: "utf8" });
    if (probe.status === 0 || probe.status === 1) {
      const tp = spawnSync("cc65", ["--print-target-path"], { encoding: "utf8" });
      const targetPath = (tp.stdout || "").trim();
      const share = targetPath ? path.dirname(targetPath) : null;
      return {
        kind: "native",
        cc65: ["cc65"], ca65: ["ca65"], ld65: ["ld65"],
        lib: share ? path.join(share, "lib", "none.lib") : "none.lib",
        asminc: share ? path.join(share, "asminc") : null,
      };
    }
    return null;
  };

  if (forced === "native") {
    const n = findNative();
    if (n) return n;
    fail("GTLUA_TOOLCHAIN=native but no cc65 found (scripts/install_tools.sh, or put cc65 on PATH).");
  }

  const native = findNative();
  if (native) return native;
  if (wasmToolchainInstalled()) return wasmToolchain();

  fail(
    "No cc65 toolchain found. Either:\n" +
    "  - run `npm install` (uses the bundled cc65 WASM, no native tools needed), or\n" +
    "  - run scripts/install_tools.sh (builds native cc65 into tools/cc65), or\n" +
    "  - put cc65/ca65/ld65 on your PATH."
  );
}

// The active toolchain kind ("native" | "wasm"), set by prepareToolchain() from
// findToolchain().kind. Decides whether execTool spawns a native binary or
// drives the persistent WASM worker synchronously.
let toolchainKind = "native";
let _runToolSync = null;   // lazily imported so native builds never load the worker

// Execute one tool. For native, `tool` is [binaryPath]; for wasm, tool[0] is the
// tool NAME ("cc65"/"ca65"/"ld65") and we route to the persistent worker. Both
// return spawnSync's shape: { status, stdout, stderr }.
function execTool(tool, args) {
  if (toolchainKind === "wasm") {
    // _runToolSync is preloaded by prepareToolchain() before the build starts
    // (the module is ESM, so it's imported at the async top level, not here).
    return _runToolSync(tool[0], args);
  }
  const [cmd, ...pre] = tool;
  return spawnSync(cmd, [...pre, ...args], { encoding: "utf8" });
}

// Called once (async) before a build. If the selected toolchain is WASM, load
// the sync client + set the kind so execTool routes to the persistent worker.
async function prepareToolchain() {
  const tc = findToolchain();
  toolchainKind = tc.kind;
  if (tc.kind === "wasm" && !_runToolSync) {
    const mod = await import("../compiler/wasm_sync_client.js");
    _runToolSync = mod.runToolSync;
    _closeWorker = mod.closeWorker;
  }
  return tc;
}
let _closeWorker = null;

// Build the environment-agnostic `env` object the shared build() runs against,
// from node's fs/path/crypto and the resolved toolchain. runTool(name, args)
// maps a tool NAME to that toolchain's argv-prefix and drives execTool.
function makeNodeEnv(tc, sdkDir) {
  return {
    readFile: (p) => readFileSync(p),
    readText: (p) => readFileSync(p, "utf8"),
    writeFile: (p, x) => writeFileSync(p, x),
    exists: (p) => existsSync(p),
    size: (p) => statSync(p).size,
    mkdirp: (p) => { mkdirSync(p, { recursive: true }); },
    join: (...parts) => path.join(...parts),
    dirname: (p) => path.dirname(p),
    basename: (p, ext) => path.basename(p, ext),
    extname: (p) => path.extname(p),
    sdk: sdkDir,
    sdkFile: (name) => path.join(sdkDir, name),
    runTool: (name, args) => execTool(tc[name], args),
    lib: tc.lib,
    asminc: tc.asminc,
    hash: (bytes) => createHash("sha1").update(bytes).digest("hex"),
    log: (msg) => console.log(msg),
    warn: (msg) => console.error(msg),
    debug: !!process.env.GTLUA_DEBUG,
  };
}

// Read a .lua file and compile it to C for the `c` debug command. Mirrors the
// build pipeline's diagnostics handling (warnings to stderr, errors exit 1).
function compileLuaCli(entry, opts = {}) {
  const source = readFileSync(entry, "utf8");
  const result = compile(source, path.basename(entry), opts);
  const warnings = result.diagnostics.filter((d) => d.severity === "warning");
  if (warnings.length) console.error(formatDiagnostics(warnings));
  if (!result.ok) {
    console.error(formatDiagnostics(result.diagnostics.filter((d) => d.severity === "error")));
    process.exit(1);
  }
  return result;
}

// Resolve the toolchain, build the node env, and run the shared build().
// The entry path is resolved to an absolute path first so build() derives an
// absolute project/build dir (the toolchain runs from the repo root).
async function runBuild(entry, opts) {
  if (!existsSync(entry)) fail(`no such file: ${entry}`);
  const tc = await prepareToolchain();
  const env = makeNodeEnv(tc, SDK);
  const absEntry = path.resolve(entry);
  try {
    await build(absEntry, opts, env);
  } catch (e) {
    fail(e?.message ?? String(e));
  }
}

// ---- main -------------------------------------------------------------------

const [, , cmd, ...rest] = process.argv;

// --target gba routes to the GBA build (Lua -> GBA C + gba_api.c runtime -> .gba
// via the romdev arm toolchain). Handled before the GameTank path below.
const tIdx = rest.indexOf("--target");
const target = tIdx !== -1 ? rest[tIdx + 1] : "gametank";

if (cmd === "build" && target === "gba") {
  const oIdx = rest.indexOf("-o");
  const outPath = oIdx !== -1 ? rest[oIdx + 1] : undefined;
  const shIdx = rest.indexOf("--sheet");
  const sheetPath = shIdx !== -1 ? rest[shIdx + 1] : undefined;
  const mpIdx = rest.indexOf("--map");
  const mapPath = mpIdx !== -1 ? rest[mpIdx + 1] : undefined;
  const m7Idx = rest.indexOf("--mode7");
  const mode7Path = m7Idx !== -1 ? rest[m7Idx + 1] : undefined;
  const valueOf = (i) => (i === -1 ? -2 : i + 1);
  const entry = rest.filter((a, i) =>
    i !== oIdx && i !== valueOf(oIdx) &&
    i !== tIdx && i !== valueOf(tIdx) &&
    i !== shIdx && i !== valueOf(shIdx) &&
    i !== mpIdx && i !== valueOf(mpIdx) &&
    i !== m7Idx && i !== valueOf(m7Idx))[0];
  if (!entry) fail("usage: gtlua build --target gba <main.lua> [--sheet sprites.png] [--map level.png] [--mode7 plane.png] [-o game.gba]");
  const out = outPath ?? path.join(path.dirname(path.resolve(entry)),
    path.basename(entry, path.extname(entry)) + ".gba");
  const { buildGba } = await import("../compiler/build-gba.mjs");
  const r = await buildGba(entry, out, { sheetPath, mapPath, mode7Path });
  if (r.issues?.length) {
    for (const iss of r.issues) console.error(`${iss.severity ?? "error"}: ${iss.file ?? ""}:${iss.line ?? ""} ${iss.message}`);
  }
  if (!r.ok) { if (r.log) console.error(r.log); fail("gba-lua: build failed"); }
  console.log(`${r.outPath} (GBA ROM)`);
} else if (cmd === "build") {
  const oIdx = rest.indexOf("-o");
  const outPath = oIdx !== -1 ? rest[oIdx + 1] : undefined;
  const sIdx = rest.indexOf("--sheet");
  const sheetPath = sIdx !== -1 ? rest[sIdx + 1] : undefined;
  const fIdx = rest.indexOf("--frames");
  const framesPath = fIdx !== -1 ? rest[fIdx + 1] : undefined;
  const gIdx = rest.indexOf("--songs");
  const songsPaths = gIdx !== -1 ? rest[gIdx + 1].split(",").filter(Boolean) : [];
  const nIdx = rest.indexOf("--num8");
  const valueOf = (i) => (i === -1 ? -2 : i + 1);   // index of a flag's value arg
  const entry = rest.filter((a, i) =>
    i !== oIdx && i !== valueOf(oIdx) &&
    i !== sIdx && i !== valueOf(sIdx) &&
    i !== fIdx && i !== valueOf(fIdx) &&
    i !== gIdx && i !== valueOf(gIdx) &&
    i !== nIdx)[0];
  if (!entry) fail("usage: gtlua build <main.lua> [--sheet foo.gtg] [--frames foo.gsi] [--songs a.gtm2,b.gtm2] [--num8] [-o game.gtr]");
  await runBuild(entry, { outPath, sheetPath, num8: nIdx !== -1, framesPath, songsPaths });
  if (_closeWorker) _closeWorker();
} else if (cmd === "run") {
  // build then play in a window (bundled core), no external emulator needed.
  const oIdx = rest.indexOf("-o");
  const sIdx = rest.indexOf("--sheet");
  const fIdx = rest.indexOf("--frames");
  const nIdx = rest.indexOf("--num8");
  const valueOf = (i) => (i === -1 ? -2 : i + 1);
  const entry = rest.filter((a, i) =>
    i !== oIdx && i !== valueOf(oIdx) &&
    i !== sIdx && i !== valueOf(sIdx) &&
    i !== fIdx && i !== valueOf(fIdx) &&
    i !== nIdx)[0];
  if (!entry) fail("usage: gtlua run <main.lua> [--sheet foo.gtg] [--frames foo.gsi] [--num8]");
  // if given a prebuilt .gtr, run it directly; else build to a temp .gtr first.
  let gtr;
  if (entry.endsWith(".gtr")) {
    gtr = entry;
  } else {
    gtr = path.join(path.dirname(path.resolve(entry)), path.basename(entry, path.extname(entry)) + ".gtr");
    await runBuild(entry, {
      outPath: gtr,
      sheetPath: sIdx !== -1 ? rest[sIdx + 1] : undefined,
      num8: nIdx !== -1,
      framesPath: fIdx !== -1 ? rest[fIdx + 1] : undefined,
    });
    if (_closeWorker) _closeWorker();
  }
  try {
    const { runRom } = await import("./gtlua-run.mjs");
    await runRom(gtr);
  } catch (e) {
    if (e && e.code === "SDL_UNAVAILABLE") {
      // graceful fallback: hand the built .gtr to an external emulator.
      const runner = path.join(REPO, "scripts", process.platform === "win32" ? "run_emulator.cmd" : "run_emulator.sh");
      const r = spawnSync(runner, [gtr], { stdio: "inherit" });
      if (r.status !== 0) {
        fail(
          "Could not open a window (the optional @kmamal/sdl dependency isn't\n" +
          "installed on this platform), and no external GameTank emulator was found.\n" +
          `Your cart built fine: ${gtr}\n` +
          "Run it with an emulator, or set GAMETANK_EMULATOR / put one on PATH."
        );
      }
    } else {
      fail(`gtlua run: ${e?.message ?? e}`);
    }
  }
} else if (cmd === "c") {
  if (!rest[0]) fail("usage: gtlua c <main.lua>");
  process.stdout.write(compileLuaCli(rest[0]).c);
} else if (cmd === "gfx") {
  const { gfxCli } = await import("./gtlua-gfx.mjs");
  gfxCli(rest);
} else {
  fail("usage: gtlua build <main.lua> [--sheet foo.gtg] [--frames foo.gsi] [--num8] [-o game.gtr]\n" +
    "       gtlua run   <main.lua|game.gtr> [--sheet ...] [--num8]   build + play in a window\n" +
    "       gtlua gfx import <in.png|in.p8|in.gtg> [-o out.gtg]\n" +
    "       gtlua gfx export <in.gtg> [-o out.png]\n" +
    "       gtlua c <main.lua>");
}
