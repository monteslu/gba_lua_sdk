#!/usr/bin/env node
// driftmania banked build driver.
//
// Why this exists (see PORT_NOTES.md "SDK findings"): the port needs the
// 2 MB FLASH2M target (2100+ lines of code + the 8 KB sheet outgrow the
// 32 KB flat cart) AND it uses gt.note audio. bin/gtlua.js's automatic
// banked path can't link an audio game: gt_audio.c's 4 KB ACP firmware blob
// lands in the FIXED bank's RODATA, which overflows the 16 KB fixed window
// ("RODATA over by ~3192"). This driver applies the combo-pool workaround:
//   1. Compile gt_audio.c with the firmware #include wrapped in
//      #pragma rodata-name("SHEET") so the blob rides in bank 2 next to the
//      sprite sheet. main() calls gt_sheet_init() (selects bank 2) right
//      before gt_audio_init(), so the firmware is mapped in exactly when the
//      one-time upload runs.
//   2. Park cc65's tail string-literal pool in B1RODATA (all of this port's
//      print() literals belong to the bank-1 draw/HUD path).
// Everything else mirrors bin/gtlua.js's FLASH2M path.
//
//   node ports/driftmania/build.mjs
//
// Once the SDK's banked build handles audio, delete this file and use:
//   node bin/gtlua.js build ports/driftmania/main.lua \
//     --sheet ports/driftmania/gfx.bin -o ports/driftmania/main.gtr

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.dirname(path.dirname(HERE));
const SDK = path.join(REPO, "sdk");
const ENTRY = path.join(HERE, "main.lua");
const SHEET = path.join(HERE, "gfx.bin");

const { compile, formatDiagnostics } = await import(REPO + "/compiler/index.js");

const BANK_SIZE = 0x4000;
const FLASH_SIZE = 0x200000;

// Hand placement across the three switched 16 KB banks + the fixed bank.
//   bank 0: the _update physics path (hot loop, self-contained)
//   bank 1: the _draw / HUD path (holds every print() string literal) plus
//           the cold gd_* data-init functions (they only fill RAM arrays, so
//           they can live anywhere — bank 2 is full of the sheet+firmware)
//   bank 2: only the sheet + the ACP firmware (12 KB) leave ~4 KB for _init
//   fixed : ckd/ckt/ctile/m3 — tiny leaf unpackers called from BOTH paths,
//           so keeping them stub-free in the fixed bank avoids a bank-switch
//           on every tile lookup in the hot draw + collision loops.
const PLACEMENT = {
  _update: "b0",
  road_tile: "b0",
  prop_tile: "b0",
  grass_at: "b0",
  wallmask: "b0",
  collides_at: "b0",
  on_cp: "b0",
  add_trail: "b0",
  wheelx: "b0",
  wheely: "b0",
  step_events: "b0",
  move_x: "b0",
  move_y: "b0",
  sgn0: "b0",
  reset: "b0",

  _draw: "b1",
  draw_tiles: "b1",
  pad2: "b1",
  fmt_time: "b1",
  lights: "b1",
  hud: "b1",
  gd_init: "b1",
  gd_1: "b1",
  gd_2: "b1",
  gd_3: "b0",
  gd_4: "b1",
  gd_5: "b1",

  ckd: "fixed",
  ckt: "fixed",
  ctile: "fixed",
  m3: "fixed",

  _init: "b2",
};

function fail(msg) { console.error(msg); process.exit(1); }

function run(cmd, args) {
  const r = spawnSync(cmd, args, { encoding: "utf8" });
  if (r.error) fail(`${cmd}: ${r.error.message}`);
  if (r.status !== 0) {
    if (r.stdout) process.stderr.write(r.stdout);
    if (r.stderr) process.stderr.write(r.stderr);
    fail(`${path.basename(cmd)} failed (exit ${r.status})`);
  }
  if (r.stderr) process.stderr.write(r.stderr);
  return r;
}

const tcHome = process.env.GTLUA_CC65_HOME ?? path.join(REPO, "tools", "cc65");
const tc = {
  cc65: path.join(tcHome, "bin", "cc65"),
  ca65: path.join(tcHome, "bin", "ca65"),
  ld65: path.join(tcHome, "bin", "ld65"),
  lib: path.join(tcHome, "lib", "none.lib"),
  asminc: path.join(tcHome, "asminc"),
};
if (!existsSync(tc.cc65)) fail("cc65 not found — run scripts/install_tools.sh");

const buildDir = path.join(HERE, "build");
mkdirSync(buildDir, { recursive: true });
const B = (f) => path.join(buildDir, f);

// 1. lua -> banked C + far-call stubs
const source = readFileSync(ENTRY, "utf8");
const result = compile(source, "main.lua", { banked: true, placement: PLACEMENT });
const warnings = result.diagnostics.filter((d) => d.severity === "warning");
if (warnings.length) console.error(formatDiagnostics(warnings));
if (!result.ok) {
  console.error(formatDiagnostics(result.diagnostics.filter((d) => d.severity === "error")));
  process.exit(1);
}
for (const name of Object.keys(PLACEMENT)) {
  if (!result.callGraph.has(name)) console.error(`placement: no function '${name}' (stale entry?)`);
}
// cc65 defers the string-literal pool to the END of the translation unit,
// AFTER emit.js's #pragma rodata-name pops — so every print() literal would
// land in the fixed bank's RODATA and overflow it. All of this port's
// literals belong to bank-1 (draw/HUD) functions, so park the tail pool
// there. (Compiler-integration bug, documented in PORT_NOTES.md.)
writeFileSync(B("main.c"), result.c + '\n#pragma rodata-name ("B1RODATA")\n');
writeFileSync(B("stubs.s"), (result.stubs ?? "; no cross-bank calls\n") + "\n");

// 2. sheet in bank 2 (same shape bin/gtlua.js generates for banked builds).
// gfx.bin is the final 8 KB sheet from tools/gen.js (tile graphics in cells
// 0-127, the 32 pre-rotated 16x16 car frames in cells 128-255) — banked as-is.
const raw = readFileSync(SHEET);
if (raw.length !== 8192) fail(`sheet must be 8192 bytes, got ${raw.length}`);
writeFileSync(B("sheet.c"),
  `#include "gt_api.h"\n` +
  `#pragma rodata-name ("SHEET")\n` +
  `static const unsigned char sheet_data[8192] = {${Array.from(raw).join(",")}};\n` +
  `#pragma rodata-name ("RODATA")\n` +
  `void gt_sheet_init(void) { gt_bank(2); gt_sheet_load(sheet_data); }\n`);

// 3. gt_audio with the firmware blob banked into bank 2 (build-time text
// transform of the unmodified sdk source; pitch_table stays in fixed RODATA
// because gt_note() reads it at runtime from any bank)
const audioSrc = readFileSync(path.join(SDK, "gt_audio.c"), "utf8");
const marker = '#include "gt_acp_fw.h"';
if (!audioSrc.includes(marker)) fail("sdk/gt_audio.c layout changed — update build.mjs");
writeFileSync(B("gt_audio_b2.c"), audioSrc.replace(marker,
  `#pragma rodata-name (push, "SHEET")\n${marker}\n#pragma rodata-name (pop)`));

// 4. compile + assemble
const CFLAGS = ["-t", "none", "-Osr", "--cpu", "65c02", "--codesize", "500",
                "--static-locals", "-I", SDK];
const AFLAGS = ["--cpu", "W65C02"];
if (existsSync(tc.asminc)) AFLAGS.push("-I", tc.asminc);
const cc = (src, dst) => run(tc.cc65, [...CFLAGS, "-o", dst, src]);
const objs = [];
const as = (src, obj) => { run(tc.ca65, [...AFLAGS, "-o", obj, src]); objs.push(obj); };

cc(B("main.c"), B("main.s"));
cc(path.join(SDK, "gt_api.c"), B("gt_api.s"));
cc(path.join(SDK, "gt_fixed.c"), B("gt_fixed.s"));
cc(path.join(SDK, "gt_math.c"), B("gt_math.s"));
cc(B("gt_audio_b2.c"), B("gt_audio.s"));
cc(B("sheet.c"), B("sheet.s"));

as(path.join(SDK, "crt0.s"), B("crt0.o"));
as(path.join(SDK, "vectors.s"), B("vectors.o"));
as(path.join(SDK, "interrupt.s"), B("interrupt.o"));
as(path.join(SDK, "gt_bank.s"), B("gt_bank.o"));
as(B("gt_api.s"), B("gt_api.o"));
as(B("gt_fixed.s"), B("gt_fixed.o"));
as(B("gt_math.s"), B("gt_math.o"));
as(B("gt_audio.s"), B("gt_audio.o"));
as(B("sheet.s"), B("sheet.o"));
as(B("stubs.s"), B("stubs.o"));
as(B("main.s"), B("main.o"));

// 5. link the four 16 KB pieces, then lay them into the 2 MB flash image
run(tc.ld65, [
  "-C", path.join(SDK, "gametank_flash2m.cfg"),
  "-o", B("main.banks"),
  "-m", B("main.map"),
  "-Ln", B("main.lbl"),
  ...objs,
  tc.lib,
]);

const pieces = readFileSync(B("main.banks"));
if (pieces.length !== 4 * BANK_SIZE) fail(`unexpected link output size ${pieces.length}`);
const img = Buffer.alloc(FLASH_SIZE, 0xff);
img.set(pieces.subarray(0 * BANK_SIZE, 1 * BANK_SIZE), 0x000000);
img.set(pieces.subarray(1 * BANK_SIZE, 2 * BANK_SIZE), 0x004000);
img.set(pieces.subarray(2 * BANK_SIZE, 3 * BANK_SIZE), 0x008000);
img.set(pieces.subarray(3 * BANK_SIZE, 4 * BANK_SIZE), FLASH_SIZE - BANK_SIZE);
const gtr = path.join(HERE, "main.gtr");
writeFileSync(gtr, img);
console.log(`${gtr} (${statSync(gtr).size} bytes, FLASH2M)`);
