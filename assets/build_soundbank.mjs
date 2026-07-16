// build_soundbank.mjs — compile music.xm → soundbank.bin (+ soundbank_ids.h)
// using romdev's pure-JS mmutil port (byte-identical to devkitPro mmutil).
//
//   node build_soundbank.mjs
//
// Regenerate music.xm first (node make_music_xm.mjs) if you changed the tune.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";

const __dirname = dirname(fileURLToPath(import.meta.url));

// romdev-maxmod is the pure-JS mmutil (lives in the romdev monorepo; we only
// READ from it). Resolve it from romdev's node_modules / workspace.
const require = createRequire(import.meta.url);
let soundbankFromModule;
const candidates = [
  "romdev-maxmod",
  join(process.env.HOME || "", "code/cliemu/romdev/packages/romdev-maxmod/src/index.js"),
];
for (const c of candidates) {
  try { ({ soundbankFromModule } = await import(c)); break; } catch { /* try next */ }
}
if (!soundbankFromModule) {
  throw new Error("could not load romdev-maxmod (the pure-JS mmutil). Ensure the romdev repo is at ~/code/cliemu/romdev.");
}

const xmBytes = readFileSync(join(__dirname, "music.xm"));
// name 'chiptune' keeps the generated define MOD_CHIPTUNE = 0 so music(0) and
// the existing soundbank_ids.h contract are unchanged (drop-in replacement).
const { bin, header } = soundbankFromModule(new Uint8Array(xmBytes), { name: "chiptune" });

writeFileSync(join(__dirname, "soundbank.bin"), Buffer.from(bin));
writeFileSync(join(__dirname, "soundbank_ids.h"), header);
console.log(`wrote soundbank.bin (${bin.length} B) + soundbank_ids.h`);
console.log(header.trim());
