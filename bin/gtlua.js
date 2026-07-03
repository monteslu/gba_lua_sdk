#!/usr/bin/env node
// gtlua CLI — compile a .lua game to a GameTank .gtr cartridge.
//
//   gtlua build <main.lua> [-o game.gtr]   compile + assemble + link
//   gtlua c <main.lua>                     print the generated C (debugging)
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

function compileLua(entry) {
  const source = readFileSync(entry, "utf8");
  const { ok, c, diagnostics } = compile(source, path.basename(entry));
  const warnings = diagnostics.filter((d) => d.severity === "warning");
  if (warnings.length) console.error(formatDiagnostics(warnings));
  if (!ok) {
    console.error(formatDiagnostics(diagnostics.filter((d) => d.severity === "error")));
    process.exit(1);
  }
  return c;
}

function build(entry, outPath, sheetPath) {
  if (!existsSync(entry)) fail(`no such file: ${entry}`);
  const tc = findToolchain();
  const projDir = path.dirname(path.resolve(entry));
  const buildDir = path.join(projDir, "build");
  mkdirSync(buildDir, { recursive: true });
  const name = path.basename(entry, path.extname(entry));
  const gtr = outPath ?? path.join(projDir, `${name}.gtr`);

  // 1. lua -> C
  const cPath = path.join(buildDir, `${name}.c`);
  writeFileSync(cPath, compileLua(entry));

  // 1b. sprite sheet: pack the 4bpp PICO-8 sheet into ROM + a loader call
  const sheetC = path.join(buildDir, "sheet.c");
  if (sheetPath) {
    const raw = readFileSync(sheetPath);
    if (raw.length !== 8192) fail(`--sheet expects an 8192-byte 4bpp gfx.bin (got ${raw.length})`);
    const bytes = Array.from(raw).join(",");
    writeFileSync(sheetC,
      `#include "gt_api.h"\n` +
      `static const unsigned char sheet_data[8192] = {${bytes}};\n` +
      `void gt_sheet_init(void) { gt_sheet_load(sheet_data); }\n`);
  } else {
    writeFileSync(sheetC, `void gt_sheet_init(void) {}\n`);
  }

  // 2. C -> asm (generated code + runtime), same flags as the C SDK
  const CFLAGS = ["-t", "none", "-Osr", "--cpu", "65c02", "--codesize", "500",
                  "--static-locals", "-I", SDK];
  const cc = (src, dst) => run(tc.cc65, [...CFLAGS, "-o", dst, src]);
  cc(cPath, path.join(buildDir, `${name}.s`));
  cc(path.join(SDK, "gt_api.c"), path.join(buildDir, "gt_api.s"));
  cc(path.join(SDK, "gt_fixed.c"), path.join(buildDir, "gt_fixed.s"));
  cc(path.join(SDK, "gt_math.c"), path.join(buildDir, "gt_math.s"));
  cc(sheetC, path.join(buildDir, "sheet.s"));

  // 3. assemble everything
  const AFLAGS = ["--cpu", "W65C02"];
  if (tc.asminc && existsSync(tc.asminc)) AFLAGS.push("-I", tc.asminc);
  const objs = [];
  const as = (src, obj) => { run(tc.ca65, [...AFLAGS, "-o", obj, src]); objs.push(obj); };
  as(path.join(SDK, "crt0.s"), path.join(buildDir, "crt0.o"));
  as(path.join(SDK, "vectors.s"), path.join(buildDir, "vectors.o"));
  as(path.join(SDK, "interrupt.s"), path.join(buildDir, "interrupt.o"));
  as(path.join(buildDir, "gt_api.s"), path.join(buildDir, "gt_api.o"));
  as(path.join(buildDir, "gt_fixed.s"), path.join(buildDir, "gt_fixed.o"));
  as(path.join(buildDir, "gt_math.s"), path.join(buildDir, "gt_math.o"));
  as(path.join(buildDir, "sheet.s"), path.join(buildDir, "sheet.o"));
  as(path.join(buildDir, `${name}.s`), path.join(buildDir, `${name}.o`));

  // 4. link -> flat 32 KB .gtr
  run(tc.ld65, [
    "-C", path.join(SDK, "gametank.cfg"),
    "-o", gtr,
    "-m", path.join(buildDir, `${name}.map`),
    "-Ln", path.join(buildDir, `${name}.lbl`),
    ...objs,
    tc.lib,
  ]);

  const size = statSync(gtr).size;
  console.log(`${gtr} (${size} bytes)`);
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
  process.stdout.write(compileLua(rest[0]));
} else {
  fail("usage: gtlua build <main.lua> [-o game.gtr] | gtlua c <main.lua>");
}
