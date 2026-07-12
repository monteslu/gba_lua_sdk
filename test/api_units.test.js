// api_units.test.js — one unit test per callable API name.
//
// Drives each catalog entry's `call` through the real libretro core and asserts
// its `verify(state)` (pixel/RAM output). This is the CORRECTNESS half of the
// per-function sweep; bench/run.mjs is the PERF half. Entries flagged
// signal:"low" (state-setters, sheet/GRAM writes with no cheap in-frame
// readback) have no verify() and are asserted only to build + run without crash.
//
// Requires the GT_PROFILE core build (the cycle-marker export). Skipped with a
// clear message if that core isn't present.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SDK = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const CORE = process.env.GT_BENCH_CORE ||
  path.join(SDK, "..", "gametank-libretro", "gametank_libretro.js");

const haveCore = existsSync(CORE);
const { bench } = haveCore ? await import("../bench/harness.mjs") : { bench: null };
const { CATALOG } = await import("../bench/catalog.mjs");

for (const e of CATALOG) {
  test(`${e.category}/${e.name}`, { skip: haveCore ? false : `GT_PROFILE core not built at ${CORE}` }, async () => {
    const r = await bench({
      name: e.name, setup: e.setup || "", call: e.call,
      reps: e.reps || 8, globals: e.globals || "", statement: !!e.statement,
      resultGlobal: e.resultGlobal || null, frames: e.frames || 70,
    });
    assert.equal(r.buildError, undefined, `build failed: ${r.buildError}`);
    // it ran if we collected marker samples (the CPU reached _draw's markers)
    assert.ok(r.samples > 0, `no marker samples — cart never reached _draw (nmarks=${r.nmarks})`);
    if (e.verify) {
      const v = e.verify({ ram: r.ram, vram: r.vram }, r);
      assert.equal(v, true, typeof v === "string" ? v : `${e.name} verify failed`);
    }
  });
}
