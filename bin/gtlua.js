#!/usr/bin/env node
// gtlua CLI - compile a .lua game to a Game Boy Advance .gba ROM.
//
//   gtlua build <main.lua> [--sheet sprites.png] [--map level.png] [--mode7 plane.png] [-o game.gba]
//   gtlua c     <main.lua>                      print the generated C (debugging)
//
// The build lowers Lua -> C (compiler/) and hands the C + the gba-sdk/ runtime to
// the bundled ARM toolchain (arm-gcc / libtonc / maxmod) via compiler/build-gba.mjs,
// producing a .gba ROM that runs in mGBA and on real hardware.

import { readFileSync } from "node:fs";
import path from "node:path";

import { compile, formatDiagnostics } from "../compiler/index.js";

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

// Compile a .lua entry to GBA-targeted C, printing diagnostics. Exits on error.
function compileLuaCli(entry) {
  const source = readFileSync(entry, "utf8");
  const result = compile(source, path.basename(entry), { target: "gba" });
  const warnings = result.diagnostics.filter((d) => d.severity === "warning");
  if (warnings.length) console.error(formatDiagnostics(warnings));
  if (!result.ok) {
    console.error(formatDiagnostics(result.diagnostics.filter((d) => d.severity === "error")));
    process.exit(1);
  }
  return result;
}

const USAGE =
  "usage: gtlua build <main.lua> [--sheet sprites.png] [--map level.png] [--mode7 plane.png] [-o game.gba]\n" +
  "       gtlua c     <main.lua>                      print the generated C (debugging)";

const [, , cmd, ...rest] = process.argv;

if (cmd === "build") {
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
    i !== shIdx && i !== valueOf(shIdx) &&
    i !== mpIdx && i !== valueOf(mpIdx) &&
    i !== m7Idx && i !== valueOf(m7Idx))[0];
  if (!entry) fail(USAGE);
  const out = outPath ?? path.join(path.dirname(path.resolve(entry)),
    path.basename(entry, path.extname(entry)) + ".gba");
  const { buildGba } = await import("../compiler/build-gba.mjs");
  const r = await buildGba(entry, out, { sheetPath, mapPath, mode7Path });
  if (r.issues?.length) {
    for (const iss of r.issues) console.error(`${iss.severity ?? "error"}: ${iss.file ?? ""}:${iss.line ?? ""} ${iss.message}`);
  }
  if (!r.ok) { if (r.log) console.error(r.log); fail("gba-lua: build failed"); }
  console.log(`${r.outPath} (GBA ROM)`);
} else if (cmd === "c") {
  if (!rest[0]) fail("usage: gtlua c <main.lua>");
  process.stdout.write(compileLuaCli(rest[0]).c);
} else {
  fail(USAGE);
}
