#!/usr/bin/env node
// gbalua CLI - compile a .lua game to a Game Boy Advance .gba ROM.
//
//   gbalua build <main.lua> [--sheet sprites.png] [--map level.png] [--mode7 plane.png] [-o game.gba]
//   gbalua c     <main.lua>                      print the generated C (debugging)
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
  "usage: gbalua build <main.lua> [--sheet sprites.png] [--map level.png] [--mode7 plane.png]\n" +
  "                    [--music song.xm]... [--soundbank bank.bin] [-o game.gba]\n" +
  "       gbalua run   <main.lua|game.gba>             build + play in a window (bundled mGBA)\n" +
  "       gbalua c     <main.lua>                      print the generated C (debugging)\n" +
  "\n" +
  "  --music is repeatable: music(0) plays the first module, music(1) the second, ...\n" +
  "  (.xm/.mod/.it/.s3m accepted; compiled to a Maxmod soundbank by romdev-maxmod)";

const [, , cmd, ...rest] = process.argv;

if (cmd === "build") {
  // options that take one value; --music may repeat.
  const opts = { musicPaths: [] };
  const positional = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    const val = () => {
      if (i + 1 >= rest.length) fail(`gbalua: ${a} needs a value\n${USAGE}`);
      return rest[++i];
    };
    if (a === "-o") opts.outPath = val();
    else if (a === "--sheet") opts.sheetPath = val();
    else if (a === "--map") opts.mapPath = val();
    else if (a === "--mode7") opts.mode7Path = val();
    else if (a === "--music") opts.musicPaths.push(val());
    else if (a === "--soundbank") opts.soundbankPath = val();
    else if (a.startsWith("-")) fail(`gbalua: unknown option ${a}\n${USAGE}`);
    else positional.push(a);
  }
  const entry = positional[0];
  if (!entry) fail(USAGE);
  if (opts.musicPaths.length && opts.soundbankPath) fail("gbalua: --music and --soundbank are mutually exclusive");
  const out = opts.outPath ?? path.join(path.dirname(path.resolve(entry)),
    path.basename(entry, path.extname(entry)) + ".gba");
  const { buildGba } = await import("../compiler/build-gba.mjs");
  const r = await buildGba(entry, out, {
    sheetPath: opts.sheetPath, mapPath: opts.mapPath, mode7Path: opts.mode7Path,
    musicPaths: opts.musicPaths, soundbankPath: opts.soundbankPath,
  });
  if (r.issues?.length) {
    for (const iss of r.issues) console.error(`${iss.severity ?? "error"}: ${iss.file ?? ""}:${iss.line ?? ""} ${iss.message}`);
  }
  if (!r.ok) { if (r.log) console.error(r.log); fail("gbalua: build failed"); }
  console.log(`${r.outPath} (GBA ROM)`);
} else if (cmd === "run") {
  // build (if given a .lua) then play in a window via the bundled mGBA core.
  const opts = { musicPaths: [] };
  const positional = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    const val = () => {
      if (i + 1 >= rest.length) fail(`gbalua: ${a} needs a value\n${USAGE}`);
      return rest[++i];
    };
    if (a === "--sheet") opts.sheetPath = val();
    else if (a === "--map") opts.mapPath = val();
    else if (a === "--mode7") opts.mode7Path = val();
    else if (a === "--music") opts.musicPaths.push(val());
    else if (a === "--soundbank") opts.soundbankPath = val();
    else if (a.startsWith("-")) fail(`gbalua: unknown option ${a}\n${USAGE}`);
    else positional.push(a);
  }
  const entry = positional[0];
  if (!entry) fail("usage: gbalua run <main.lua|game.gba>");
  let rom;
  if (entry.endsWith(".gba")) rom = entry;
  else {
    rom = path.join(path.dirname(path.resolve(entry)), path.basename(entry, path.extname(entry)) + ".gba");
    const { buildGba } = await import("../compiler/build-gba.mjs");
    const r = await buildGba(entry, rom, {
      sheetPath: opts.sheetPath, mapPath: opts.mapPath, mode7Path: opts.mode7Path,
      musicPaths: opts.musicPaths, soundbankPath: opts.soundbankPath,
    });
    if (r.issues?.length) {
      for (const iss of r.issues) console.error(`${iss.severity ?? "error"}: ${iss.file ?? ""}:${iss.line ?? ""} ${iss.message}`);
    }
    if (!r.ok) { if (r.log) console.error(r.log); fail("gbalua: build failed"); }
  }
  try {
    const { runRom } = await import("./gbalua-run.mjs");
    await runRom(rom);
  } catch (e) {
    if (e && e.code === "SDL_UNAVAILABLE") {
      fail("@kmamal/sdl not available - install it or run the .gba in any GBA emulator (mGBA).");
    }
    fail(`gbalua run: your ROM built fine (${rom}), but a window couldn't open: ${e?.message ?? e}\n` +
         "Load the .gba in any GBA emulator (mGBA).");
  }
} else if (cmd === "c") {
  if (!rest[0]) fail("usage: gbalua c <main.lua>");
  process.stdout.write(compileLuaCli(rest[0]).c);
} else {
  fail(USAGE);
}
