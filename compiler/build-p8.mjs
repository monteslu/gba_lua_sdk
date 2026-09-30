// build-p8.mjs - build a real PICO-8 cart (.p8 / .p8.png, or a .lua using the
// full PICO-8 language) to a .gba ROM through luacretro's dynamic tier.
//
//   cart --luacretro dynamic tier--> C
//   C + luacretro runtime + gba-sdk/lc_gba.c --romdev-platform-gba buildGbaC--> .gba
//
// Unlike `gbalua build main.lua` (the static PICO-8-flavored dialect with the
// GBA extras), this runs unmodified PICO-8 carts: 128x128 in the middle of the
// screen, PICO-8 audio, cartdata in SRAM.

import { existsSync, readFileSync } from "node:fs";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { compileCart, RUNTIME_SOURCES, RUNTIME_HEADERS } from "luacretro/dyn";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SDK_DIR = path.resolve(__dirname, "..", "gba-sdk");
const RUNTIME_DIR = path.dirname(fileURLToPath(import.meta.resolve("luacretro/runtime/lc.h")));

// cc1 flags: buildGbaC's defaults plus the runtime placement/config defines
const CC1 = ["-O2", "-mthumb", "-mthumb-interwork", "-ffunction-sections", "-fdata-sections", "-Wall",
  "-Wno-unused-parameter", "-DLC_P8_MEMSIZE=0x10000u", "-DLC_BIGDATA=__attribute__((section(\".sbss\")))",
  "-DLC_CO_REGION=16384", "-DLC_CO_VREGION=1024",
  // the fast synth (luacretro lc_p8snd_fast.c): output straight at the DirectSound
  // rate, per-sample and per-block code in IWRAM as ARM, walk tables in EWRAM
  "-DLC_P8SND_FAST", "-DLC_P8SND_RATE=13379",
  "-DLC_P8SND_HOT=__attribute__((section(\".iwram\"), long_call, target(\"arm\")))",
  "-DLC_P8SND_BSS=__attribute__((section(\".sbss\")))"];

/**
 * @param {string} cartPath
 * @param {string} outPath
 * @param {{debugLines?: boolean, cflags?: string[], audio?: boolean}} [opts]
 */
export async function buildGbaCart(cartPath, outPath, opts = {}) {
  const bytes = new Uint8Array(await readFile(cartPath));
  const r = compileCart(bytes, path.basename(cartPath), { debugLines: opts.debugLines, resolveInclude: (p) => { const f = path.resolve(path.dirname(cartPath), p); return existsSync(f) ? readFileSync(f) : null; } });
  if (!r.ok) return { ok: false, stage: "compile", diagnostics: r.diagnostics };
  const sources = { "cart.c": r.c, "lc_gba.c": await readFile(path.join(SDK_DIR, "lc_gba.c"), "utf8") };
  for (const s of RUNTIME_SOURCES) sources[s] = await readFile(path.join(RUNTIME_DIR, s), "utf8");
  const headers = {};
  for (const h of RUNTIME_HEADERS) headers[h] = await readFile(path.join(RUNTIME_DIR, h), "utf8");
  const { buildGbaC, parseBuildLog } = await import("romdev-platform-gba");
  const b = await buildGbaC({
    sources, headers, runtime: "libtonc",
    cc1Options: [...CC1, ...(opts.audio === false ? ["-DGBALUA_AUDIO=0"] : []), ...(opts.cflags ?? [])],
  });
  if (!b.ok || !b.binary) return { ok: false, stage: "build", log: b.log, issues: parseBuildLog(b.log || ""), c: r.c };
  if (outPath) {
    const abs = path.resolve(outPath);
    await mkdir(path.dirname(abs), { recursive: true });
    await writeFile(abs, b.binary);
  }
  return { ok: true, binary: b.binary, outPath: outPath && path.resolve(outPath), c: r.c, map: b.symbols };
}
