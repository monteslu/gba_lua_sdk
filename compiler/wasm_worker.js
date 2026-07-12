// wasm_worker.js - a persistent worker thread that HOLDS the cc65 WASM tools
// for the lifetime of one build and runs them on demand.
//
// Why a worker: the build orchestrator (bin/gtlua.js) is synchronous and drives
// the cc65/ca65/ld65 tools dozens of times (every SDK unit + the FLASH2M bank-
// placement ladder's many link passes). Spawning a fresh `node` + re-loading +
// re-instantiating the WASM + re-mounting the 11 MB cc65 share tree PER TOOL was
// ~85 ms of pure overhead each - 12x slower than native for no good reason.
//
// This worker is spawned ONCE per build. It caches the glue factories, the wasm
// binaries, and the (in-memory) share-tree file bytes, and mounts only the
// subdir each tool needs. The main thread blocks synchronously on each call via
// Atomics.wait (see wasm_sync_client.js), so run()/runLink() in the build stay
// synchronous and the placement ladder is untouched.
//
// emcc modules can't be reused across callMain (libc exit state), so we DO
// re-instantiate the module each call - but that's only ~7 ms; the killers were
// the subprocess spawn and the full-tree mount, both gone now.
//
// WEB IDE REUSE: runTool() below is the environment-agnostic core (load glue,
// mount the needed share subdir, stage inputs, callMain, collect outputs). Only
// (a) the file I/O (node:fs here; a virtual project FS in the browser) and (b)
// the transport at the bottom (node worker_threads + Atomics for a SYNC caller
// here) are environment-specific. The web IDE runs this same core in a browser
// Worker and exposes runTool as a rawr RPC method - rawr's async Promise model
// fits the browser build loop (no Atomics needed there), and rawr already has a
// browser-Worker transport. The CLI can't use rawr because its build loop is
// synchronous and rawr is async; hence the Atomics sync client here. Shared:
// the methods. Different: the transport. See internal-gtlua/WEB_IDE_PLAN.md.

import { parentPort } from "node:worker_threads";
import { readFile, readdir, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";

let toolchain, shareDir;
const factoryCache = new Map();       // gluePath -> { factory, wasmBinary }
const shareCache = new Map();         // subdir name -> [{ vfs, bytes }]

async function init() {
  const mod = await import("romdev-toolchain-cc65");
  toolchain = mod.toolchain;
  shareDir = mod.shareDir;
}

async function loadFactory(gluePath) {
  const hit = factoryCache.get(gluePath);
  if (hit) return hit;
  const wasmBinary = await readFile(gluePath.replace(/\.(m?js)$/, ".wasm"));
  const factory = (await import(gluePath)).default;
  const entry = { factory, wasmBinary };
  factoryCache.set(gluePath, entry);
  return entry;
}

// Read a share subdir's files into memory ONCE (cached across calls), returning
// a flat list of { vfs, bytes } to write into a fresh module's MEMFS each call.
async function loadShareSub(sub) {
  if (shareCache.has(sub)) return shareCache.get(sub);
  const out = [];
  const walk = async (hostDir, vfsDir) => {
    for (const e of await readdir(hostDir, { withFileTypes: true })) {
      const hp = path.join(hostDir, e.name), vp = vfsDir + "/" + e.name;
      if (e.isDirectory()) await walk(hp, vp);
      else if (e.isFile()) out.push({ vfs: vp, bytes: new Uint8Array(await readFile(hp)) });
    }
  };
  await walk(path.join(shareDir, sub), "/cc65/" + sub);
  shareCache.set(sub, out);
  return out;
}

// Only the subdir(s) a given tool needs (skips the 154-file target/ tree etc).
const SHARE_FOR = { cc65: ["include"], ca65: ["asminc"], ld65: ["lib", "cfg"] };

function ensureDir(FS, dir) {
  const parts = dir.split("/").filter(Boolean);
  let cur = "";
  for (const p of parts) { cur += "/" + p; try { FS.mkdir(cur); } catch {} }
}

function looksLikePath(tok) {
  return typeof tok === "string" && (tok.includes("/") || tok.includes("\\") || /\.\w+$/.test(tok));
}

// Run one tool. Reads inputs from + writes outputs to the SAME host paths the
// caller used (files already live on disk), so only {tool, argv} crosses the
// thread boundary. Returns { status, stderr }.
async function runTool(tool, argv) {
  const glue = toolchain[tool]?.gluePath;
  if (!glue) throw new Error(`no wasm tool '${tool}'`);
  const { factory, wasmBinary } = await loadFactory(glue);

  let log = "";
  let capturedExit = null;
  const mod = await factory({
    wasmBinary, noInitialRun: true,
    print: (m) => { log += m + "\n"; },
    printErr: (m) => { log += m + "\n"; },
    quit: (s, e) => { capturedExit = s; throw e ?? new Error("exit " + s); },
    onExit: (s) => { capturedExit = s; },
  });
  const FS = mod.FS;

  // mount only the share subdir(s) this tool needs, from the cached bytes
  for (const sub of SHARE_FOR[tool] ?? []) {
    for (const { vfs, bytes } of await loadShareSub(sub)) {
      ensureDir(FS, path.posix.dirname(vfs));
      FS.writeFile(vfs, bytes);
    }
  }
  ensureDir(FS, "/work");

  // stage inputs + rewrite argv to MEMFS paths (same mapping as the in-process
  // path used to do). Track outputs to copy back to the host after the run.
  const outMap = [];
  const vfsArgv = [];
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    // Output-file flags: the tool WRITES the arg to that path. ld65 emits the
    // cart (-o) plus a map (-m), label file (-Ln) and debug file (--dbgfile).
    // All must be redirected to /work and copied back to the host afterward, or
    // the tool fails trying to write to a host path that doesn't exist in MEMFS.
    if (tok === "-o" || tok === "-m" || tok === "-Ln" || tok === "--dbgfile") {
      const host = argv[i + 1], vfs = "/work/" + path.basename(host);
      vfsArgv.push(tok, vfs); outMap.push({ vfs, host }); i++; continue;
    }
    if (tok === "-C") {
      const host = argv[i + 1], vfs = "/work/" + path.basename(host);
      if (existsSync(host)) FS.writeFile(vfs, new Uint8Array(await readFile(host)));
      vfsArgv.push("-C", vfs); i++; continue;
    }
    if (tok === "-I") {
      const host = argv[i + 1];
      let vfs;
      if (host && host.replace(/\\/g, "/").endsWith("/asminc")) vfs = "/cc65/asminc";
      else { vfs = "/work/inc_" + outMap.length; if (existsSync(host)) {
        for (const e of await readdir(host, { withFileTypes: true })) if (e.isFile()) {
          ensureDir(FS, vfs); FS.writeFile(vfs + "/" + e.name, new Uint8Array(await readFile(path.join(host, e.name))));
        }
      } }
      vfsArgv.push("-I", vfs); i++; continue;
    }
    if (looksLikePath(tok) && existsSync(tok)) {
      const vfs = "/work/" + path.basename(tok);
      FS.writeFile(vfs, new Uint8Array(await readFile(tok)));
      vfsArgv.push(vfs); continue;
    }
    vfsArgv.push(tok);
  }

  let status = 0;
  const originalExit = process.exit;
  process.exit = (c) => { capturedExit = c ?? 0; throw new Error("intercepted exit " + capturedExit); };
  try { mod.callMain(vfsArgv); }
  catch (e) {
    if (e && typeof e === "object" && "status" in e) status = e.status;
    else if (capturedExit !== null) status = capturedExit;
    else status = status || 1;
  } finally { process.exit = originalExit; }
  if (capturedExit !== null && status === 0) status = capturedExit;
  if (mod.EXITSTATUS != null && status === 0) status = mod.EXITSTATUS;
  if (process.exitCode != null && process.exitCode !== 0) { if (status === 0) status = process.exitCode; process.exitCode = undefined; }

  for (const { vfs, host } of outMap) {
    try {
      const bytes = FS.readFile(vfs);
      await mkdir(path.dirname(host), { recursive: true });
      await writeFile(host, Buffer.from(bytes));
    } catch {}
  }

  return { status, stderr: log.replace(/\x1b\[[0-9;]*m/g, "") };
}

// --- protocol: the sync client posts { id, tool, argv, sab }. We run the tool
// and write the result INTO the SAB (not a message, which would race the flag):
//   [0]=flag(set 1 when done), [1]=status, [2]=stderr byte length (or -1 if the
//   log doesn't fit -> client grows the buffer and retries), then stderr bytes.
// Finally flip flag[0] and notify so the client's Atomics.wait unblocks. ---
const HEADER_INTS = 3;
let ready = false;
parentPort.on("message", async (msg) => {
  if (msg.type !== "run") return;
  if (!ready) { await init(); ready = true; }
  let result;
  try { result = await runTool(msg.tool, msg.argv); }
  catch (e) { result = { status: 1, stderr: `wasm ${msg.tool}: ${e?.stack ?? e?.message ?? e}\n` }; }

  const flag = new Int32Array(msg.sab, 0, HEADER_INTS);
  const enc = new TextEncoder().encode(result.stderr ?? "");
  const cap = msg.sab.byteLength - HEADER_INTS * 4;
  Atomics.store(flag, 1, result.status | 0);
  if (enc.length > cap) {
    Atomics.store(flag, 2, -1);        // signal "too small"; client grows+retries
  } else {
    new Uint8Array(msg.sab, HEADER_INTS * 4, enc.length).set(enc);
    Atomics.store(flag, 2, enc.length);
  }
  Atomics.store(flag, 0, 1);
  Atomics.notify(flag, 0);
});
parentPort.postMessage({ type: "ready" });
