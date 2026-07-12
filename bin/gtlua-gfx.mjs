// bin/gtlua-gfx.mjs — the `gtlua gfx` sprite-sheet importer/exporter CLI.
//
//   gtlua gfx import <in.png|in.p8|in.gtg> [-o out.gtg]
//        Convert an image (or a PICO-8 cart's __gfx__) into GameTank .gtg
//        sprite quadrants. A source up to 256x256 splits into up to four
//        128x128 quadrant files: out.gtg, out_1.gtg, out_2.gtg, out_3.gtg
//        (the official GameTank name / _1 / _2 / _3 order). Color 0 is
//        transparent; every other pixel maps to the nearest CAPTURE color.
//
//   gtlua gfx export <in.gtg> [-o out.png]
//        Render a .gtg quadrant back to a PNG for editing/previewing.
//
// The .gtg bytes are byte-for-byte the official GameTank SDK format (see
// compiler/gfx.mjs + docs/GRAPHICS.md), so art round-trips with real GameTank
// tooling and existing .gtg assets load unchanged.

import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { toGtg, gtgToPng, gtgNames, QUADRANT_BYTES } from "../compiler/gfx.mjs";

function die(msg) {
  process.stderr.write(`gtlua gfx: ${msg}\n`);
  process.exit(1);
}

function parseIO(rest) {
  const oIdx = rest.indexOf("-o");
  const out = oIdx !== -1 ? rest[oIdx + 1] : undefined;
  const input = rest.filter((a, i) => i !== oIdx && i !== oIdx + 1)[0];
  return { input, out };
}

export function gfxCli(rest) {
  const sub = rest[0];
  const { input, out } = parseIO(rest.slice(1));

  if (sub === "import") {
    if (!input) die("usage: gtlua gfx import <in.png|in.p8|in.gtg> [-o out.gtg]");
    let res;
    try {
      res = toGtg(readFileSync(input), input);
    } catch (e) {
      die(e.message);
    }
    const base = out || input.replace(/\.[^.]+$/, ".gtg");
    const names = gtgNames(base, res.quadrants.length);
    names.forEach((name, i) => writeFileSync(name, res.quadrants[i]));
    const dims = `${res.width}x${res.height}`;
    if (names.length === 1) {
      process.stdout.write(`${names[0]}  (${dims}, ${QUADRANT_BYTES} bytes)\n`);
    } else {
      process.stdout.write(
        `${dims} sheet -> ${names.length} quadrants:\n  ${names.join("\n  ")}\n`);
    }
    return;
  }

  if (sub === "export") {
    if (!input) die("usage: gtlua gfx export <in.gtg> [-o out.png]");
    let png;
    try {
      const gtg = readFileSync(input);
      if (gtg.length < QUADRANT_BYTES) die(`${input} is ${gtg.length} bytes; a .gtg quadrant is ${QUADRANT_BYTES}`);
      png = gtgToPng(gtg);
    } catch (e) {
      die(e.message);
    }
    const outPath = out || input.replace(/\.gtg$/i, ".png").replace(/(\.png)?$/i, ".png");
    writeFileSync(outPath, png);
    process.stdout.write(`${outPath}  (128x128 PNG)\n`);
    return;
  }

  die("usage: gtlua gfx import <in.png|in.p8|in.gtg> [-o out.gtg]\n" +
      "       gtlua gfx export <in.gtg> [-o out.png]");
}
