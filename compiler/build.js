// gtlua build pipeline - environment-agnostic.
//
// The entire cart build (lua -> C -> cc65/ca65/ld65 -> .gtr, including the
// FLASH2M bank-placement ladder) lives here and takes an injected `env` for
// every filesystem, path, hash, tool-running and logging primitive. The node
// CLI (bin/gtlua.js) supplies a node-backed env; a browser can supply its own
// (in-memory FS + a WASM toolchain) and call the SAME build().
//
// Cart tiers: the build first targets a flat 32 KB EEPROM cart. If the game
// overflows it, the build automatically re-targets the 2 MB FLASH2M cart:
// game functions are partitioned across three 16 KB banks (update path /
// draw+init path / spill+sheet) by call-graph reachability, cross-bank calls
// are routed through generated far-call stubs in the fixed bank, and the
// final image is a 2 MB flash layout the emulator size-detects.
//
// @typedef {object} BuildEnv
// @property {(path:string)=>Uint8Array} readFile      binary; throws if missing
// @property {(path:string)=>string}     readText      utf8; throws if missing
// @property {(path:string, data:(string|Uint8Array))=>void} writeFile  string -> utf8
// @property {(path:string)=>boolean}    exists
// @property {(path:string)=>number}     size          bytes on disk
// @property {(path:string)=>void}       mkdirp
// @property {(...parts:string[])=>string} join
// @property {(p:string)=>string}        dirname
// @property {(p:string, ext?:string)=>string} basename
// @property {(p:string)=>string}        extname
// @property {string}                    sdk           SDK dir path
// @property {(name:string)=>string}     sdkFile       = join(sdk, name)
// @property {(tool:string, argv:string[])=>{status:number,stdout:string,stderr:string}} runTool
// @property {string}                    lib           path to none.lib
// @property {string|null}               asminc        asminc dir path or null
// @property {(bytes:(string|Uint8Array))=>string} hash sha1 hex
// @property {(msg:string)=>void}        log
// @property {(msg:string)=>void}        warn
// @property {boolean}                   debug

import { compile, formatDiagnostics } from "./index.js";
import { peephole } from "./peephole.js";
import { parseGsi, bakeFrameTable } from "./gfx.mjs";

const BANK_SIZE = 0x4000;
const FLASH_SIZE = 0x200000;
const BANK_MARGIN = 256;          // safety slack per bank (size estimates)

/** Throw on a fatal build error (the CLI adapter catches and exits). */
function fail(msg) {
  throw new Error(msg);
}

// `tool` is a tool NAME ("cc65"/"ca65"/"ld65"). run() dispatches via env.runTool.
function run(env, tool, args) {
  const r = env.runTool(tool, args);
  if (r.error) fail(`${tool}: ${r.error.message}`);
  if (r.status !== 0) {
    if (r.stdout) env.warn(r.stdout);
    if (r.stderr) env.warn(r.stderr);
    fail(`${tool} failed (exit ${r.status})`);
  }
  if (r.stderr) env.warn(r.stderr); // warnings
  return r;
}

// like run() but overflow-tolerant: returns {ok, overflows:[{segment,bytes}]}
function runLink(env, tool, args) {
  const r = env.runTool(tool, args);
  if (r.error) fail(`${tool}: ${r.error.message}`);
  const text = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  if (r.status === 0) return { ok: true, overflows: [], text };
  const overflows = [];
  // NB: ld65 says "by 1 byte" (singular) - a 1-byte overflow with a plural-
  // only pattern is invisible to the juggler and hard-fails the build
  const re = /Segment '?‘?([A-Z0-9]+)'?’? overflows memory area '?‘?\w+'?’? by (\d+) bytes?/g;
  let m;
  while ((m = re.exec(text)) !== null) overflows.push({ segment: m[1], bytes: Number(m[2]) });
  if (!overflows.length) {
    env.warn(text);
    fail(`${tool} failed (exit ${r.status})`);
  }
  return { ok: false, overflows, text };
}

// Sum every non-game module's bytes per bank from an ld65 map (SDK objects,
// the embedded sheet, cross-bank stubs). This is the REAL immovable load -
// the capacity model uses it instead of hand-tuned constants, which went
// stale every time an SDK body moved banks.
const MAP_SEG_BIN = {
  B0CODE: "b0", B0RODATA: "b0", B1CODE: "b1", B1RODATA: "b1",
  B2CODE: "b2", B2RODATA: "b2", SHEET: "b2",
  CODE: "fixed", RODATA: "fixed", DATA: "fixed",
};
function sdkLoadFromMap(env, mapPath) {
  let txt;
  try { txt = env.readText(mapPath); } catch { return null; }
  const sec = txt.split("Modules list:")[1]?.split("Segment list:")[0];
  if (!sec) return null;
  const load = { b0: 0, b1: 0, b2: 0, fixed: 0 };
  const port = { b0: 0, b1: 0, b2: 0, fixed: 0 };
  let mod = null;
  for (const ln of sec.split("\n")) {
    // module headers: "path/foo.o:" AND library members "none.lib(bar.o):"
    const mh = ln.match(/^([\w./-]+\.o|[\w./-]+\.lib\([\w.-]+\.o\)):/);
    if (mh) { mod = mh[1].split("/").pop(); continue; }
    if (!mod) continue;
    const sm = ln.match(/^\s+(\w+)\s+Offs=\S+\s+Size=(\S+)/);
    if (!sm) continue;
    const bin = MAP_SEG_BIN[sm[1]];
    if (!bin) continue;
    (mod === "main.o" ? port : load)[bin] += parseInt(sm[2], 16);
  }
  return { load, port };
}

// scale each function's size estimate so per-bank sums match the REAL bytes
// ld65 measured - the ~2 bytes/line heuristic runs ~10% off, which is the
// whole gap between converging and thrashing on carts at the capacity cliff
function calibrateSizes(sizes, placement, realPort) {
  const est = { b0: 0, b1: 0, b2: 0, fixed: 0 };
  for (const [n, bin] of Object.entries(placement)) est[bin] += sizes.get(n) ?? 0;
  for (const [n, bin] of Object.entries(placement)) {
    if (!est[bin] || !realPort[bin]) continue;
    const f = Math.min(3, Math.max(0.5, realPort[bin] / est[bin]));
    sizes.set(n, Math.round((sizes.get(n) ?? 0) * f));
  }
}

function compileLua(env, entry, opts = {}) {
  const source = env.readText(entry);
  const result = compile(source, env.basename(entry), opts);
  const warnings = result.diagnostics.filter((d) => d.severity === "warning");
  if (warnings.length) env.warn(formatDiagnostics(warnings));
  if (!result.ok) {
    env.warn(formatDiagnostics(result.diagnostics.filter((d) => d.severity === "error")));
    throw new Error("gtlua: compile failed");
  }
  return result;
}

// parse per-function code-size estimates out of a cc65-generated .s file
function functionSizes(env, sPath) {
  const sizes = new Map();
  let name = null, count = 0;
  for (const ln of env.readText(sPath).split("\n")) {
    const m = ln.match(/^\.proc\s+_gtl_(\w+)/);
    if (m) { name = m[1]; count = 0; continue; }
    if (ln.startsWith(".endproc")) {
      if (name) sizes.set(name, Math.round(count * 2.0)); // ~2 bytes/line
      name = null;
      continue;
    }
    if (name && ln.trim() && !ln.startsWith(";")) count++;
  }
  return sizes;
}

// packbits: [n, b0..bn-1] literal run (n 1..127), [n|0x80, v] repeat run
// (n 3..127). Sheets are ~half zero bytes, so this typically halves the
// ROM cost. Only when the game never re-reads the raw sheet (bg_compose
// random-accesses it), else the plain form is kept.
function packbits(raw) {
  const out = [];
  let i = 0;
  while (i < raw.length) {
    let run = 1;
    while (run < 127 && i + run < raw.length && raw[i + run] === raw[i]) run++;
    if (run >= 3) {
      out.push(0x80 | run, raw[i]);
      i += run;
      continue;
    }
    let lit = i;
    while (lit < raw.length && lit - i < 127) {
      let r = 1;
      while (r < 3 && lit + r < raw.length && raw[lit + r] === raw[lit]) r++;
      if (r >= 3) break;
      lit++;
    }
    out.push(lit - i, ...raw.slice(i, lit));
    i = lit;
  }
  return out;
}

const GTG_BYTES = 16384;   // one native .gtg quadrant = 128x128 8bpp
// Composed tiles live in cells 0-127 = the top 8 tile-rows = the first 8 KB of a
// quadrant (sprite cells 128-255 sit below and are never composed, only spr'd).
// So a composing native game stores just this top slice raw for compose re-reads.
const GTG_COMPOSE_BYTES = 8192;

// A native .gtg sheet is 16384 bytes (one 128x128 8bpp quadrant). This is the
// only sheet format; makeSheetC rejects any other size.
function isGtgSheet(env, sheetPath) {
  return !!sheetPath && env.size(sheetPath) === GTG_BYTES;
}

// Given foo.gtg, return the ordered list of quadrant files that exist, in the
// official name / _1 / _2 / _3 order (NW, NE, SW, SE). A single-quadrant sheet
// is just [foo.gtg]. The sibling quadrants are what `gtlua gfx import` emits
// when a source image is larger than 128x128.
function discoverQuadrants(env, sheetPath) {
  const stem = sheetPath.replace(/\.gtg$/i, "");
  const files = [sheetPath];
  for (let i = 1; i < 4; i++) {
    const q = `${stem}_${i}.gtg`;
    if (env.exists(q)) files.push(q);
  }
  return files;
}

// Total packbits-compressed ROM cost of a native .gtg sheet's quadrants (for
// the FLASH2M bank-capacity accounting).
function gtgSheetBytes(env, sheetPath) {
  return discoverQuadrants(env, sheetPath)
    .reduce((n, q) => n + packbits(Array.from(env.readFile(q))).length, 0);
}

// Bytes of the native .gtg that land in the SHEET segment (bank 2), for the
// bank-2 capacity juggler. Non-composing = all quadrants packbits'd. Composing =
// only quadrant 0's raw top 8 KB (the packbits'd bottom half goes to bank 1, not
// bank 2), plus any further quadrants packbits'd.
function gtgSheetRomBytes(env, sheetPath, composes) {
  if (!composes) return gtgSheetBytes(env, sheetPath);
  const quads = discoverQuadrants(env, sheetPath);
  let n = GTG_COMPOSE_BYTES;   // raw top only; bottom half is in bank 1
  for (const q of quads.slice(1)) n += packbits(Array.from(env.readFile(q))).length;
  return n;
}

// Bake a .gsi frame table into a C array for the runtime. .gsi gx/gy are
// full-sheet pixel coords (0..255); the runtime wants 0..127 within a quadrant
// with the quadrant selector in bit7 (GX bit7 = right, GY bit7 = bottom). We
// derive the quadrant from gx/gy >= 128 and bake bit7 back on, so gt_gspr_frame
// gets final GRAM source coords and needs zero quadrant logic. 6 bytes/frame.
function makeFrameTableC(env, framesPath, banked) {
  const frames = parseGsi(env.readFile(framesPath));
  const quadOf = (i) => ((frames[i].gx >= 128 ? 1 : 0) | (frames[i].gy >= 128 ? 2 : 0));
  // mask gx/gy to the low 7 bits before bakeFrameTable re-adds bit7 by quadrant
  const masked = frames.map((f) => ({ ...f, gx: f.gx & 127, gy: f.gy & 127 }));
  const tab = bakeFrameTable(masked, quadOf);
  const decl = `static const unsigned char frametab[${tab.length}] = {${Array.from(tab).join(",")}};`;
  const reg = `gt_frames_register(frametab, ${frames.length}U);`;
  return { decl, reg, banked };
}

// Emit sheet.c for a NATIVE .gtg sheet: each 16384-byte quadrant is packbits-
// compressed into its own ROM array and loaded into its GRAM quadrant (0=NW,
// 1=NE, 2=SW, 3=SE) by gt_gsheet_load_packed. The grid spr(n) draw path reads
// GRAM the same way regardless of how it was filled, so games keep working with
// no Lua change - see docs/GRAPHICS.md. `banked` places the blobs in bank 2.
// A --frames foo.gsi adds a frame table (for sprf) alongside, in the same bank.
const GTG_BOTTOM_BANK = 1;   // composing games park the sheet's bottom half here

function makeGSheetC(env, sheetPath, banked, framesPath, composes) {
  const quads = discoverQuadrants(env, sheetPath);
  // SHEET-segment (bank 2) declarations, and a separate B1RODATA (bank 1) chunk
  // for a composing game's sheet bottom-half (so a full native sheet doesn't have
  // to share bank 2 with the compose code - cart banks are cheap on hardware).
  const sheetDecls = [];
  const b1Decls = [];
  const calls = [];       // run with bank 2 mapped
  const b1Calls = [];     // run with bank GTG_BOTTOM_BANK mapped

  quads.forEach((q, i) => {
    const bytes = Array.from(env.readFile(q));
    // A COMPOSING game (bg_compose / bg_tile / bg_coln / track_*) re-reads the
    // sheet's TILE pixels from ROM each compose (via gt_gsheet_ptr). Composed
    // tiles are cells 0-127 = the top 8 tile-rows = the first 8 KB of the
    // quadrant; sprite cells 128-255 sit below (spr()-only, from GRAM). Split
    // quadrant 0: the top 8 KB raw rides bank 2 with the compose code (serves
    // compose AND GRAM rows 0-63); the packbits'd bottom half rides bank 1 and
    // loads GRAM rows 64-127 at boot. A full 16 KB sheet + the compose code
    // won't fit ONE 16 KB bank, so we spend a second bank (size is free as long
    // as the whole cart fits the 2 MB FLASH2M).
    if (composes && i === 0) {
      const top = bytes.slice(0, GTG_COMPOSE_BYTES);
      const bot = packbits(bytes.slice(GTG_COMPOSE_BYTES));
      sheetDecls.push(`static const unsigned char gsheet_raw[${top.length}] = {${top.join(",")}};`);
      b1Decls.push(`static const unsigned char gsheet0b[${bot.length}] = {${bot.join(",")}};`);
      calls.push(`gt_gsheet_load_top(gsheet_raw, 0);`);
      calls.push(`gt_gsheet_ptr = gsheet_raw;`);
      b1Calls.push(`gt_gsheet_load_bottom(gsheet0b, ${bot.length}U);`);
    } else {
      const pk = packbits(bytes);
      sheetDecls.push(`static const unsigned char gsheet${i}[${pk.length}] = {${pk.join(",")}};`);
      calls.push(`gt_gsheet_load_packed(gsheet${i}, ${pk.length}U, ${i});`);
    }
  });
  if (framesPath) {
    const ft = makeFrameTableC(env, framesPath, banked);
    sheetDecls.push(ft.decl);
    calls.push(ft.reg);
  }

  if (!banked) {
    return `#include "gt_api.h"\n${sheetDecls.join("\n")}\n${b1Decls.join("\n")}\n` +
      `void gt_sheet_init(void) { ${calls.join(" ")} ${b1Calls.join(" ")} }\n`;
  }
  // banked: bank-2 data in SHEET, bank-1 bottom-half in B1RODATA; init maps bank
  // 2 (top + tables), then bank 1 (bottom-half GRAM load), then back to bank 2.
  const b1 = b1Calls.length
    ? `gt_bank(${GTG_BOTTOM_BANK}); ${b1Calls.join(" ")} gt_bank(2);`
    : "";
  return `#include "gt_api.h"\n` +
    `#pragma rodata-name ("SHEET")\n${sheetDecls.join("\n")}\n` +
    (b1Decls.length ? `#pragma rodata-name ("B1RODATA")\n${b1Decls.join("\n")}\n` : "") +
    `#pragma rodata-name ("RODATA")\n` +
    `void gt_sheet_init(void) { gt_bank(2); ${calls.join(" ")} ${b1} }\n`;
}

function makeSheetC(env, sheetPath, banked, framesPath, composes) {
  if (!sheetPath) return `void gt_sheet_init(void) {}\n`;
  if (isGtgSheet(env, sheetPath)) return makeGSheetC(env, sheetPath, banked, framesPath, composes);
  const n = env.size(sheetPath);
  fail(`--sheet expects a native .gtg sprite sheet (16384 bytes/quadrant; got ${n}). ` +
    `Convert a PICO-8 cart or a PNG with: gtlua gfx import <in> -o sheet.gtg`);
}

// ---- FLASH2M bank placement -------------------------------------------------
//
// Any placement is CORRECT (far-call stubs bridge every cross-bank edge);
// the solver only chooses a good one: update path in bank 0, draw+init path
// in bank 1, shared functions in the fixed bank (stub-free hot loops), then
// moves functions between bins when a bank overflows.

function reachable(callGraph, roots) {
  const seen = new Set();
  const stack = roots.filter((r) => callGraph.has(r));
  while (stack.length) {
    const n = stack.pop();
    if (seen.has(n)) continue;
    seen.add(n);
    for (const c of callGraph.get(n) ?? []) stack.push(c);
  }
  return seen;
}

function initialPlacement(callGraph) {
  const A = reachable(callGraph, ["_update", "_update60"]);
  const B = reachable(callGraph, ["_draw", "_init"]);
  const placement = {};
  for (const name of callGraph.keys()) {
    const inA = A.has(name), inB = B.has(name);
    if (inA && inB) placement[name] = "fixed";
    else if (inA) placement[name] = "b0";
    else if (inB) placement[name] = "b1";
    else placement[name] = "fixed";
  }
  // callbacks stay in their path's bank (main() selects it before the call)
  if (placement._update) placement._update = "b0";
  if (placement._update60) placement._update60 = "b0";
  if (placement._draw) placement._draw = "b1";
  if (placement._init) placement._init = "b1";
  return placement;
}

// segment name -> placement bin
const SEG_BIN = { B0CODE: "b0", B1CODE: "b1", B2CODE: "b2", CODE: "fixed", RODATA: "fixed", B0RODATA: "b0", B1RODATA: "b1", B2RODATA: "b2",
  // a VECTORS overflow means the fixed window ran past its end
  VECTORS: "fixed", DATA: "fixed" };

// ---- layout quality ---------------------------------------------------------
// The packer's job is FIT; this scores SPEED: every cross-bank call edge
// costs a far-call stub (~100 cycles), and an edge on the per-frame path
// costs it every frame. Score = weighted count of stubbed edges, lower is
// better. Used by the post-convergence repair pass to compare layouts.
function hotSet(callGraph) {
  const hot = new Set();
  const stack = ["_update", "_update60", "_draw"];
  while (stack.length) {
    const n = stack.pop();
    if (hot.has(n)) continue;
    hot.add(n);
    for (const c of callGraph.get(n) ?? []) stack.push(c);
  }
  return hot;
}
// BFS depth from the per-frame roots: depth 1 = the frame dispatch layer
// (runs every frame), deeper = increasingly conditional. Non-reachable
// functions get Infinity (init/menu code - coldest).
function hotDepth(callGraph) {
  const depth = new Map();
  let ring = ["_update", "_update60", "_draw"];
  let d = 0;
  while (ring.length) {
    const next = [];
    for (const n of ring) {
      if (depth.has(n)) continue;
      depth.set(n, d);
      for (const c of callGraph.get(n) ?? []) if (!depth.has(c)) next.push(c);
    }
    ring = next;
    d++;
  }
  return depth;
}
function layoutScore(placement, callGraph, hot) {
  let score = 0;
  for (const [caller, callees] of callGraph) {
    const cb = placement[caller] ?? "fixed";
    for (const cee of callees) {
      const eb = placement[cee] ?? "fixed";
      if (eb !== "fixed" && eb !== cb) score += (hot.has(caller) ? 10 : 1) + (hot.has(cee) ? 10 : 0);
    }
  }
  return score;
}
// the stubbed edges of a layout, worst (hot) first - repair candidates
function stubbedEdges(placement, callGraph, hot, depths) {
  const edges = [];
  for (const [caller, callees] of callGraph) {
    const cb = placement[caller] ?? "fixed";
    for (const cee of callees) {
      const eb = placement[cee] ?? "fixed";
      if (eb !== "fixed" && eb !== cb) {
        edges.push({ caller, callee: cee,
          d: Math.min(depths?.get(caller) ?? 99, depths?.get(cee) ?? 99),
          w: (hot.has(caller) ? 10 : 1) + (hot.has(cee) ? 10 : 0) });
      }
    }
  }
  edges.sort((a, b) => b.w - a.w || (a.d ?? 99) - (b.d ?? 99));
  return edges;
}

// rebalance after a link overflow: move functions out of the fat bins.
// fixedHeadroom is the fixed-bank packing margin, owned by build() and passed
// in (build rebinds it across the ladder rungs).
function rebalance(env, placement, sizes, overflows, sheetBytes, callGraph, usesBg, usesAudio, usesMusic, usesAtlas, sdkLoad, fixedHeadroom) {
  const bins = { b0: [], b1: [], b2: [], fixed: [] };
  for (const [name, bin] of Object.entries(placement)) bins[bin].push(name);
  const estUsed = (bin) => bins[bin].reduce((a, n) => a + (sizes.get(n) ?? 0), 0);

  // free space estimates per receiving bin. The fixed bank already holds the
  // ~12 KB runtime + stubs, so game functions get a small conservative slice
  // of it; ld65 re-checks every iteration and the ROM-overflow branch bails
  // us out if the estimate was optimistic.
  // Bank 2 also carries SDK RODATA/CODE that must be mapped when read:
  // gt_bg_compose's ~625 B decode body (usesBg), the ~2.7 KB sfx/music
  // sequencer + tables (usesMusic), and ~900 B of exiled cold gt_api bodies
  // (font upload, sheet load, starfield init/move). The 4 KB ACP firmware
  // rides in BANK 0 (B0RODATA) - bank 2 was strangling the heavy audio
  // carts. Reserve so the game-function packer doesn't overfill and fail
  // to converge.
  const B2_SDK_RESERVE =
    (usesBg ? 700 : 0) + (usesAtlas ? 500 : 0) + 2600 + (usesMusic ? 2800 : 0);
  const capacity = sdkLoad
    ? { // measured from the failed link's map: the true immovable load
        b0: BANK_SIZE - BANK_MARGIN - sdkLoad.b0,
        b1: BANK_SIZE - BANK_MARGIN - sdkLoad.b1,
        b2: BANK_SIZE - BANK_MARGIN - sdkLoad.b2,
        fixed: BANK_SIZE - BANK_MARGIN - sdkLoad.fixed,
      }
    : { // first-attempt estimates (no map yet)
        b0: BANK_SIZE - BANK_MARGIN - (usesAudio ? 4400 : 0) - 3400,
        b1: BANK_SIZE - BANK_MARGIN - 1450,
        b2: BANK_SIZE - BANK_MARGIN - sheetBytes - B2_SDK_RESERVE,
        fixed: estUsed("fixed") + 2500,
      };

  const CALLBACKS = new Set(["_update", "_update60", "_draw", "_init"]);
  let moved = false;

  for (const { segment, bytes } of overflows) {
    const bin = SEG_BIN[segment];
    if (!bin) continue;
    let need = bytes + BANK_MARGIN;

    if (bin === "fixed") {
      // Fixed bank too full. Moving a function OUT of fixed isn't free: every
      // cross-bank edge it gains needs a far-call stub, and stubs live in the
      // fixed bank's CODE - the thing we're trying to shrink. (Moving big
      // fns blindly used to ping-pong: -600 bytes of function, +400 bytes of
      // stubs, forever.) So pick by NET gain: size minus the stub bytes the
      // move creates, and pick the target bank where the function's call
      // neighbors already live so few new edges appear.
      const STUB_BYTES = 24;
      const callersOf = (fn) => {
        const cs = [];
        for (const [caller, callees] of callGraph) if (callees.has(fn)) cs.push(caller);
        return cs;
      };
      const stubDelta = (n, target) => {
        let d = 0;
        // callees of n that end up in a DIFFERENT bank (fixed callees are free)
        for (const c of (callGraph.get(n) ?? [])) {
          const cb = placement[c] ?? "fixed";
          if (cb !== "fixed" && cb !== target) d += STUB_BYTES;
        }
        // n itself needs a stub if any banked caller sits outside the target
        if (callersOf(n).some((c) => {
          const cb = placement[c] ?? "fixed";
          return cb !== target;  // fixed callers also far-call into a bank
        })) d += STUB_BYTES;
        return d;
      };
      const candidates = bins.fixed
        .filter((n) => !CALLBACKS.has(n))
        .map((n) => {
          const size = sizes.get(n) ?? 0;
          const target = ["b0", "b1", "b2"]
            .filter((t) => capacity[t] - estUsed(t) >= size)
            .sort((x, y) => stubDelta(n, x) - stubDelta(n, y))[0];
          return target ? { n, size, target, net: size - stubDelta(n, target) } : null;
        })
        .filter(Boolean)
        .sort((a, b) => b.net - a.net);
      let movedHere = false;
      for (const c of candidates) {
        if (need <= 0) break;
        if (c.net <= 0) break;            // only net-positive moves shrink CODE
        placement[c.n] = c.target;
        bins[c.target].push(c.n);
        bins.fixed.splice(bins.fixed.indexOf(c.n), 1);
        need -= c.net;
        moved = true;
        movedHere = true;
      }
      // last resort: the stub estimate is pessimistic (shared stubs, existing
      // edges) - if no net-positive move exists, try the least-bad candidate
      // once and let ld65 be the judge.
      if (!movedHere && candidates.length) {
        const c = candidates[0];
        placement[c.n] = c.target;
        bins[c.target].push(c.n);
        bins.fixed.splice(bins.fixed.indexOf(c.n), 1);
        moved = true;
      }
      continue;
    }

    // banked bin too full: move FEW, LARGE functions. Small helpers are
    // disproportionately likely to be hot leaves (called every loop
    // iteration) and exiling one across a bank turns each call into two
    // bank-register bit-bangs - the first solver draft moved the collision
    // helper to the spill bank and update loops made ~300 stub calls per
    // frame. Big functions (wave spawners, one-shot setups) cover the
    // overflow in one or two moves and are called rarely.
    // EXCEPT for RODATA overflows: string/table data isn't proportional to a
    // function's code size (a tiny print helper can own a fat string pool),
    // so the >=200 code-size filter would leave the actual rodata owners
    // unmovable and the placement stuck. Let rodata overflows move anything.
    const minSize = segment.includes("RODATA") ? 0 : 200;
    if (env.debug) {
      env.warn(`[juggle] ${segment} over ${bytes}; cap b0=${capacity.b0 - estUsed("b0")} b1=${capacity.b1 - estUsed("b1")} b2=${capacity.b2 - estUsed("b2")} fixed=${capacity.fixed - estUsed("fixed")}`);
    }
    // callbacks ARE movable between banks: they're already bank-placed and
    // main() reaches them through stubs - pinning them wedged carts whose
    // update loop IS most of a bank (moving smaller helpers can never cover
    // the overflow). They stay out of `fixed` (no stub back-path needed).
    // coldest-first eviction: reachability alone calls everything "hot"
    // (the update tree transitively reaches death/level-load code), so
    // rank by BFS depth from the frame roots - depth 1 is the per-frame
    // dispatch layer (celeste2's p_update), deep/unreachable is genuinely
    // cold. Evict deepest first, biggest first within a depth.
    const depths = hotDepth(callGraph);
    const movable = bins[bin]
      .filter((n) => (sizes.get(n) ?? 0) >= minSize)
      .sort((a, b) => {
        const da = depths.get(a) ?? 99, db = depths.get(b) ?? 99;
        if (da !== db) return db - da;
        return (sizes.get(b) ?? 0) - (sizes.get(a) ?? 0);
      });
    for (const n of movable) {
      if (need <= 0) break;
      const sz = sizes.get(n) ?? 0;
      // the capacity model picks the roomiest target but never vetoes the
      // move: our size estimates run ~10% light, and a model that vetoes on
      // its own arithmetic wedges the loop repeating the same overflow while
      // ld65 (the ground truth) keeps rejecting the link
      const targets = ["b2", bin === "b0" ? "b1" : "b0", "fixed"]
        .filter((t) => t !== bin && !(t === "fixed" && CALLBACKS.has(n)))
        .sort((x, y) => (capacity[y] - estUsed(y)) - (capacity[x] - estUsed(x)));
      if (!targets.length) continue;
      const target = targets[0];
      // fit-check the roomiest target, but keep scanning smaller candidates
      // rather than giving up: a too-big function is not a reason to wedge.
      // FIXED gets a safety margin: the estimates run light, and unlike the
      // game banks nothing downstream can relieve an overfilled fixed region
      // (cherry repeatedly failed 'RODATA over by ~650' from exactly this -
      // eight functions moved onto a 6KB estimate that was ~10% optimistic)
      const headroom = target === "fixed" ? fixedHeadroom : 0;
      if (capacity[target] - estUsed(target) < sz + headroom) continue;
      if (env.debug) env.warn(`[juggle]   move ${n} (${sz}) ${bin} -> ${target}`);
      placement[n] = target;
      bins[target].push(n);
      bins[bin].splice(bins[bin].indexOf(n), 1);
      need -= sz;
      moved = true;
    }
  }
  return moved;
}

// ---- build ------------------------------------------------------------------

/**
 * Build a gtlua game to a .gtr cart.
 * @param {string} entry path to the game's main.lua
 * @param {{outPath?:string, sheetPath?:string, num8?:boolean, framesPath?:string}} opts
 * @param {BuildEnv} env injected filesystem / toolchain / logging primitives
 */
export async function build(entry, opts, env) {
  const { outPath, sheetPath, num8 = false, framesPath = undefined } = opts;
  const SDK = env.sdk;
  if (!env.exists(entry)) fail(`no such file: ${entry}`);
  const projDir = env.dirname(entry);
  const buildDir = env.join(projDir, "build");
  env.mkdirp(buildDir);
  const name = env.basename(entry, env.extname(entry));
  const gtr = outPath ?? env.join(projDir, `${name}.gtr`);

  const CFLAGS = ["-t", "none", "-Osr", "--cpu", "65c02", "--codesize", "500", "-g",
                  "--static-locals", "-I", SDK];
  // --num8: fixed becomes 8.8-in-an-int everywhere - the game C and every
  // SDK unit must agree on the width, so the define rides the shared CFLAGS
  if (num8) CFLAGS.push("-DGT_NUM8");
  const AFLAGS = ["--cpu", "W65C02", "-g"];   /* -g: symbols reach the ld65 dbgfile */
  if (env.asminc && env.exists(env.asminc)) AFLAGS.push("-I", env.asminc);
  // compile C then run the gtlua peephole pass over cc65's assembly output
  // (tail-call fusion + dead reload elimination - see compiler/peephole.js)
  let phTail = 0, phReload = 0;
  const cc = (src, dst, extra = []) => {
    run(env, "cc65", [...CFLAGS, ...extra, "-o", dst, src]);
    const opt = peephole(env.readText(dst));
    env.writeFile(dst, opt.text);
    phTail += opt.stats.tailCalls;
    phReload += opt.stats.reloads;
  };
  const as = (src, obj, defs = []) => run(env, "ca65", [...AFLAGS, ...defs, "-o", obj, src]);
  const B = (f) => env.join(buildDir, f);

  // In-RAM object memo (retro objects are a few KB - no filesystem cache
  // needed). The FLASH2M placement ladder recompiles heavy SDK units like
  // gt_api.c (~2100 lines) on several attempt-triggers, but usually with the
  // SAME cc65 flags as the prior attempt - producing an identical .o. Memoize
  // the compiled .o bytes keyed on (source path + flags) for THIS build; on a
  // hit, write the remembered bytes to the target and skip cc65+ca65 entirely.
  const objMemo = new Map();       // key -> Uint8Array(.o bytes)
  const memoKey = (src, ccFlags) => `${src}\x1f${ccFlags.join("\x1f")}`;
  // compile C -> .s (peephole) -> assemble -> .o, memoized in RAM by src+flags.
  const ccAsMemo = (src, sdst, obj, extra = []) => {
    const key = memoKey(src, [...CFLAGS, ...extra]);
    const hit = objMemo.get(key);
    if (hit) { env.writeFile(obj, hit); return; }
    cc(src, sdst, extra);
    as(sdst, obj);
    objMemo.set(key, env.readFile(obj));
  };

  // If a winning FLASH2M layout is already cached for this project, we KNOW the
  // cart overflows 32 KB - so skip the flat-32K attempt (compile every unit +
  // link, all of which the banked path redoes) and go straight to banked. This
  // is the single biggest rebuild cost: without it every unit compiles TWICE.
  // The flat main.c compile is kept (section 4 reads its .s for function sizes).
  const flash2mHint = env.exists(env.join(buildDir, ".placement.json"));

  // 1. lua -> C (flat 32 KB attempt first)
  let result = compileLua(env, entry, { num8 });
  const usesAudio = result.c.includes("gt_audio_init(");
  const usesStarfield = result.c.includes("gt_starfield");
  const usesAutocls = result.c.includes("gt_autocls_set(");
  // torus track cache (gt_track_grid/col/row2/view/props/compose): a racing-track
  // scroll engine in gt_bg.c + gt_api.c, gated on GT_TRACK_CACHE.
  const usesTrack = result.c.includes("gt_track_grid(") || result.c.includes("gt_track_col(") ||
    result.c.includes("gt_track_row2(") || result.c.includes("gt_track_view(") ||
    result.c.includes("gt_track_props(") || result.c.includes("gt_track_compose(");
  // The only sheet format is the native 8bpp .gtg (loaded raw into GRAM, no
  // palette expansion). makeSheetC rejects anything else.
  const gtgSheet = !!sheetPath && isGtgSheet(env, sheetPath);
  const apiDefs = [
    ...(gtgSheet ? ["-DGT_GSHEET"] : []),
    ...(usesStarfield ? ["-DGT_STARFIELD"] : []),
    ...(result.c.includes("gt_flakes") || result.c.includes("gt_chain") ? ["-DGT_FLAKES"] : []),
    ...(result.c.includes("gt_canvas_view(") ? ["-DGT_CANVAS"] : []),
    ...(result.c.includes("gt_tiles_draw") ? ["-DGT_TILES"] : []),
    ...(result.c.includes("gt_balls_step") ? ["-DGT_BALLS"] : []),
    ...((result.c.includes("gt_pool_move") || (result.c.includes("gt_cost_decay") || result.c.includes("gt_trail_stamp")) || result.c.includes("gt_pool_anim") || result.c.includes("gt_pool_edraw") || result.c.includes("gt_pool_sprs")) ? ["-DGT_POOLMV"] : []),
    // gt_track_props lives in gt_api.c behind GT_CHUNKS (shares the chunk decode);
    // gt_chunks_draw or gt_track_props both need it.
    ...((result.c.includes("gt_chunks_draw") || result.c.includes("gt_track_props(")) ? ["-DGT_CHUNKS"] : []),
    ...(result.c.includes("gt_hit_scan") ? ["-DGT_HITS"] : []),
    // the torus track-cache (gt_track_grid/col/row2/view/compose in gt_bg.c) is
    // gated on GT_TRACK_CACHE; track_compose additionally needs GT_BG_COMPOSE_ON.
    ...(usesTrack ? ["-DGT_TRACK_CACHE"] : []),
    ...((result.c.includes("gt_bg_compose") || usesTrack) ? ["-DGT_BG_COMPOSE_ON"] : []),
    ...(usesAutocls ? ["-DGT_AUTOCLS"] : []),
  ];
  // sfx()/music() pull in the tracker (gt_music.c). Its data + per-frame
  // sequencer are small and read across arbitrary game banks every frame, so
  // it stays in the always-mapped fixed bank (compiled plain, not -DGT_BANKED).
  const usesMusic = result.c.includes("gt_music_init(");
  // gt_bg (offscreen-GRAM background) is only linked when the game uses it -
  // its compose body rides in bank 2 with the sheet, so linking it into a game
  // that doesn't need it just steals bank-2 space from the game's own code.
  const usesBg = result.c.includes("gt_bg_compose(") || result.c.includes("gt_bg_draw(") ||
    result.c.includes("gt_bg_clear(") || result.c.includes("gt_bg_tile(") ||
    result.c.includes("gt_bg_coln(") || result.c.includes("gt_gspr(") || usesTrack;
  // atlas builders (bg_clear/bg_tile) carry a second bank-2 decode body -
  // only compile + reserve for it when the game actually stamps tiles
  const usesAtlas = result.c.includes("gt_bg_clear(") || result.c.includes("gt_bg_tile(") ||
    result.c.includes("gt_bg_coln(");
  // gt.bg_compose / bg_tile / bg_coln and the track cache (gt.track_*) RE-READ
  // the raw sheet pixels each compose to paint into a GRAM page. With a native
  // .gtg sheet the build also emits the raw 8bpp bytes in ROM (gt_gsheet_ptr)
  // and compiles the 8bpp decode path (GT_GSHEET_COMPOSE).
  const readsRawSheet = result.c.includes("gt_bg_compose(") ||
    result.c.includes("gt_bg_tile(") || result.c.includes("gt_bg_coln(") || usesTrack;
  const gsheetCompose = gtgSheet && readsRawSheet;   // native .gtg + composes
  env.writeFile(B(`${name}.c`), result.c);
  env.writeFile(B("sheet.c"), makeSheetC(env, sheetPath, false, framesPath, gsheetCompose));

  // 2. compile + assemble everything.
  // main.c is always needed (its .s feeds the FLASH2M function-size model).
  cc(B(`${name}.c`), B(`${name}.s`));
  // The SDK .c units here are the NON-banked (flat-32K) builds. When we already
  // know the cart is FLASH2M (a layout is cached), the banked path recompiles
  // all of them with -DGT_BANKED, so these flat compiles are pure waste - skip
  // them. main.c + sheet stay (sheet.o is reused by the banked link).
  if (!flash2mHint) {
    cc(env.sdkFile("gt_api.c"), B("gt_api.s"), apiDefs);
    cc(env.sdkFile("gt_fixed.c"), B("gt_fixed.s"));
    cc(env.sdkFile("gt_math.c"), B("gt_math.s"));
    if (usesBg) cc(env.sdkFile("gt_bg.c"), B("gt_bg.s"), [
      ...(usesAtlas ? ["-DGT_BG_ATLAS"] : []),
      ...((result.c.includes("gt_bg_compose(") || usesTrack) ? ["-DGT_BG_COMPOSE_ON"] : []),
      ...(usesTrack ? ["-DGT_TRACK_CACHE"] : []),
      ...(gsheetCompose ? ["-DGT_GSHEET_COMPOSE"] : []),
    ]);
    if (usesAudio) cc(env.sdkFile("gt_audio.c"), B("gt_audio.s"));
    if (usesMusic) cc(env.sdkFile("gt_music.c"), B("gt_music.s"));
  }
  cc(B("sheet.c"), B("sheet.s"));

  as(env.sdkFile("crt0.s"), B("crt0.o"));
  as(env.sdkFile("vectors.s"), B("vectors.o"));
  as(env.sdkFile("interrupt.s"), B("interrupt.o"));
  as(env.sdkFile("gt_blitq.s"), B("gt_blitq.o"),
     result.c.includes("gt_dbar_z") ? ["-D", "GT_DBAR"] : []);
  as(env.sdkFile(num8 ? "gt_fixed8_asm.s" : "gt_fixed_asm.s"), B("gt_fixed_asm.o"));
  const usesFlakes = result.c.includes("gt_flakes") || result.c.includes("gt_chain");
  const usesCanvas = result.c.includes("gt_canvas_view(");
  if (usesFlakes) as(env.sdkFile("gt_flakes.s"), B("gt_flakes.o"));
  if (usesStarfield) as(env.sdkFile("gt_stars.s"), B("gt_stars.o"));
  if (usesCanvas) as(env.sdkFile("gt_canvas.s"), B("gt_canvas.o"));
  as(env.sdkFile("gt_circ.s"), B("gt_circ.o"));
  as(env.sdkFile("gt_line.s"), B("gt_line.o"));
  const usesTiles = result.c.includes("gt_tiles_draw");
  if (usesTiles) as(env.sdkFile("gt_tiles.s"), B("gt_tiles.o"));
  const usesBalls = result.c.includes("gt_balls_step");
  if (usesBalls) as(env.sdkFile("gt_balls.s"), B("gt_balls.o"), num8 ? ["-D", "GT_NUM8"] : []);
  const usesPoolmv = (result.c.includes("gt_pool_move") || (result.c.includes("gt_cost_decay") || result.c.includes("gt_trail_stamp")) || result.c.includes("gt_pool_anim") || result.c.includes("gt_pool_edraw") || result.c.includes("gt_pool_sprs"));
  if (usesPoolmv) as(env.sdkFile("gt_poolmv.s"), B("gt_poolmv.o"));
  // gt_chunks.s defines the ck_* zp state that gt_chunks_draw AND gt_track_props
  // (both under GT_CHUNKS) use, so assemble it for either.
  const usesChunks = result.c.includes("gt_chunks_draw") || result.c.includes("gt_track_props(");
  if (usesChunks) as(env.sdkFile("gt_chunks.s"), B("gt_chunks.o"));
  const usesHits = result.c.includes("gt_hit_scan");
  if (usesHits) as(env.sdkFile("gt_hits.s"), B("gt_hits.o"));
  as(env.sdkFile("gt_print_asm.s"), B("gt_print_asm.o"));
  // banked tier gets the bank-0 segment build of the glyph run (scarce
  // fixed bank stays clear); the flat 32K tier keeps plain CODE
  as(env.sdkFile("gt_print_asm.s"), B("gt_print_asm_b.o"), ["-D", "GT_BANKED"]);
  // Flat SDK .o (from the non-banked .s above) - skipped when FLASH2M-hinted,
  // same as their compiles; the banked path builds its own.
  if (!flash2mHint) {
    as(B("gt_api.s"), B("gt_api.o"));
    as(B("gt_fixed.s"), B("gt_fixed.o"));
    as(B("gt_math.s"), B("gt_math.o"));
    if (usesBg) as(B("gt_bg.s"), B("gt_bg.o"));
    if (usesAudio) as(B("gt_audio.s"), B("gt_audio.o"));
    if (usesMusic) as(B("gt_music.s"), B("gt_music.o"));
  }
  as(B("sheet.s"), B("sheet.o"));
  as(B(`${name}.s`), B(`${name}.o`));

  const baseObjs = [
    B("crt0.o"), B("vectors.o"), B("interrupt.o"), B("gt_blitq.o"),
    B("gt_api.o"), B("gt_fixed.o"), B("gt_fixed_asm.o"), B("gt_math.o"),
    ...(usesBg ? [B("gt_bg.o")] : []),
    ...(usesAudio ? [B("gt_audio.o")] : []),
    ...(usesMusic ? [B("gt_music.o")] : []),
    ...(usesFlakes ? [B("gt_flakes.o")] : []),
    ...(usesStarfield ? [B("gt_stars.o")] : []),
    ...(usesCanvas ? [B("gt_canvas.o")] : []),
    B("gt_circ.o"),
    B("gt_line.o"),
    ...(usesTiles ? [B("gt_tiles.o")] : []),
    ...(usesBalls ? [B("gt_balls.o")] : []),
    ...(usesPoolmv ? [B("gt_poolmv.o")] : []),
    ...(usesChunks ? [B("gt_chunks.o")] : []),
    ...(usesHits ? [B("gt_hits.o")] : []),
    B("gt_print_asm.o"),
    B("sheet.o"),
  ];

  // 3. link: flat 32 KB. Skipped when FLASH2M-hinted (we know it overflows and
  // the flat SDK .o don't even exist) - jump straight to the banked build.
  const link32 = flash2mHint
    ? { ok: false, overflows: [], text: "" }
    : runLink(env, "ld65", [
      "-C", env.sdkFile("gametank.cfg"),
      "-o", gtr,
      "-m", B(`${name}.map`),
      "-Ln", B(`${name}.lbl`), "--dbgfile", B(`${name}.dbg`),
      ...baseObjs, B(`${name}.o`),
      env.lib,
    ]);
  if (link32.ok) {
    env.log(`${gtr} (${env.size(gtr)} bytes, EEPROM32K)`);
    return;
  }

  // 4. overflow -> FLASH2M banked build
  const over = link32.overflows.reduce((a, o) => a + o.bytes, 0);
  env.warn(`32 KB cart overflows by ~${over} bytes - re-targeting the 2 MB FLASH2M cart`);
  let sizes = functionSizes(env, B(`${name}.s`));
  // fold each function's rodata (string literals + literal-run tables) into
  // its size: rodata rides the function's bank (the emitter pushes
  // rodata-name with code-name), so the packer must see the full footprint.
  const foldRodataSizes = (cSource, map) => {
    let cur = null;
    for (const ln of cSource.split("\n")) {
      const m = ln.match(/^[\w ]*\bgtl_(\w+)\([^;]*\)$/);
      if (m && !ln.includes(";")) { cur = m[1]; continue; }
      if (!cur) continue;
      for (const str of ln.matchAll(/"((?:[^"\\]|\\.)*)"/g)) {
        map.set(cur, (map.get(cur) ?? 0) + str[1].length + 1);
      }
      const lit = ln.match(/static const (int|long) gtl__lit\d+\[(\d+)\]/);
      if (lit) {
        map.set(cur, (map.get(cur) ?? 0) + (lit[1] === "long" ? 4 : 2) * parseInt(lit[2], 10));
      }
    }
  };
  foldRodataSizes(result.c, sizes);
  const sheetBytes = sheetPath ? gtgSheetRomBytes(env, sheetPath, gsheetCompose) : 0;
  const placement = initialPlacement(result.callGraph);

  as(env.sdkFile("gt_bank.s"), B("gt_bank.o"));
  env.writeFile(B("sheet.c"), makeSheetC(env, sheetPath, true, framesPath, gsheetCompose));
  cc(B("sheet.c"), B("sheet.s"));
  as(B("sheet.s"), B("sheet.o"));

  // The flat build placed the whole cold gt_math unit (gt_fsin/gt_fcos/
  // gt_fatan2/rnd/srand/time + the 1 KB sine table) in the always-mapped
  // FIXED bank. The quarter-square multiply tables now fill that bank, so
  // recompile gt_math banked: -DGT_BANKED routes its CODE/RODATA into bank 1
  // (B1CODE/B1RODATA) and renames the impls with an _impl suffix. Its DATA/BSS
  // stay in RAM. The fixed-bank far-call stubs in gt_math_stubs.o own the plain
  // public names and bridge every caller (game code + fixed-bank SDK code) to
  // the bank-1 impls. Reclaims ~2.2 KB of fixed-bank space.
  run(env, "cc65", [...CFLAGS, "-DGT_BANKED", "-o", B("gt_math.s"),
                env.sdkFile("gt_math.c")]);
  as(B("gt_math.s"), B("gt_math.o"));
  as(env.sdkFile("gt_math_stubs.s"), B("gt_math_stubs.o"));

  // gt_bg_compose reads the sheet (which rides in bank 2 for FLASH2M) to paint
  // the background page - recompile it banked: the decode body goes to B2CODE
  // (bank 2, with the sheet) and a fixed-bank stub maps bank 2 before calling it.
  if (usesBg) {
    run(env, "cc65", [...CFLAGS, "-DGT_BANKED", "-DGT_SHEET_BANK=2",
                  ...(usesAtlas ? ["-DGT_BG_ATLAS"] : []),
                  ...((result.c.includes("gt_bg_compose(") || usesTrack) ? ["-DGT_BG_COMPOSE_ON"] : []),
                  ...(usesTrack ? ["-DGT_TRACK_CACHE"] : []),
                  ...(gsheetCompose ? ["-DGT_GSHEET_COMPOSE"] : []),
                  "-o", B("gt_bg.s"), env.sdkFile("gt_bg.c")]);
    as(B("gt_bg.s"), B("gt_bg.o"));
  }

  // The flat-attempt gt_audio.o placed the 4 KB ACP firmware blob in the
  // fixed bank's RODATA - the single biggest reason banked games had to
  // ship silent. Recompile it banked: the blob rides in bank 2 (with the
  // sheet) and gt_audio_init() maps that bank in before the ARAM upload.
  if (usesAudio) {
    run(env, "cc65", [...CFLAGS, "-DGT_BANKED",
                  "-o", B("gt_audio.s"), env.sdkFile("gt_audio.c")]);
    as(B("gt_audio.s"), B("gt_audio.o"));
  }

  // gt_api carries ~2 KB of cold bodies (font upload, sheet load, circfill/
  // circ/line-diagonal, starfield init/move, the glyph table) that exile to
  // bank 2 under GT_BANKED - the fixed window can't hold them all plus the
  // blitter font. Recompile banked so those pragmas take effect.
  ccAsMemo(env.sdkFile("gt_api.c"), B("gt_api.s"), B("gt_api.o"), ["-DGT_BANKED", ...apiDefs]);
  run(env, "cc65", [...CFLAGS, "-DGT_BANKED",
                "-o", B("gt_fixed.s"), env.sdkFile("gt_fixed.c")]);
  as(B("gt_fixed.s"), B("gt_fixed.o"));

  // gt_music (sfx/music sequencer + its instrument/sfx/song tables) is another
  // fat unit that would blow the near-full fixed bank's RODATA/CODE. Recompile
  // it banked: the impls + tables ride in bank 2 (B2CODE/B2RODATA, renamed
  // _impl) and the fixed-bank stubs in gt_music_stubs.o bridge every call
  // (game code AND gt_endframe's frame hook) with a bank-2 switch.
  // a cart that registers converted PICO-8 banks never uses the built-in
  // sfx/song tables - compile the zero-authoring layer out (~700 bytes)
  const noBuiltinSfx = result.c.includes("gt_sfx_bank(") ? ["-DGT_NO_BUILTIN_SFX"] : [];
  if (usesMusic) {
    run(env, "cc65", [...CFLAGS, "-DGT_BANKED", ...noBuiltinSfx,
                  "-o", B("gt_music.s"), env.sdkFile("gt_music.c")]);
    as(B("gt_music.s"), B("gt_music.o"));
    as(env.sdkFile("gt_music_stubs.s"), B("gt_music_stubs.o"));
  }

  let linked = null;
  let lastOverflows = [];
  // In-RAM memos for the placement ladder: the game unit + stubs are recompiled
  // on every attempt, but many attempts regenerate byte-identical C (a placement
  // move that doesn't change any cross-bank call boundary). Key the .o on the
  // generated source bytes so a repeat is a Map lookup, not a ~230ms recompile.
  const gameObjMemo = new Map();
  const stubObjMemo = new Map();
  // Ladder cycle-skip: the size-relief escalation rungs (integer-rnd off, inline
  // off, ...) are hardcoded to fire at fixed attempt numbers. Between rungs the
  // juggle/rebalance can only reproduce placements it already tried (nothing
  // shrinks the code until the next rung), so it spins - re-linking the SAME
  // failing placement up to a dozen times waiting for the attempt counter to
  // reach the next rung. When a link fails on a placement whose generated C we
  // have ALREADY seen, jump straight to the next rung instead of spinning. This
  // only skips provably-redundant iterations; the rungs that fire, the distinct
  // placements tried, and the final cart are all unchanged.
  const RUNGS = [8, 10, 14, 18, 20, 26, 32];
  const seenPlacements = new Set();
  let lastCKey = null;
  // The min/max/mid ternary inlining is a speed-for-size trade. A game at the
  // bank-capacity cliff can fail to place WITH it but link fine WITHOUT it -
  // so if placement is still failing halfway through the attempts, fall back
  // to the compact call form and start placement over.
  let midInline = true;
  let fnInline = true;
  // fixed-bank packing margin for the placement mover (rebalance); build()
  // rebinds it across the ladder rungs and passes it into rebalance.
  let fixedHeadroom = 768;
  let workPlacement = placement;
  let rndInt = true;

  // Placement replay: the winning bank layout is STABLE across ordinary code
  // edits (a 1-line change moves 0 functions between banks - measured), but the
  // ladder re-searches it from scratch every build (~6-9 game-unit recompiles).
  // So persist the last winning layout and, on the NEXT build, TRY IT FIRST: the
  // game unit still recompiles (the code changed - that's correct), but against
  // the known-good placement, so it links in ONE pass. Only when the layout no
  // longer fits (a big structural change) do we fall back to the full search.
  // NOT keyed on source - it's "the last placement that worked here", not a
  // memo of a specific build; validated by actually linking, so never a
  // correctness risk. Lives in build/.placement.json (per project).
  const replayPath = env.join(buildDir, ".placement.json");
  let replay = null;
  if (env.exists(replayPath)) {
    try {
      const r = JSON.parse(env.readText(replayPath));
      // Replay only if the saved layout still describes THIS game: every placed
      // function must still exist, and every currently-placeable function must be
      // covered (a new/removed function means the layout is stale -> full search).
      // callGraph includes fixed callbacks that aren't in the placement map, so
      // compare against the set of functions initialPlacement actually assigns.
      const placeable = new Set(Object.keys(initialPlacement(result.callGraph)));
      const saved = new Set(Object.keys(r.placement ?? {}));
      if (r.placement && saved.size === placeable.size &&
          [...placeable].every((k) => saved.has(k))) {
        replay = r;
      }
    } catch { /* corrupt - ignore */ }
  }
  const saveReplay = () => {
    try {
      env.writeFile(replayPath, JSON.stringify({
        placement: workPlacement, midInline, fnInline, rndInt, fixedHeadroom, apiDefs,
      }));
    } catch { /* best effort */ }
  };

  // Fast path: replay the saved layout in ONE pass. If it links, we're done -
  // skip the entire search AND the hot-edge repair (the saved layout is already
  // repaired). If it doesn't link, discard it and fall into the normal ladder.
  if (replay) {
    midInline = replay.midInline; fnInline = replay.fnInline; rndInt = replay.rndInt;
    fixedHeadroom = replay.fixedHeadroom;
    apiDefs.length = 0; apiDefs.push(...replay.apiDefs);
    ccAsMemo(env.sdkFile("gt_api.c"), B("gt_api.s"), B("gt_api.o"), ["-DGT_BANKED", ...apiDefs]);
    workPlacement = { ...replay.placement };
  }

  for (let attempt = 0; attempt < 48; attempt++) {
    // size-relief ladder: 0-7 everything on -> 8-15 function inlining off
    // (mid ternaries STAY: they're smaller than the cdecl mid() call) ->
    // 16-23 everything off. Each rung restarts from a fresh placement.
    // Bank-moving rungs are overflow-aware: they read which bins the last
    // failed link actually overflowed and never move load INTO one.
    const overBins = new Set(lastOverflows.map((o) => SEG_BIN[o.segment]));
    if (attempt === 10 && apiDefs.includes("-DGT_INPUT_B2") && overBins.has("b2")) {
      // the b2 relief move backfired (this cart's bank 2 is the tight one):
      // undo it and let the cold bodies go back to bank 0
      apiDefs.splice(apiDefs.indexOf("-DGT_INPUT_B2"), 1);
      ccAsMemo(env.sdkFile("gt_api.c"), B("gt_api.s"), B("gt_api.o"), ["-DGT_BANKED", ...apiDefs]);
      workPlacement = initialPlacement(result.callGraph);
      env.warn("bank placement tight: b2 relief undone (bank 2 is the tight bank)");
    }
    if (attempt === 18 && fixedHeadroom) {
      // the conservative fixed-move margin protects most carts from
      // overfilling the fixed region on light estimates, but some placements
      // genuinely need to pack fixed to the byte - drop it before the more
      // destructive rungs
      fixedHeadroom = 0;
      workPlacement = initialPlacement(result.callGraph);
      env.warn("bank placement tight: fixed-bank packing margin dropped");
    }
    if (attempt === 20 && fnInline) {
      fnInline = false;
      workPlacement = initialPlacement(result.callGraph);
      env.warn("bank placement tight: retrying with function inlining off");
    }
    // (the old attempt-4 firmware-relocation rung is gone: the whole audio
    // unit owns private bank 3 now, out of the placement fight entirely)
    if (attempt === 8 && !apiDefs.includes("-DGT_INPUT_B2") &&
        (overBins.has("b0") || overBins.has("fixed")) && !overBins.has("b2")) {
      // which bank the SDK input block fits in is per-cart: b0-heavy carts
      // (big update loop + audio firmware) need it in bank 2 and vice versa
      apiDefs.push("-DGT_INPUT_B2");
      ccAsMemo(env.sdkFile("gt_api.c"), B("gt_api.s"), B("gt_api.o"), ["-DGT_BANKED", ...apiDefs]);
      workPlacement = initialPlacement(result.callGraph);
      env.warn("bank placement tight: input block to bank 2");
    }
    if (attempt === 14 && rndInt) {
      // size relief: the integer-rnd fast path costs ~90 fixed bytes of
      // trampoline + call-site changes; carts at the absolute capacity
      // cliff give it up before giving up the blit font
      rndInt = false;
      workPlacement = initialPlacement(result.callGraph);
      env.warn("bank placement tight: integer-rnd fast path off");
    }
    if (attempt === 32 && !apiDefs.includes("-DGT_NO_BLITFONT")) {
      // LAST-resort size relief: drop the GRAM blit font (~1 KB across
      // banks); print falls back to the per-pixel CPU path. This rung is
      // CATASTROPHIC for text-heavy carts - celeste2 measured 7 vsyncs a
      // frame (8.5 fps) with ~198k cycles of per-pixel glyphs - so every
      // cheaper rung (including turning inlining off) goes first.
      apiDefs.push("-DGT_NO_BLITFONT");
      ccAsMemo(env.sdkFile("gt_api.c"), B("gt_api.s"), B("gt_api.o"), ["-DGT_BANKED", ...apiDefs]);
      workPlacement = initialPlacement(result.callGraph);
      env.warn("bank placement tight: dropping the blit font (CPU print fallback)");
    }
    if (attempt === 26 && midInline) {
      midInline = false;
      workPlacement = initialPlacement(result.callGraph);
      env.warn("bank placement tight: retrying with all inlining off");
    }
    const compileAndLink = (placementNow) => {
      result = compileLua(env, entry, { banked: true, placement: placementNow, midInline, inliner: fnInline, num8, rndInt });
      env.writeFile(B(`${name}.c`), result.c);
      // Memoize the game-unit .o by the GENERATED C bytes. The placement ladder
      // recompiles main.c on every attempt, but many placement changes produce
      // IDENTICAL C (they only move a function whose calls already stayed within
      // a bank), so the ~230ms cc65 recompile is pure waste. Identical C -> the
      // same .o, so key the in-RAM memo on a hash of result.c. (RAM only; the
      // game .o is a few KB.) Same for the tiny stubs.s -> stubs.o.
      const cKey = env.hash(result.c);
      lastCKey = cKey;
      const cHit = gameObjMemo.get(cKey);
      if (cHit) {
        env.writeFile(B(`${name}.o`), cHit);
      } else {
        cc(B(`${name}.c`), B(`${name}.s`));
        as(B(`${name}.s`), B(`${name}.o`));
        gameObjMemo.set(cKey, env.readFile(B(`${name}.o`)));
      }
      const stubsSrc = (result.stubs ?? "; no cross-bank calls\n") + "\n";
      env.writeFile(B("stubs.s"), stubsSrc);
      const sKey = env.hash(stubsSrc);
      const sHit = stubObjMemo.get(sKey);
      if (sHit) env.writeFile(B("stubs.o"), sHit);
      else { as(B("stubs.s"), B("stubs.o")); stubObjMemo.set(sKey, env.readFile(B("stubs.o"))); }
      return runLink(env, "ld65", [
        "-C", env.sdkFile("gametank_flash2m.cfg"),
        "-o", B(`${name}.banks`),
        "-m", B(`${name}.map`),
        "-Ln", B(`${name}.lbl`), "--dbgfile", B(`${name}.dbg`),
        ...baseObjs.map((o) => o.endsWith("gt_print_asm.o") ? B("gt_print_asm_b.o") : o),
      B("gt_bank.o"), B("gt_math_stubs.o"),
        ...(usesMusic ? [B("gt_music_stubs.o")] : []),
        B("stubs.o"),
        B(`${name}.o`),
        env.lib,
      ]);
    };
    const link = compileAndLink(workPlacement);
    // re-measure per attempt: the .s parsed before the loop can be stale
    // (previous run's build dir) and the inlining rungs change which
    // functions even exist - a stale map makes the mover shuffle size-0
    // ghosts while the real hogs stay put
    sizes = functionSizes(env, B(`${name}.s`));
    foldRodataSizes(result.c, sizes);

    if (link.ok) {
      linked = B(`${name}.banks`);
      // Replay fast path: the saved layout linked on the first pass. It's ALREADY
      // hot-edge-repaired (we saved the post-repair layout), so re-running repair
      // would just re-derive it (or diverge). Accept it as-is and finish.
      if (replay && attempt === 0) { break; }
      // ---- hot-edge repair: the packer found A layout; now heal the worst
      // per-frame cross-bank edges (each costs a ~100-cycle stub every call,
      // every frame). Move the callee into the caller's bank; keep every
      // change that still links and lowers the score, revert the rest.
      const hot = hotSet(result.callGraph);
      const pinned = new Set(["_update", "_update60", "_draw", "_init"]);
      let bestScore = layoutScore(workPlacement, result.callGraph, hot);
      if (bestScore >= 10) {
        const attempted = new Set();
        let dirty = false;
        for (let round = 0; round < 40; round++) {
          const edges = stubbedEdges(workPlacement, result.callGraph, hot, hotDepth(result.callGraph))
            .filter((e) => e.w >= 10 && !attempted.has(`${e.caller}>${e.callee}`));
          if (!edges.length) break;
          const e = edges[0];
          attempted.add(`${e.caller}>${e.callee}`);
          if (env.debug) env.warn(`[repair] trying edge ${e.caller}(${workPlacement[e.caller] ?? "fixed"}) -> ${e.callee}(${workPlacement[e.callee] ?? "fixed"}) w=${e.w}`);
          // a shared callee can't chase one caller's bank without stubbing
          // its other callers - score BOTH directions, take the better
          const options = [];
          if (!pinned.has(e.callee)) options.push([e.callee, workPlacement[e.caller] ?? "fixed"]);
          if (!pinned.has(e.caller) && (workPlacement[e.callee] ?? "fixed") !== "fixed") {
            options.push([e.caller, workPlacement[e.callee]]);
          }
          let best = null;
          for (const [fn, target] of options) {
            const prev = workPlacement[fn] ?? "fixed";
            workPlacement[fn] = target;
            const cand = layoutScore(workPlacement, result.callGraph, hot);
            workPlacement[fn] = prev;
            if (cand < bestScore && (!best || cand < best.cand)) best = { fn, target, prev, cand };
          }
          if (!best) continue;
          workPlacement[best.fn] = best.target;
          let relink = compileAndLink(workPlacement);
          if (!relink.ok) {
            // make room: the target bank is full - evict its biggest COLD
            // resident to the roomiest other bank and retry once. (The
            // repair otherwise can't heal a hot edge whose callee is
            // squeezed out by cold code, e.g. celeste2's p_update stuck
            // across a bank from the movement core it calls ~40x/frame.)
            // deepest-coldest first; rotate destinations so a full first
            // choice doesn't wedge the whole eviction (RODATA overflows in
            // particular follow the FN, so moving anything with a string
            // pool relieves them - code size alone was blind to that)
            const depthsE = hotDepth(result.callGraph);
            const cold = Object.entries(workPlacement)
              .filter(([fn, b]) => b === best.target && !pinned.has(fn) && fn !== best.fn)
              .map(([fn]) => fn)
              .sort((a, b2) => {
                const da = depthsE.get(a) ?? 99, db = depthsE.get(b2) ?? 99;
                if (da !== db) return db - da;
                return (sizes.get(b2) ?? 0) - (sizes.get(a) ?? 0);
              });
            const dests = ["b2", "b1", "b0", "fixed"].filter((d) => d !== best.target);
            const evicted = [];
            for (let e = 0; e < Math.min(6, cold.length); e++) {
              const evictee = cold[e];
              const evPrev = workPlacement[evictee];
              workPlacement[evictee] = dests[e % dests.length];
              evicted.push([evictee, evPrev]);
              relink = compileAndLink(workPlacement);
              if (relink.ok) {
                if (env.debug) env.warn(`[repair]   evicted ${evicted.map(([f]) => f).join(", ")} from ${best.target}`);
                break;
              }
            }
            if (!relink.ok) for (const [fn, b] of evicted.reverse()) workPlacement[fn] = b;
          }
          if (relink.ok) {
            bestScore = layoutScore(workPlacement, result.callGraph, hot);
            dirty = false;
            if (env.debug) env.warn(`[repair] ${best.fn} -> ${best.target} (score ${bestScore})`);
          } else {
            if (env.debug) env.warn(`[repair]   FAILED ${best.fn} -> ${best.target}: ${relink.overflows?.map((o) => `${o.segment}+${o.bytes}`).join(",") ?? "?"}`);
            workPlacement[best.fn] = best.prev;
            dirty = true;
          }
        }
        // artifacts on disk must match the accepted placement
        if (dirty) compileAndLink(workPlacement);
      }
      saveReplay();   // remember this winning (post-repair) layout for next build
      break;
    }
    // Replay miss: the saved layout no longer links (a big enough code change).
    // Discard it and restart the search from a fresh placement, exactly as a
    // no-replay build would - so a stale layout only ever costs one extra pass.
    if (replay && attempt === 0) {
      replay = null;
      midInline = true; fnInline = true; rndInt = true; fixedHeadroom = 768;
      workPlacement = initialPlacement(result.callGraph);
      ccAsMemo(env.sdkFile("gt_api.c"), B("gt_api.s"), B("gt_api.o"), ["-DGT_BANKED", ...apiDefs]);
      attempt = -1;   // loop ++ -> restart at attempt 0 with the fresh layout
      continue;
    }
    lastOverflows = link.overflows;
    // Cycle-skip: this placement's C was already tried and still failed. The
    // rungs before the next boundary can't change the outcome, so fast-forward
    // the attempt counter to the next rung (which shrinks code / restarts
    // placement) instead of re-deriving the same dead end every iteration.
    if (seenPlacements.has(lastCKey)) {
      const nextRung = RUNGS.find((r) => r > attempt);
      if (nextRung !== undefined) { attempt = nextRung - 1; continue; }  // -1: loop's ++ lands on the rung
    }
    seenPlacements.add(lastCKey);
    const mapInfo = sdkLoadFromMap(env, B(`${name}.map`));
    if (mapInfo) calibrateSizes(sizes, workPlacement, mapInfo.port);
    const moved = rebalance(env, workPlacement, sizes, link.overflows, sheetBytes, result.callGraph, usesBg, usesAudio, usesMusic, usesAtlas, mapInfo?.load ?? null, fixedHeadroom);
    if (!moved && attempt >= 40) {
      fail("FLASH2M bank placement failed: " +
        link.overflows.map((o) => `${o.segment} over by ${o.bytes}`).join(", "));
    }
  }
  if (!linked) fail("FLASH2M bank placement did not converge; last overflows: " +
    lastOverflows.map((o) => `${o.segment} over by ${o.bytes}`).join(", "));

  // 5. lay the four 16 KB pieces into the 2 MB flash image:
  //    bank n at n*0x4000, the fixed bank last (offset 0x1FC000)
  const pieces = env.readFile(linked);
  if (pieces.length !== 5 * BANK_SIZE) {
    fail(`unexpected banked link output size ${pieces.length}`);
  }
  // Uint8Array (not Buffer) so build.js stays free of node globals - the
  // browser env has no Buffer. Same bytes: a 0xff-filled 2 MB flash image.
  const img = new Uint8Array(FLASH_SIZE).fill(0xff);
  img.set(pieces.subarray(0 * BANK_SIZE, 1 * BANK_SIZE), 0x000000);
  img.set(pieces.subarray(1 * BANK_SIZE, 2 * BANK_SIZE), 0x004000);
  img.set(pieces.subarray(2 * BANK_SIZE, 3 * BANK_SIZE), 0x008000);
  img.set(pieces.subarray(3 * BANK_SIZE, 4 * BANK_SIZE), 0x00C000);
  img.set(pieces.subarray(4 * BANK_SIZE, 5 * BANK_SIZE), FLASH_SIZE - BANK_SIZE);
  env.writeFile(gtr, img);

  // save the placement the successful link ACTUALLY used - the ladder rungs
  // rebind workPlacement, and saving the original seed object poisoned the
  // next build's starting point with a stale layout
  env.writeFile(B("banks.json"), JSON.stringify(workPlacement, null, 1));
  const counts = { fixed: 0, b0: 0, b1: 0, b2: 0 };
  for (const b of Object.values(workPlacement)) counts[b]++;
  env.log(`${gtr} (${env.size(gtr)} bytes, FLASH2M; ` +
    `functions fixed:${counts.fixed} bank0:${counts.b0} bank1:${counts.b1} bank2:${counts.b2})`);
}
