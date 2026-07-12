// run.mjs — run the benchmark catalog and print a cycles/call table.
//
//   node bench/run.mjs [category|name] ...   (default: all)
//   node bench/run.mjs draw                   (one category)
//   node bench/run.mjs sqrt sin cos           (specific names)
//   node bench/run.mjs --json out.json        (machine-readable, for delta cmp)
//
// Each row also runs the entry's verify() (if any) and flags a ✗ on mismatch —
// so a perf run doubles as a smoke test of correctness.

import { writeFileSync } from "node:fs";
import { bench } from "./harness.mjs";
import { CATALOG } from "./catalog.mjs";

const argv = process.argv.slice(2);
let jsonOut = null;
const ji = argv.indexOf("--json");
if (ji !== -1) { jsonOut = argv[ji + 1]; argv.splice(ji, 2); }
const filters = argv;

function selected(e) {
  if (!filters.length) return true;
  return filters.includes(e.name) || filters.includes(e.category);
}

const rows = [];
for (const e of CATALOG.filter(selected)) {
  const r = await bench({
    name: e.name, setup: e.setup || "", call: e.call,
    reps: e.reps || 64, globals: e.globals || "", statement: !!e.statement,
    resultGlobal: e.resultGlobal || null, frames: e.frames || 70,
  });
  let ok = "—";
  if (e.verify && !r.buildError) {
    const v = e.verify({ ram: r.ram, vram: r.vram }, r);
    ok = v === true ? "✓" : `✗ ${v}`;
  }
  rows.push({ ...r, category: e.category, signal: e.signal || "ok", note: e.note || "", ok });
}

// table
const wName = Math.max(4, ...rows.map((r) => r.name.length));
const wCat = Math.max(8, ...rows.map((r) => r.category.length));
const hdr = `${"NAME".padEnd(wName)}  ${"CATEGORY".padEnd(wCat)}  ${"CYC/CALL".padStart(9)}  ${"REPS".padStart(4)}  ${"SMPL".padStart(4)}  SIGNAL  VERIFY`;
console.log(hdr);
console.log("-".repeat(hdr.length));
const VSYNC = 59660; // cycles per vsync — anything above is a multi-frame op
for (const r of rows) {
  const cyc = r.buildError ? "BUILD-ERR" : r.perCall == null ? "NO-SAMP" : r.perCall.toFixed(1);
  const sig = r.signal === "low" ? "low " : "ok  ";
  // ops that exceed a vsync are blocking/multi-frame; show their frame span so
  // the raw cycle number isn't read as "per-call CPU work" (it includes the
  // blit-drain / vsync-wait the op blocks on).
  const span = (!r.buildError && r.perCall > VSYNC) ? ` (~${(r.perCall / VSYNC).toFixed(1)} vsyncs — BLOCKING)` : "";
  const tail = r.buildError ? `  ! ${r.buildError}` : (r.note ? "  # " + r.note : "");
  console.log(
    `${r.name.padEnd(wName)}  ${r.category.padEnd(wCat)}  ${cyc.padStart(9)}  ${String(r.reps).padStart(4)}  ${String(r.samples).padStart(4)}  ${sig}    ${r.ok}${span}${tail}`
  );
}

if (jsonOut) {
  const out = rows.map((r) => ({ name: r.name, category: r.category, perCall: r.perCall, reps: r.reps, samples: r.samples, signal: r.signal, verify: r.ok }));
  writeFileSync(jsonOut, JSON.stringify(out, null, 2));
  console.log(`\nwrote ${jsonOut}`);
}
