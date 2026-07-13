// bench.mjs - micro-benchmark harness for gt-lua SDK functions.
//
// Measures EXACT main-CPU cycles for a call via in-frame cycle MARKERS:
//   _draw runs `gt.mark(1); <call×reps>; gt.mark(2)`. The libretro core
//   (GT_PROFILE build) snapshots the cumulative cycle counter on every write to
//   GT_MARK_ADDR ($1000), so the delta between a mark-1 and its following mark-2
//   is the exact cost of the bracketed code. We collect the delta from several
//   frames and take the MEDIAN (robust against the odd NMI landing mid-window).
//
//   per-call = (median(mark2 - mark1) - markOverhead) / reps
//
// markOverhead = the cost of the two gt.mark calls + the empty reps loop,
// measured once from a baseline cart with an empty body. Subtracting it leaves
// just the function under test.
//
// The emulator runs a FIXED cycle budget per retro_run and _draw executes only
// ~once per ~1.8 retro_run calls (the CPU idles in gt_endframe's vsync wait), so
// we run ~60 frames to collect a dozen+ clean samples.
//
//   import { bench } from "./bench.mjs"
//   const r = await bench({ name, setup, call, reps })

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";

const SDK = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
// The GT_PROFILE core build (exports gt_mark's cycle-marker ring). Override with
// GT_BENCH_CORE for a different build path.
const CORE = process.env.GT_BENCH_CORE ||
  path.join(SDK, "..", "gametank-libretro", "gametank_libretro_prof.js");
const SHEET = path.join(SDK, "bench/bench-sheet.gtg");
const MARK_ADDR = 0x1000;

function cartSrc({ setup = "", call = "", reps = 1, globals = "" }) {
  return `${globals}
function _init()
${ind(setup)}
end
function _update60()
end
function _draw()
  gt.mark(1)
  for _bi = 1, ${reps} do
${ind(call, 4)}
  end
  gt.mark(2)
end
`;
}
function ind(s, n = 2) {
  const pad = " ".repeat(n);
  return (s || "").split("\n").map((l) => (l.trim() ? pad + l : l)).join("\n");
}

// Look up a global's RAM address from the build's .lbl map (cc65 emits
// `al <hexaddr> .<sym>`). gt-lua globals are named `gtl_<name>`. Returns the
// unbanked address (bank 0), or null.
export function globalAddr(buildDir, name) {
  const lbl = path.join(buildDir, "build", "main.lbl");
  let txt;
  try { txt = readFileSync(lbl, "utf8"); } catch { return null; }
  const m = txt.match(new RegExp(`^al\\s+([0-9A-Fa-f]{6})\\s+\\.(?:_)?gtl_${name}\\b`, "m"));
  return m ? parseInt(m[1], 16) & 0x1fff : null;
}

export function buildCart(src, num8 = true) {
  const dir = mkdtempSync(path.join(tmpdir(), "gtbench-"));
  const lua = path.join(dir, "main.lua");
  const out = path.join(dir, "b.gtr");
  writeFileSync(lua, src);
  execFileSync("node", [
    path.join(SDK, "bin/gtlua.js"), "build", lua,
    "--sheet", SHEET, ...(num8 ? ["--num8"] : []), "-o", out,
  ], { stdio: ["ignore", "ignore", "pipe"] });
  return { out, dir };
}

let MOD = null;
async function newCore() {
  if (!MOD) MOD = (await import(CORE)).default;
  const M = await MOD();
  // env cb from gtlr_run.mjs: 0 for unhandled queries (returning 1 for all lies
  // to the core about capabilities and wedges the frame loop).
  const envCb = M.addFunction((cmd) => {
    const id = (cmd >>> 0) & 0xff;
    return (id === 10 || id === 3 || id === 27) ? 1 : 0;
  }, "iii");
  M._retro_set_environment(envCb);
  M._retro_set_video_refresh(M.addFunction(() => {}, "viiii"));
  M._retro_set_input_poll(M.addFunction(() => {}, "v"));
  M._retro_set_input_state(M.addFunction(() => 0, "iiiii"));
  M._retro_set_audio_sample(M.addFunction(() => {}, "vii"));
  M._retro_set_audio_sample_batch(M.addFunction((ptr, n) => n, "iii"));
  M._retro_init();
  return M;
}

function median(a) {
  if (!a.length) return null;
  const s = [...a].sort((x, y) => x - y);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// Run a cart for `frames` frames, return the per-frame (mark1 -> mark2) deltas.
// resultAddr (optional): a RAM address to read back as a signed 16-bit value.
async function collectDeltas(cartPath, frames = 70, resultAddr = null) {
  const M = await newCore();
  M._gt_marker_config(MARK_ADDR);
  const rom = readFileSync(cartPath);
  const p = M._malloc(rom.length); M.HEAPU8.set(rom, p);
  const info = M._malloc(16);
  M.HEAP32[(info >> 2)] = 0; M.HEAP32[(info >> 2) + 1] = p;
  M.HEAP32[(info >> 2) + 2] = rom.length; M.HEAP32[(info >> 2) + 3] = 0;
  if (!M._retro_load_game(info)) throw new Error("load failed");
  M._gt_marker_config(MARK_ADDR); // re-arm after load
  for (let i = 0; i < frames; i++) M._retro_run();
  const n = M._gt_marker_count();
  const marks = [];
  for (let i = 0; i < n; i++) {
    const lo = M._gt_marker_cyc_lo(i) >>> 0, hi = M._gt_marker_cyc_hi(i) >>> 0;
    marks.push({ v: M._gt_marker_value(i), c: hi * 4294967296 + lo });
  }
  // pair each mark-1 with the immediately-following mark-2
  const deltas = [];
  for (let i = 0; i + 1 < marks.length; i++) {
    if (marks[i].v === 1 && marks[i + 1].v === 2) deltas.push(marks[i + 1].c - marks[i].c);
  }
  const ram = M._retro_get_memory_data(2);
  const ramSnap = ram ? Uint8Array.from(M.HEAPU8.subarray(ram, ram + 0x2000)) : null;
  const vp = M._gt_vram_ptr ? M._gt_vram_ptr() : 0;
  const vram = vp ? Uint8Array.from(M.HEAPU8.subarray(vp, vp + 0x8000)) : null;
  // optional 16-bit little-endian readback of a global (a math result, etc.),
  // signed (fixed-point / int deltas are often negative)
  let result = null;
  if (resultAddr != null && ramSnap) {
    const u = ramSnap[resultAddr] | (ramSnap[resultAddr + 1] << 8);
    result = u >= 0x8000 ? u - 0x10000 : u;
  }
  return { deltas, ram: ramSnap, vram, nmarks: n, result };
}

// Baseline shares the EXACT loop+store skeleton, differing only in the RHS
// expression, so subtracting it removes the loop overhead AND the `local q = …`
// store, leaving just the marginal cost of the expression under test.
//   busy:  `local q = <expr>`     base: `local q = 0`
// For statement-form ops (draw calls that return void, e.g. `rectfill(...)`),
// pass exprIsStatement:true and the base is an empty loop body.
const BASE_CACHE = new Map();
async function baseline(reps, globals, setup, frames, isStatement) {
  const key = `${reps}|${globals}|${setup}|${isStatement}`;
  if (BASE_CACHE.has(key)) return BASE_CACHE.get(key);
  const body = isStatement ? "" : "local q = 0";
  const { out, dir } = buildCart(cartSrc({ setup, call: body, reps, globals }));
  let deltas;
  try {
    ({ deltas } = await collectDeltas(out, frames));
  } finally {
    rmSync(dir, { recursive: true, force: true });  // don't leak the mkdtemp build dir
  }
  const v = median(deltas) ?? 0;
  BASE_CACHE.set(key, v);
  return v;
}

// Cycles-per-call for `call`.
//  - Expression form (default): pass `call` as an expression string (e.g.
//    "flr(3.5)"); it's wrapped as `local q = <call>` and diffed against
//    `local q = 0`. Result = pure cost of evaluating the expression.
//  - Statement form (`statement:true`): `call` is a full statement (e.g.
//    "rectfill(10,10,50,50,8)"); diffed against an empty loop body.
// resultGlobal (optional): a gt-lua global name whose 16-bit value is read back
// after the run (for math/int verifiers). The cart must assign it in _draw.
export async function bench({ name = "", setup = "", call, reps = 64, globals = "", frames = 70, statement = false, resultGlobal = null }) {
  const body = statement ? call : `local q = ${call}`;
  let built;
  try {
    built = buildCart(cartSrc({ setup, call: body, reps, globals }));
  } catch (e) {
    const msg = (e.stderr ? Buffer.from(e.stderr).toString() : e.message).split("\n").filter((l) => /Error|error/.test(l)).slice(0, 2).join(" | ");
    return { name, perCall: null, reps, buildError: msg || "build failed", samples: 0, nmarks: 0 };
  }
  const resultAddr = resultGlobal ? globalAddr(built.dir, resultGlobal) : null;
  let busy;
  try {
    busy = await collectDeltas(built.out, frames, resultAddr);
  } finally {
    rmSync(built.dir, { recursive: true, force: true });  // don't leak the mkdtemp build dir
  }
  const base = await baseline(reps, globals, setup, frames, statement);
  const busyMed = median(busy.deltas);
  const perCall = busyMed == null ? null : (busyMed - base) / reps;
  return {
    name, perCall, reps,
    busyMedian: busyMed, baseMedian: base,
    samples: busy.deltas.length, nmarks: busy.nmarks,
    ram: busy.ram, vram: busy.vram, result: busy.result,
  };
}

// CLI: node bench.mjs <name> '<setup>' '<call-expr>' [reps] [--stmt]
if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2);
  const statement = argv.includes("--stmt");
  const [name, setup, call, reps] = argv.filter((a) => a !== "--stmt");
  const r = await bench({ name: name || "t", setup: setup || "", call: call || "flr(3.5)", reps: reps ? +reps : 64, statement });
  if (r.perCall == null) { console.error(`${r.name}: NO SAMPLES (nmarks=${r.nmarks})`); process.exit(1); }
  console.log(`${r.name}: ${r.perCall.toFixed(2)} cyc/call  (busyMed=${r.busyMedian}, base=${r.baseMedian}, reps=${r.reps}, samples=${r.samples})`);
}
