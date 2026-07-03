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
  const re = /Segment '?‘?([A-Z0-9]+)'?’? overflows memory area '?‘?\w+'?’? by (\d+) bytes/g;
  let m;
  while ((m = re.exec(text)) !== null) overflows.push({ segment: m[1], bytes: Number(m[2]) });
  if (!overflows.length) {
    process.stderr.write(text);
    fail(`${path.basename(cmd)} failed (exit ${r.status})`);
  }
  return { ok: false, overflows, text };
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

function makeSheetC(sheetPath, banked) {
  if (!sheetPath) return `void gt_sheet_init(void) {}\n`;
  const raw = readFileSync(sheetPath);
  if (raw.length !== 8192) fail(`--sheet expects an 8192-byte 4bpp gfx.bin (got ${raw.length})`);
  const bytes = Array.from(raw).join(",");
  if (banked) {
    // sheet data lives in bank 2; the loader (fixed bank) maps it in first
    return `#include "gt_api.h"\n` +
      `#pragma rodata-name ("SHEET")\n` +
      `static const unsigned char sheet_data[8192] = {${bytes}};\n` +
      `#pragma rodata-name ("RODATA")\n` +
      `void gt_sheet_init(void) { gt_bank(2); gt_sheet_load(sheet_data); }\n`;
  }
  return `#include "gt_api.h"\n` +
    `static const unsigned char sheet_data[8192] = {${bytes}};\n` +
    `void gt_sheet_init(void) { gt_sheet_load(sheet_data); }\n`;
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
const SEG_BIN = { B0CODE: "b0", B1CODE: "b1", B2CODE: "b2", CODE: "fixed", RODATA: "fixed", B0RODATA: "b0", B1RODATA: "b1", B2RODATA: "b2" };

// rebalance after a link overflow: move functions out of the fat bins
function rebalance(placement, sizes, overflows, sheetBytes, callGraph, usesBg) {
  const bins = { b0: [], b1: [], b2: [], fixed: [] };
  for (const [name, bin] of Object.entries(placement)) bins[bin].push(name);
  const estUsed = (bin) => bins[bin].reduce((a, n) => a + (sizes.get(n) ?? 0), 0);

  // free space estimates per receiving bin. The fixed bank already holds the
  // ~12 KB runtime + stubs, so game functions get a small conservative slice
  // of it; ld65 re-checks every iteration and the ROM-overflow branch bails
  // us out if the estimate was optimistic.
  // gt_bg_compose's decode body rides in bank 2 (B2CODE, ~625 B) alongside the
  // sheet so it's mapped when it reads the sheet — reserve for it so the
  // game-function packer doesn't overfill bank 2 and fail to converge.
  const B2_SDK_RESERVE = usesBg ? 700 : 0;
  const capacity = {
    b0: BANK_SIZE - BANK_MARGIN,
    b1: BANK_SIZE - BANK_MARGIN,
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
      // fixed bank too full: push the largest movable fixed functions into
      // the emptiest bank
      const movable = bins.fixed
        .filter((n) => !CALLBACKS.has(n))
        .sort((a, b) => (sizes.get(b) ?? 0) - (sizes.get(a) ?? 0));
      for (const n of movable) {
        if (need <= 0) break;
        const target = ["b2", "b1", "b0"].sort((x, y) =>
          (capacity[y] - estUsed(y)) - (capacity[x] - estUsed(x)))[0];
        if ((capacity[target] - estUsed(target)) < (sizes.get(n) ?? 0)) continue;
        placement[n] = target;
        bins[target].push(n);
        bins.fixed.splice(bins.fixed.indexOf(n), 1);
        need -= sizes.get(n) ?? 0;
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
    const movable = bins[bin]
      .filter((n) => !CALLBACKS.has(n) && (sizes.get(n) ?? 0) >= 200)
      .sort((a, b) => (sizes.get(b) ?? 0) - (sizes.get(a) ?? 0));
    for (const n of movable) {
      if (need <= 0) break;
      const sz = sizes.get(n) ?? 0;
      const targets = ["b2", bin === "b0" ? "b1" : "b0", "fixed"]
        .filter((t) => t !== bin && capacity[t] - estUsed(t) >= sz);
      if (!targets.length) continue;
      const target = targets[0];
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

function build(entry, outPath, sheetPath) {
  if (!existsSync(entry)) fail(`no such file: ${entry}`);
  const tc = findToolchain();
  const projDir = path.dirname(path.resolve(entry));
  const buildDir = path.join(projDir, "build");
  mkdirSync(buildDir, { recursive: true });
  const name = path.basename(entry, path.extname(entry));
  const gtr = outPath ?? path.join(projDir, `${name}.gtr`);

  const CFLAGS = ["-t", "none", "-Osr", "--cpu", "65c02", "--codesize", "500",
                  "--static-locals", "-I", SDK];
  const AFLAGS = ["--cpu", "W65C02"];
  if (tc.asminc && existsSync(tc.asminc)) AFLAGS.push("-I", tc.asminc);
  const cc = (src, dst) => run(tc.cc65, [...CFLAGS, "-o", dst, src]);
  const as = (src, obj) => run(tc.ca65, [...AFLAGS, "-o", obj, src]);
  const B = (f) => path.join(buildDir, f);

  // 1. lua -> C (flat 32 KB attempt first)
  let result = compileLua(entry);
  const usesAudio = result.c.includes("gt_audio_init(");
  // gt_bg (offscreen-GRAM background) is only linked when the game uses it —
  // its compose body rides in bank 2 with the sheet, so linking it into a game
  // that doesn't need it just steals bank-2 space from the game's own code.
  const usesBg = result.c.includes("gt_bg_compose(") || result.c.includes("gt_bg_draw(");
  writeFileSync(B(`${name}.c`), result.c);
  writeFileSync(B("sheet.c"), makeSheetC(sheetPath, false));

  // 2. compile + assemble everything
  cc(B(`${name}.c`), B(`${name}.s`));
  cc(path.join(SDK, "gt_api.c"), B("gt_api.s"));
  cc(path.join(SDK, "gt_fixed.c"), B("gt_fixed.s"));
  cc(path.join(SDK, "gt_math.c"), B("gt_math.s"));
  if (usesBg) cc(path.join(SDK, "gt_bg.c"), B("gt_bg.s"));
  if (usesAudio) cc(path.join(SDK, "gt_audio.c"), B("gt_audio.s"));
  cc(B("sheet.c"), B("sheet.s"));

  as(path.join(SDK, "crt0.s"), B("crt0.o"));
  as(path.join(SDK, "vectors.s"), B("vectors.o"));
  as(path.join(SDK, "interrupt.s"), B("interrupt.o"));
  as(path.join(SDK, "gt_blitq.s"), B("gt_blitq.o"));
  as(path.join(SDK, "gt_fixed_asm.s"), B("gt_fixed_asm.o"));
  as(B("gt_api.s"), B("gt_api.o"));
  as(B("gt_fixed.s"), B("gt_fixed.o"));
  as(B("gt_math.s"), B("gt_math.o"));
  if (usesBg) as(B("gt_bg.s"), B("gt_bg.o"));
  if (usesAudio) as(B("gt_audio.s"), B("gt_audio.o"));
  as(B("sheet.s"), B("sheet.o"));
  as(B(`${name}.s`), B(`${name}.o`));

  const baseObjs = [
    B("crt0.o"), B("vectors.o"), B("interrupt.o"), B("gt_blitq.o"),
    B("gt_api.o"), B("gt_fixed.o"), B("gt_fixed_asm.o"), B("gt_math.o"),
    ...(usesBg ? [B("gt_bg.o")] : []),
    ...(usesAudio ? [B("gt_audio.o")] : []),
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
  const sizes = functionSizes(B(`${name}.s`));
  const sheetBytes = sheetPath ? 8192 : 0;
  const placement = initialPlacement(result.callGraph);

  as(path.join(SDK, "gt_bank.s"), B("gt_bank.o"));
  writeFileSync(B("sheet.c"), makeSheetC(sheetPath, true));
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
                  "-o", B("gt_bg.s"), path.join(SDK, "gt_bg.c")]);
    as(B("gt_bg.s"), B("gt_bg.o"));
  }

  // The flat-attempt gt_audio.o placed the 4 KB ACP firmware blob in the
  // fixed bank's RODATA — the single biggest reason banked games had to
  // ship silent. Recompile it banked: the blob rides in bank 2 (with the
  // sheet) and gt_audio_init() maps that bank in before the ARAM upload.
  if (usesAudio) {
    run(tc.cc65, [...CFLAGS, "-DGT_BANKED", "-DGT_FW_BANK=2",
                  "-o", B("gt_audio.s"), path.join(SDK, "gt_audio.c")]);
    as(B("gt_audio.s"), B("gt_audio.o"));
  }

  let linked = null;
  for (let attempt = 0; attempt < 8; attempt++) {
    result = compileLua(entry, { banked: true, placement });
    writeFileSync(B(`${name}.c`), result.c);
    cc(B(`${name}.c`), B(`${name}.s`));
    as(B(`${name}.s`), B(`${name}.o`));
    writeFileSync(B("stubs.s"), (result.stubs ?? "; no cross-bank calls\n") + "\n");
    as(B("stubs.s"), B("stubs.o"));

    const flashOut = B(`${name}.banks`);
    const link = runLink(tc.ld65, [
      "-C", path.join(SDK, "gametank_flash2m.cfg"),
      "-o", flashOut,
      "-m", B(`${name}.map`),
      "-Ln", B(`${name}.lbl`),
      ...baseObjs, B("gt_bank.o"), B("gt_math_stubs.o"), B("stubs.o"),
      B(`${name}.o`),
      tc.lib,
    ]);
    if (link.ok) { linked = flashOut; break; }
    const moved = rebalance(placement, sizes, link.overflows, sheetBytes, result.callGraph, usesBg);
    if (!moved) {
      fail("FLASH2M bank placement failed: " +
        link.overflows.map((o) => `${o.segment} over by ${o.bytes}`).join(", "));
    }
  }
  if (!linked) fail("FLASH2M bank placement did not converge");

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

  writeFileSync(B("banks.json"), JSON.stringify(placement, null, 1));
  const counts = { fixed: 0, b0: 0, b1: 0, b2: 0 };
  for (const b of Object.values(placement)) counts[b]++;
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
  const entry = rest.filter((a, i) =>
    i !== oIdx && i !== (oIdx === -1 ? -2 : oIdx + 1) &&
    i !== sIdx && i !== (sIdx === -1 ? -2 : sIdx + 1))[0];
  if (!entry) fail("usage: gtlua build <main.lua> [--sheet gfx.bin] [-o game.gtr]");
  build(entry, outPath, sheetPath);
} else if (cmd === "c") {
  if (!rest[0]) fail("usage: gtlua c <main.lua>");
  process.stdout.write(compileLua(rest[0]).c);
} else {
  fail("usage: gtlua build <main.lua> [--sheet gfx.bin] [-o game.gtr] | gtlua c <main.lua>");
}
