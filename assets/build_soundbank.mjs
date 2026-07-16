// build_soundbank.mjs — compile music.xm → soundbank.bin (+ soundbank_ids.h)
// using romdev's pure-JS mmutil port (byte-identical to devkitPro mmutil).
//
//   node build_soundbank.mjs
//
// Regenerate music.xm first (node make_music_xm.mjs) if you changed the tune.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
// romdev-maxmod (a dependency) is the pure-JS mmutil port.
import { soundbankFromModule } from "romdev-maxmod";

const __dirname = dirname(fileURLToPath(import.meta.url));

const xmBytes = readFileSync(join(__dirname, "music.xm"));
// name 'chiptune' keeps the generated define MOD_CHIPTUNE = 0 so music(0) and
// the existing soundbank_ids.h contract are unchanged (drop-in replacement).
const { bin, header } = soundbankFromModule(new Uint8Array(xmBytes), { name: "chiptune" });

writeFileSync(join(__dirname, "soundbank.bin"), Buffer.from(bin));
writeFileSync(join(__dirname, "soundbank_ids.h"), header);
console.log(`wrote soundbank.bin (${bin.length} B) + soundbank_ids.h`);
console.log(header.trim());
