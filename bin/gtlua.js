#!/usr/bin/env node
// gtlua CLI — compile a .lua game to a GameTank .gtr cartridge.
//
//   gtlua build <main.lua> [--sheet gfx.bin] [-o game.gtr]
//   gtlua c <main.lua>                     print the generated C (debugging)
//
// Cart tiers: the build first targets a flat 32 KB EEPROM cart. If the game
// overflows it, the build automatically re-targets the 2 MB FLASH2M cart:
// game functions are partitioned across three 16 KB banks (update path /
// draw+init path / spill+sheet) by call-graph reachability, cross-bank calls
// are routed through generated far-call stubs in the fixed bank, and the
// final image is a 2 MB flash layout the emulator size-detects.
//
// Toolchain resolution (first hit wins):
//   $GTLUA_CC65_HOME/bin, <sdk repo>/tools/cc65/bin, then PATH.
// Build cc65 into tools/ with: scripts/install_tools.sh

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { compile, formatDiagnostics } from "../compiler/index.js";
import { peephole } from "../compiler/peephole.js";

const REPO = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const SDK = path.join(REPO, "sdk");

const BANK_SIZE = 0x4000;
const FLASH_SIZE = 0x200000;
const BANK_MARGIN = 256;          // safety slack per bank (size estimates)

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

function findToolchain() {
  const candidates = [];
  if (process.env.GTLUA_CC65_HOME) candidates.push(process.env.GTLUA_CC65_HOME);
  candidates.push(path.join(REPO, "tools", "cc65"));
  for (const home of candidates) {
    if (existsSync(path.join(home, "bin", "cc65"))) {
      return {
        cc65: path.join(home, "bin", "cc65"),
        ca65: path.join(home, "bin", "ca65"),
        ld65: path.join(home, "bin", "ld65"),
        lib: path.join(home, "lib", "none.lib"),
        asminc: path.join(home, "asminc"),
      };
    }
  }
  // fall back to PATH (cc65 --print-target-path locates lib/asminc)
  const probe = spawnSync("cc65", ["--version"], { encoding: "utf8" });
  if (probe.status === 0 || probe.status === 1) {
    const tp = spawnSync("cc65", ["--print-target-path"], { encoding: "utf8" });
    const targetPath = (tp.stdout || "").trim();
    const share = targetPath ? path.dirname(targetPath) : null;
    return {
      cc65: "cc65", ca65: "ca65", ld65: "ld65",
      lib: share ? path.join(share, "lib", "none.lib") : "none.lib",
      asminc: share ? path.join(share, "asminc") : null,
    };
  }
  fail(
    "cc65 not found. Install it with scripts/install_tools.sh (builds into tools/cc65)\n" +
    "or put cc65/ca65/ld65 on your PATH."
  );
}

function run(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: "utf8" });
  if (r.error) fail(`${cmd}: ${r.error.message}`);
  if (r.status !== 0) {
    if (r.stdout) process.stderr.write(r.stdout);
    if (r.stderr) process.stderr.write(r.stderr);
    fail(`${path.basename(cmd)} failed (exit ${r.status})`);
  }
  if (r.stderr) process.stderr.write(r.stderr); // warnings
  return r;
}

// like run() but overflow-tolerant: returns {ok, overflows:[{segment,bytes}]}
function runLink(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: "utf8" });
  if (r.error) fail(`${cmd}: ${r.error.message}`);
  const text = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  if (r.status === 0) return { ok: true, overflows: [], text };
  const overflows = [];
  // NB: ld65 says "by 1 byte" (singular) — a 1-byte overflow with a plural-
  // only pattern is invisible to the juggler and hard-fails the build
  const re = /Segment '?‘?([A-Z0-9]+)'?’? overflows memory area '?‘?\w+'?’? by (\d+) bytes?/g;
  let m;
  while ((m = re.exec(text)) !== null) overflows.push({ segment: m[1], bytes: Number(m[2]) });
  if (!overflows.length) {
    process.stderr.write(text);
    fail(`${path.basename(cmd)} failed (exit ${r.status})`);
  }
  return { ok: false, overflows, text };
}

// Sum every non-game module's bytes per bank from an ld65 map (SDK objects,
// the embedded sheet, cross-bank stubs). This is the REAL immovable load —
// the capacity model uses it instead of hand-tuned constants, which went
// stale every time an SDK body moved banks.
const MAP_SEG_BIN = {
  B0CODE: "b0", B0RODATA: "b0", B1CODE: "b1", B1RODATA: "b1",
  B2CODE: "b2", B2RODATA: "b2", SHEET: "b2",
  CODE: "fixed", RODATA: "fixed", DATA: "fixed",
};
function sdkLoadFromMap(mapPath) {
  let txt;
  try { txt = readFileSync(mapPath, "utf8"); } catch { return null; }
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
// ld65 measured — the ~2 bytes/line heuristic runs ~10% off, which is the
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

function compileLua(entry, opts = {}) {
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

// parse per-function code-size estimates out of a cc65-generated .s file
function functionSizes(sPath) {
  const sizes = new Map();
  let name = null, count = 0;
  for (const ln of readFileSync(sPath, "utf8").split("\n")) {
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

function makeSheetC(sheetPath, banked, packed) {
  if (!sheetPath) return `void gt_sheet_init(void) {}\n`;
  const raw = readFileSync(sheetPath);
  if (raw.length !== 8192) fail(`--sheet expects an 8192-byte 4bpp gfx.bin (got ${raw.length})`);
  let decl, call;
  if (packed) {
    const pk = packbits(Array.from(raw));
    decl = `static const unsigned char sheet_data[${pk.length}] = {${pk.join(",")}};\n`;
    call = `gt_sheet_load_packed(sheet_data, ${pk.length}U)`;
  } else {
    decl = `static const unsigned char sheet_data[8192] = {${Array.from(raw).join(",")}};\n`;
    call = `gt_sheet_load(sheet_data)`;
  }
  if (banked) {
    // sheet data lives in bank 2; the loader (fixed bank) maps it in first
    return `#include "gt_api.h"\n` +
      `#pragma rodata-name ("SHEET")\n` + decl +
      `#pragma rodata-name ("RODATA")\n` +
      `void gt_sheet_init(void) { gt_bank(2); ${call}; }\n`;
  }
  return `#include "gt_api.h"\n` + decl +
    `void gt_sheet_init(void) { ${call}; }\n`;
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
function layoutScore(placement, callGraph, hot) {
  let score = 0;
  for (const [caller, callees] of callGraph) {
    const cb = placement[caller] ?? "fixed";
    for (const cee of callees) {
      const eb = placement[cee] ?? "fixed";
      if (eb !== "fixed" && eb !== cb) score += hot.has(caller) ? 10 : 1;
    }
  }
  return score;
}
// the stubbed edges of a layout, worst (hot) first — repair candidates
function stubbedEdges(placement, callGraph, hot) {
  const edges = [];
  for (const [caller, callees] of callGraph) {
    const cb = placement[caller] ?? "fixed";
    for (const cee of callees) {
      const eb = placement[cee] ?? "fixed";
      if (eb !== "fixed" && eb !== cb) {
        edges.push({ caller, callee: cee, w: hot.has(caller) ? 10 : 1 });
      }
    }
  }
  edges.sort((a, b) => b.w - a.w);
  return edges;
}

// rebalance after a link overflow: move functions out of the fat bins
function rebalance(placement, sizes, overflows, sheetBytes, callGraph, usesBg, usesAudio, usesMusic, usesAtlas, sdkLoad) {
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
  // rides in BANK 0 (B0RODATA) — bank 2 was strangling the heavy audio
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
      // fixed bank's CODE — the thing we're trying to shrink. (Moving big
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
      // edges) — if no net-positive move exists, try the least-bad candidate
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
    // bank-register bit-bangs — the first solver draft moved the collision
    // helper to the spill bank and update loops made ~300 stub calls per
    // frame. Big functions (wave spawners, one-shot setups) cover the
    // overflow in one or two moves and are called rarely.
    // EXCEPT for RODATA overflows: string/table data isn't proportional to a
    // function's code size (a tiny print helper can own a fat string pool),
    // so the >=200 code-size filter would leave the actual rodata owners
    // unmovable and the placement stuck. Let rodata overflows move anything.
    const minSize = segment.includes("RODATA") ? 0 : 200;
    if (process.env.GTLUA_DEBUG) {
      console.error(`[juggle] ${segment} over ${bytes}; cap b0=${capacity.b0 - estUsed("b0")} b1=${capacity.b1 - estUsed("b1")} b2=${capacity.b2 - estUsed("b2")} fixed=${capacity.fixed - estUsed("fixed")}`);
    }
    // callbacks ARE movable between banks: they're already bank-placed and
    // main() reaches them through stubs — pinning them wedged carts whose
    // update loop IS most of a bank (moving smaller helpers can never cover
    // the overflow). They stay out of `fixed` (no stub back-path needed).
    const movable = bins[bin]
      .filter((n) => (sizes.get(n) ?? 0) >= minSize)
      .sort((a, b) => (sizes.get(b) ?? 0) - (sizes.get(a) ?? 0));
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
      // rather than giving up: a too-big function is not a reason to wedge
      if (capacity[target] - estUsed(target) < sz) continue;
      if (process.env.GTLUA_DEBUG) console.error(`[juggle]   move ${n} (${sz}) ${bin} -> ${target}`);
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

function build(entry, outPath, sheetPath, num8 = false) {
  if (!existsSync(entry)) fail(`no such file: ${entry}`);
  const tc = findToolchain();
  const projDir = path.dirname(path.resolve(entry));
  const buildDir = path.join(projDir, "build");
  mkdirSync(buildDir, { recursive: true });
  const name = path.basename(entry, path.extname(entry));
  const gtr = outPath ?? path.join(projDir, `${name}.gtr`);

  const CFLAGS = ["-t", "none", "-Osr", "--cpu", "65c02", "--codesize", "500",
                  "--static-locals", "-I", SDK];
  // --num8: fixed becomes 8.8-in-an-int everywhere — the game C and every
  // SDK unit must agree on the width, so the define rides the shared CFLAGS
  if (num8) CFLAGS.push("-DGT_NUM8");
  const AFLAGS = ["--cpu", "W65C02"];
  if (tc.asminc && existsSync(tc.asminc)) AFLAGS.push("-I", tc.asminc);
  // compile C then run the gtlua peephole pass over cc65's assembly output
  // (tail-call fusion + dead reload elimination — see compiler/peephole.js)
  let phTail = 0, phReload = 0;
  const cc = (src, dst, extra = []) => {
    run(tc.cc65, [...CFLAGS, ...extra, "-o", dst, src]);
    const opt = peephole(readFileSync(dst, "utf8"));
    writeFileSync(dst, opt.text);
    phTail += opt.stats.tailCalls;
    phReload += opt.stats.reloads;
  };
  const as = (src, obj) => run(tc.ca65, [...AFLAGS, "-o", obj, src]);
  const B = (f) => path.join(buildDir, f);

  // 1. lua -> C (flat 32 KB attempt first)
  let result = compileLua(entry, { num8 });
  const usesAudio = result.c.includes("gt_audio_init(");
  const usesStarfield = result.c.includes("gt_starfield");
  const usesAutocls = result.c.includes("gt_autocls_set(");
  const usesPackedSheet = !!sheetPath &&
    !(result.c.includes("gt_bg_compose(") || result.c.includes("gt_gspr("));
  const apiDefs = [
    ...(usesStarfield ? ["-DGT_STARFIELD"] : []),
    ...(usesAutocls ? ["-DGT_AUTOCLS"] : []),
    ...(usesPackedSheet ? ["-DGT_SHEET_PACKED"] : []),
  ];
  // sfx()/music() pull in the tracker (gt_music.c). Its data + per-frame
  // sequencer are small and read across arbitrary game banks every frame, so
  // it stays in the always-mapped fixed bank (compiled plain, not -DGT_BANKED).
  const usesMusic = result.c.includes("gt_music_init(");
  // gt_bg (offscreen-GRAM background) is only linked when the game uses it —
  // its compose body rides in bank 2 with the sheet, so linking it into a game
  // that doesn't need it just steals bank-2 space from the game's own code.
  const usesBg = result.c.includes("gt_bg_compose(") || result.c.includes("gt_bg_draw(") ||
    result.c.includes("gt_bg_clear(") || result.c.includes("gt_bg_tile(") ||
    result.c.includes("gt_gspr(");
  // atlas builders (bg_clear/bg_tile) carry a second bank-2 decode body —
  // only compile + reserve for it when the game actually stamps tiles
  const usesAtlas = result.c.includes("gt_bg_clear(") || result.c.includes("gt_bg_tile(");
  writeFileSync(B(`${name}.c`), result.c);
  writeFileSync(B("sheet.c"), makeSheetC(sheetPath, false));

  // 2. compile + assemble everything
  cc(B(`${name}.c`), B(`${name}.s`));
  cc(path.join(SDK, "gt_api.c"), B("gt_api.s"), apiDefs);
  cc(path.join(SDK, "gt_fixed.c"), B("gt_fixed.s"));
  cc(path.join(SDK, "gt_math.c"), B("gt_math.s"));
  if (usesBg) cc(path.join(SDK, "gt_bg.c"), B("gt_bg.s"), usesAtlas ? ["-DGT_BG_ATLAS"] : []);
  if (usesAudio) cc(path.join(SDK, "gt_audio.c"), B("gt_audio.s"));
  if (usesMusic) cc(path.join(SDK, "gt_music.c"), B("gt_music.s"));
  cc(B("sheet.c"), B("sheet.s"));

  as(path.join(SDK, "crt0.s"), B("crt0.o"));
  as(path.join(SDK, "vectors.s"), B("vectors.o"));
  as(path.join(SDK, "interrupt.s"), B("interrupt.o"));
  as(path.join(SDK, "gt_blitq.s"), B("gt_blitq.o"));
  as(path.join(SDK, num8 ? "gt_fixed8_asm.s" : "gt_fixed_asm.s"), B("gt_fixed_asm.o"));
  as(B("gt_api.s"), B("gt_api.o"));
  as(B("gt_fixed.s"), B("gt_fixed.o"));
  as(B("gt_math.s"), B("gt_math.o"));
  if (usesBg) as(B("gt_bg.s"), B("gt_bg.o"));
  if (usesAudio) as(B("gt_audio.s"), B("gt_audio.o"));
  if (usesMusic) as(B("gt_music.s"), B("gt_music.o"));
  as(B("sheet.s"), B("sheet.o"));
  as(B(`${name}.s`), B(`${name}.o`));

  const baseObjs = [
    B("crt0.o"), B("vectors.o"), B("interrupt.o"), B("gt_blitq.o"),
    B("gt_api.o"), B("gt_fixed.o"), B("gt_fixed_asm.o"), B("gt_math.o"),
    ...(usesBg ? [B("gt_bg.o")] : []),
    ...(usesAudio ? [B("gt_audio.o")] : []),
    ...(usesMusic ? [B("gt_music.o")] : []),
    B("sheet.o"),
  ];

  // 3. link: flat 32 KB
  const link32 = runLink(tc.ld65, [
    "-C", path.join(SDK, "gametank.cfg"),
    "-o", gtr,
    "-m", B(`${name}.map`),
    "-Ln", B(`${name}.lbl`),
    ...baseObjs, B(`${name}.o`),
    tc.lib,
  ]);
  if (link32.ok) {
    console.log(`${gtr} (${statSync(gtr).size} bytes, EEPROM32K)`);
    return;
  }

  // 4. overflow -> FLASH2M banked build
  const over = link32.overflows.reduce((a, o) => a + o.bytes, 0);
  console.error(`32 KB cart overflows by ~${over} bytes — re-targeting the 2 MB FLASH2M cart`);
  let sizes = functionSizes(B(`${name}.s`));
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
  const sheetBytes = sheetPath
    ? (usesBg ? 8192 : packbits(Array.from(readFileSync(sheetPath))).length)
    : 0;
  const placement = initialPlacement(result.callGraph);

  as(path.join(SDK, "gt_bank.s"), B("gt_bank.o"));
  writeFileSync(B("sheet.c"), makeSheetC(sheetPath, true, !usesBg));
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
  run(tc.cc65, [...CFLAGS, "-DGT_BANKED", "-o", B("gt_math.s"),
                path.join(SDK, "gt_math.c")]);
  as(B("gt_math.s"), B("gt_math.o"));
  as(path.join(SDK, "gt_math_stubs.s"), B("gt_math_stubs.o"));

  // gt_bg_compose reads the sheet (which rides in bank 2 for FLASH2M) to paint
  // the background page — recompile it banked: the decode body goes to B2CODE
  // (bank 2, with the sheet) and a fixed-bank stub maps bank 2 before calling it.
  if (usesBg) {
    run(tc.cc65, [...CFLAGS, "-DGT_BANKED", "-DGT_SHEET_BANK=2",
                  ...(usesAtlas ? ["-DGT_BG_ATLAS"] : []),
                  "-o", B("gt_bg.s"), path.join(SDK, "gt_bg.c")]);
    as(B("gt_bg.s"), B("gt_bg.o"));
  }

  // The flat-attempt gt_audio.o placed the 4 KB ACP firmware blob in the
  // fixed bank's RODATA — the single biggest reason banked games had to
  // ship silent. Recompile it banked: the blob rides in bank 2 (with the
  // sheet) and gt_audio_init() maps that bank in before the ARAM upload.
  if (usesAudio) {
    run(tc.cc65, [...CFLAGS, "-DGT_BANKED", "-DGT_FW_BANK=0",
                  "-o", B("gt_audio.s"), path.join(SDK, "gt_audio.c")]);
    as(B("gt_audio.s"), B("gt_audio.o"));
  }

  // gt_api carries ~2 KB of cold bodies (font upload, sheet load, circfill/
  // circ/line-diagonal, starfield init/move, the glyph table) that exile to
  // bank 2 under GT_BANKED — the fixed window can't hold them all plus the
  // blitter font. Recompile banked so those pragmas take effect.
  run(tc.cc65, [...CFLAGS, "-DGT_BANKED", ...apiDefs,
                "-o", B("gt_api.s"), path.join(SDK, "gt_api.c")]);
  as(B("gt_api.s"), B("gt_api.o"));
  run(tc.cc65, [...CFLAGS, "-DGT_BANKED",
                "-o", B("gt_fixed.s"), path.join(SDK, "gt_fixed.c")]);
  as(B("gt_fixed.s"), B("gt_fixed.o"));

  // gt_music (sfx/music sequencer + its instrument/sfx/song tables) is another
  // fat unit that would blow the near-full fixed bank's RODATA/CODE. Recompile
  // it banked: the impls + tables ride in bank 2 (B2CODE/B2RODATA, renamed
  // _impl) and the fixed-bank stubs in gt_music_stubs.o bridge every call
  // (game code AND gt_endframe's frame hook) with a bank-2 switch.
  if (usesMusic) {
    run(tc.cc65, [...CFLAGS, "-DGT_BANKED",
                  "-o", B("gt_music.s"), path.join(SDK, "gt_music.c")]);
    as(B("gt_music.s"), B("gt_music.o"));
    as(path.join(SDK, "gt_music_stubs.s"), B("gt_music_stubs.o"));
  }

  let linked = null;
  let lastOverflows = [];
  // The min/max/mid ternary inlining is a speed-for-size trade. A game at the
  // bank-capacity cliff can fail to place WITH it but link fine WITHOUT it —
  // so if placement is still failing halfway through the attempts, fall back
  // to the compact call form and start placement over.
  let midInline = true;
  let fnInline = true;
  let workPlacement = placement;
  let fwB1 = false;
  let rndInt = true;
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
      run(tc.cc65, [...CFLAGS, "-DGT_BANKED", ...apiDefs,
                    "-o", B("gt_api.s"), path.join(SDK, "gt_api.c")]);
      as(B("gt_api.s"), B("gt_api.o"));
      workPlacement = initialPlacement(result.callGraph);
      console.error("bank placement tight: b2 relief undone (bank 2 is the tight bank)");
    }
    if (attempt === 26 && fnInline) {
      fnInline = false;
      workPlacement = initialPlacement(result.callGraph);
      console.error("bank placement tight: retrying with function inlining off");
    }
    if (attempt === 4 && usesAudio && !fwB1 && (overBins.has("b0") || overBins.has("fixed"))) {
      // the 4KB ACP firmware defaults to bank 0; carts whose update loop
      // owns bank 0 need it in bank 1 instead
      fwB1 = true;
      run(tc.cc65, [...CFLAGS, "-DGT_BANKED", "-DGT_FW_BANK=1",
                    "-o", B("gt_audio.s"), path.join(SDK, "gt_audio.c")]);
      as(B("gt_audio.s"), B("gt_audio.o"));
      workPlacement = initialPlacement(result.callGraph);
      console.error("bank placement tight: audio firmware to bank 1");
    }
    if (attempt === 8 && !apiDefs.includes("-DGT_INPUT_B2") &&
        (overBins.has("b0") || overBins.has("fixed")) && !overBins.has("b2")) {
      // which bank the SDK input block fits in is per-cart: b0-heavy carts
      // (big update loop + audio firmware) need it in bank 2 and vice versa
      apiDefs.push("-DGT_INPUT_B2");
      run(tc.cc65, [...CFLAGS, "-DGT_BANKED", ...apiDefs,
                    "-o", B("gt_api.s"), path.join(SDK, "gt_api.c")]);
      as(B("gt_api.s"), B("gt_api.o"));
      workPlacement = initialPlacement(result.callGraph);
      console.error("bank placement tight: input block to bank 2");
    }
    if (attempt === 14 && rndInt) {
      // size relief: the integer-rnd fast path costs ~90 fixed bytes of
      // trampoline + call-site changes; carts at the absolute capacity
      // cliff give it up before giving up the blit font
      rndInt = false;
      workPlacement = initialPlacement(result.callGraph);
      console.error("bank placement tight: integer-rnd fast path off");
    }
    if (attempt === 20 && !apiDefs.includes("-DGT_NO_BLITFONT")) {
      // final size relief: drop the GRAM blit font (~1 KB across banks);
      // print falls back to the per-pixel CPU path — correct, just slower
      apiDefs.push("-DGT_NO_BLITFONT");
      run(tc.cc65, [...CFLAGS, "-DGT_BANKED", ...apiDefs,
                    "-o", B("gt_api.s"), path.join(SDK, "gt_api.c")]);
      as(B("gt_api.s"), B("gt_api.o"));
      workPlacement = initialPlacement(result.callGraph);
      console.error("bank placement tight: dropping the blit font (CPU print fallback)");
    }
    if (attempt === 32 && midInline) {
      midInline = false;
      workPlacement = initialPlacement(result.callGraph);
      console.error("bank placement tight: retrying with all inlining off");
    }
    const compileAndLink = (placementNow) => {
      result = compileLua(entry, { banked: true, placement: placementNow, midInline, inliner: fnInline, num8, rndInt });
      writeFileSync(B(`${name}.c`), result.c);
      cc(B(`${name}.c`), B(`${name}.s`));
      as(B(`${name}.s`), B(`${name}.o`));
      writeFileSync(B("stubs.s"), (result.stubs ?? "; no cross-bank calls\n") + "\n");
      as(B("stubs.s"), B("stubs.o"));
      return runLink(tc.ld65, [
        "-C", path.join(SDK, "gametank_flash2m.cfg"),
        "-o", B(`${name}.banks`),
        "-m", B(`${name}.map`),
        "-Ln", B(`${name}.lbl`),
        ...baseObjs, B("gt_bank.o"), B("gt_math_stubs.o"),
        ...(usesMusic ? [B("gt_music_stubs.o")] : []),
        B("stubs.o"),
        B(`${name}.o`),
        tc.lib,
      ]);
    };
    const link = compileAndLink(workPlacement);
    // re-measure per attempt: the .s parsed before the loop can be stale
    // (previous run's build dir) and the inlining rungs change which
    // functions even exist — a stale map makes the mover shuffle size-0
    // ghosts while the real hogs stay put
    sizes = functionSizes(B(`${name}.s`));
    foldRodataSizes(result.c, sizes);

    if (link.ok) {
      linked = B(`${name}.banks`);
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
        for (let round = 0; round < 10; round++) {
          const edges = stubbedEdges(workPlacement, result.callGraph, hot)
            .filter((e) => e.w >= 10 && !attempted.has(`${e.caller}>${e.callee}`));
          if (!edges.length) break;
          const e = edges[0];
          attempted.add(`${e.caller}>${e.callee}`);
          // a shared callee can't chase one caller's bank without stubbing
          // its other callers — score BOTH directions, take the better
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
          const relink = compileAndLink(workPlacement);
          if (relink.ok) {
            bestScore = best.cand;
            dirty = false;
            if (process.env.GTLUA_DEBUG) console.error(`[repair] ${best.fn} -> ${best.target} (score ${best.cand})`);
          } else {
            workPlacement[best.fn] = best.prev;
            dirty = true;
          }
        }
        // artifacts on disk must match the accepted placement
        if (dirty) compileAndLink(workPlacement);
      }
      break;
    }
    lastOverflows = link.overflows;
    const mapInfo = sdkLoadFromMap(B(`${name}.map`));
    if (mapInfo) calibrateSizes(sizes, workPlacement, mapInfo.port);
    const moved = rebalance(workPlacement, sizes, link.overflows, sheetBytes, result.callGraph, usesBg, usesAudio, usesMusic, usesAtlas, mapInfo?.load ?? null);
    if (!moved && attempt >= 40) {
      fail("FLASH2M bank placement failed: " +
        link.overflows.map((o) => `${o.segment} over by ${o.bytes}`).join(", "));
    }
  }
  if (!linked) fail("FLASH2M bank placement did not converge; last overflows: " +
    lastOverflows.map((o) => `${o.segment} over by ${o.bytes}`).join(", "));

  // 5. lay the four 16 KB pieces into the 2 MB flash image:
  //    bank n at n*0x4000, the fixed bank last (offset 0x1FC000)
  const pieces = readFileSync(linked);
  if (pieces.length !== 4 * BANK_SIZE) {
    fail(`unexpected banked link output size ${pieces.length}`);
  }
  const img = Buffer.alloc(FLASH_SIZE, 0xff);
  img.set(pieces.subarray(0 * BANK_SIZE, 1 * BANK_SIZE), 0x000000);
  img.set(pieces.subarray(1 * BANK_SIZE, 2 * BANK_SIZE), 0x004000);
  img.set(pieces.subarray(2 * BANK_SIZE, 3 * BANK_SIZE), 0x008000);
  img.set(pieces.subarray(3 * BANK_SIZE, 4 * BANK_SIZE), FLASH_SIZE - BANK_SIZE);
  writeFileSync(gtr, img);

  // save the placement the successful link ACTUALLY used — the ladder rungs
  // rebind workPlacement, and saving the original seed object poisoned the
  // next build's starting point with a stale layout
  writeFileSync(B("banks.json"), JSON.stringify(workPlacement, null, 1));
  const counts = { fixed: 0, b0: 0, b1: 0, b2: 0 };
  for (const b of Object.values(workPlacement)) counts[b]++;
  console.log(`${gtr} (${statSync(gtr).size} bytes, FLASH2M; ` +
    `functions fixed:${counts.fixed} bank0:${counts.b0} bank1:${counts.b1} bank2:${counts.b2})`);
}

// ---- main -------------------------------------------------------------------

const [, , cmd, ...rest] = process.argv;
if (cmd === "build") {
  const oIdx = rest.indexOf("-o");
  const outPath = oIdx !== -1 ? rest[oIdx + 1] : undefined;
  const sIdx = rest.indexOf("--sheet");
  const sheetPath = sIdx !== -1 ? rest[sIdx + 1] : undefined;
  const nIdx = rest.indexOf("--num8");
  const entry = rest.filter((a, i) =>
    i !== oIdx && i !== (oIdx === -1 ? -2 : oIdx + 1) &&
    i !== sIdx && i !== (sIdx === -1 ? -2 : sIdx + 1) &&
    i !== nIdx)[0];
  if (!entry) fail("usage: gtlua build <main.lua> [--sheet gfx.bin] [--num8] [-o game.gtr]");
  build(entry, outPath, sheetPath, nIdx !== -1);
} else if (cmd === "c") {
  if (!rest[0]) fail("usage: gtlua c <main.lua>");
  process.stdout.write(compileLua(rest[0]).c);
} else {
  fail("usage: gtlua build <main.lua> [--sheet gfx.bin] [-o game.gtr] | gtlua c <main.lua>");
}
