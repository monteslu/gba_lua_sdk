// wasm_toolchain.js - run cc65 / ca65 / ld65 as bundled WASM, in-process.
//
// This is the zero-install build backend: instead of shelling out to a native
// cc65 (spawnSync), we load the Emscripten glue from `romdev-toolchain-cc65`
// and run each tool inside its own MEMFS. The public surface deliberately
// mirrors Node's spawnSync result - `{ status, stdout, stderr }` - so the build
// orchestrator in bin/gtlua.js can call a WASM tool exactly where it used to
// call a native one, with no change to the build logic.
//
// Path handling is the crux: the SDK's build passes REAL host paths on the
// command line (`-o /abs/out.s /abs/in.c`, `-C /abs/gametank.cfg`, `tc.lib`,
// `-I /abs/asminc`). We can't hand those to a WASM FS, so runTool():
//   1. mounts the cc65 share tree (asminc/include/lib/cfg) into MEMFS once,
//   2. copies each host input file referenced in argv into MEMFS,
//   3. rewrites the argv path tokens to their MEMFS locations,
//   4. runs the tool,
//   5. copies declared output files back out to the host.
//
// The FS-mapping core (mountHostDir / stageAndRewrite) is the same shape the
// web IDE needs - there the "host" is just a virtual project FS, so this module
// is the seam we reuse in the browser (see internal-gtlua/WEB_IDE_PLAN.md).

import { readFile, writeFile, readdir, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

// Lazily resolve romdev-toolchain-cc65's exported glue paths + share dir. Kept
// lazy so a clone-without-npm-install can still fall back to native cc65 without
// this import throwing at module load.
let _pkg = null;
async function pkg() {
  if (_pkg) return _pkg;
  const mod = await import("romdev-toolchain-cc65");
  _pkg = { toolchain: mod.toolchain, shareDir: mod.shareDir };
  return _pkg;
}

/** True if the WASM toolchain is installed and usable. */
export async function wasmToolchainAvailable() {
  try {
    const { toolchain, shareDir } = await pkg();
    return existsSync(toolchain.cc65.gluePath) && existsSync(shareDir);
  } catch {
    return false;
  }
}

// One cached factory per glue path (the emcc module factory is reusable; we
// instantiate a fresh module per call so MEMFS never leaks between tools).
const factoryCache = new Map();
async function loadFactory(gluePath) {
  const cached = factoryCache.get(gluePath);
  if (cached) return cached;
  const wasmPath = gluePath.replace(/\.(m?js)$/, ".wasm");
  const wasmBinary = await readFile(wasmPath);
  const factory = (await import(gluePath)).default;
  const entry = { factory, wasmBinary };
  factoryCache.set(gluePath, entry);
  return entry;
}

function ensureDir(FS, dir) {
  const parts = dir.split("/").filter(Boolean);
  let cur = "";
  for (const p of parts) {
    cur += "/" + p;
    try { FS.mkdir(cur); } catch { /* exists */ }
  }
}

async function mountHostDir(FS, hostDir, vfsDir) {
  ensureDir(FS, vfsDir);
  const entries = await readdir(hostDir, { withFileTypes: true });
  for (const e of entries) {
    const hp = path.join(hostDir, e.name);
    const vp = vfsDir + "/" + e.name;
    if (e.isDirectory()) await mountHostDir(FS, hp, vp);
    else if (e.isFile()) FS.writeFile(vp, new Uint8Array(await readFile(hp)));
  }
}

// Which argv tokens are host FILE paths we must stage into MEMFS. A token is a
// host path if it exists on disk as a file (inputs), or if it's the argument to
// -o (an output we'll copy back). Flag values like "none", "65c02", "500" are
// left alone because they don't exist as files.
function looksLikePath(tok) {
  return typeof tok === "string" && (tok.includes("/") || tok.includes("\\") || /\.\w+$/.test(tok));
}

/**
 * Run one cc65-family tool in WASM.
 * @param {"cc65"|"ca65"|"ld65"} tool
 * @param {string[]} argv  the SAME argv you'd pass a native tool (host paths ok)
 * @returns {Promise<{status:number, stdout:string, stderr:string}>}
 */
export async function runTool(tool, argv) {
  const { toolchain, shareDir } = await pkg();
  const glue = toolchain[tool]?.gluePath;
  if (!glue) throw new Error(`wasm toolchain has no tool '${tool}'`);
  const { factory, wasmBinary } = await loadFactory(glue);

  let log = "";
  // emcc tools signal a nonzero exit in several ways depending on the build:
  // throw an object with .status, call Module.quit(status), fire onExit(status),
  // or call process.exit(status). We capture ALL of them so a tool that PRINTS
  // an error (e.g. ld65 "Duplicate external identifier") but exits 1 is never
  // mistaken for success - that false-success is what silently corrupts a build.
  let capturedExit = null;
  const mod = await factory({
    wasmBinary,
    noInitialRun: true,
    print: (m) => { log += m + "\n"; },
    printErr: (m) => { log += m + "\n"; },
    quit: (status, toThrow) => { capturedExit = status; throw toThrow ?? new Error("exit " + status); },
    onExit: (status) => { capturedExit = status; },
  });
  const FS = mod.FS;

  // Mount the cc65 share tree so #include <...>, .inc lookups, none.lib and the
  // cc65 target cfgs resolve. We mount at /cc65/{asminc,include,lib,cfg} and
  // point the tool at them explicitly below.
  await mountHostDir(FS, shareDir, "/cc65");
  ensureDir(FS, "/work");

  // Stage input files + build the MEMFS argv. We track which output path maps to
  // which host path so we can copy results back after the run.
  const outMap = [];      // { vfs, host }
  const vfsArgv = [];
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    // Output-file flags (tool WRITES to the arg): -o cart, -m map, -Ln labels,
    // --dbgfile debug. All redirect to /work and copy back, else the tool fails
    // writing to a host path absent from MEMFS.
    if (tok === "-o" || tok === "-m" || tok === "-Ln" || tok === "--dbgfile") {
      // next token is an output host path
      const host = argv[i + 1];
      const base = path.basename(host);
      const vfs = "/work/" + base;
      vfsArgv.push(tok, vfs);
      outMap.push({ vfs, host });
      i++;
      continue;
    }
    if (tok === "-C") {
      // linker config: a host path we must stage in
      const host = argv[i + 1];
      const vfs = "/work/" + path.basename(host);
      if (existsSync(host)) FS.writeFile(vfs, new Uint8Array(await readFile(host)));
      vfsArgv.push("-C", vfs);
      i++;
      continue;
    }
    if (tok === "-I") {
      // include/asminc dir: if it's the bundled asminc, point at the mounted
      // copy; otherwise stage the host dir in.
      const host = argv[i + 1];
      let vfs;
      if (host && host.replace(/\\/g, "/").endsWith("/asminc")) {
        vfs = "/cc65/asminc";
      } else {
        vfs = "/work/inc_" + outMap.length;
        if (existsSync(host)) await mountHostDir(FS, host, vfs);
      }
      vfsArgv.push("-I", vfs);
      i++;
      continue;
    }
    // A bare host file path (an input source, an object, or none.lib): stage it.
    if (looksLikePath(tok) && existsSync(tok)) {
      const vfs = "/work/" + path.basename(tok);
      FS.writeFile(vfs, new Uint8Array(await readFile(tok)));
      vfsArgv.push(vfs);
      continue;
    }
    // Plain flag or value (e.g. "-t", "none", "--cpu", "65c02"): pass through.
    vfsArgv.push(tok);
  }

  // Run it. Intercept process.exit too (some emcc glue calls it directly on a
  // fatal tool error instead of throwing), so ld65/ca65 error exits are seen.
  let status = 0;
  const originalExit = process.exit;
  process.exit = (c) => { capturedExit = c ?? 0; throw new Error("intercepted exit " + capturedExit); };
  try {
    mod.callMain(vfsArgv);
  } catch (e) {
    if (e && typeof e === "object" && "status" in e) status = e.status;
    else if (capturedExit !== null) status = capturedExit;
    else status = status || 1;
  } finally {
    process.exit = originalExit;
  }
  if (capturedExit !== null && status === 0) status = capturedExit;
  if (mod.EXITSTATUS != null && status === 0) status = mod.EXITSTATUS;
  // Some cc65 tools set process.exitCode instead of exiting; honor it, then clear
  // so it doesn't leak into OUR process's exit code.
  if (process.exitCode != null && process.exitCode !== 0) {
    if (status === 0) status = process.exitCode;
    process.exitCode = undefined;
  }

  // Copy outputs back to the host.
  for (const { vfs, host } of outMap) {
    try {
      const bytes = FS.readFile(vfs);
      await mkdir(path.dirname(host), { recursive: true });
      await writeFile(host, Buffer.from(bytes));
    } catch { /* tool may not have produced it on failure */ }
  }

  // The WASM cc65 build emits ANSI color escapes in its diagnostics; native
  // cc65 does not. Strip them so downstream parsing (the ld65 overflow regex in
  // runLink, warning passthrough) sees the SAME plain text as native - otherwise
  // an escape sits between the quote and the segment name and the overflow
  // detector misses it, hard-failing a build that should re-target to FLASH2M.
  const plain = log.replace(/\x1b\[[0-9;]*m/g, "");
  // cc65 warnings/errors all go to the merged log; the caller's parsers expect
  // them on stderr (overflow detection, warning passthrough), so return the log
  // as stderr and leave stdout empty (native cc65 is silent on stdout too).
  return { status, stdout: "", stderr: plain };
}
