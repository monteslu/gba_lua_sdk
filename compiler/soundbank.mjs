// soundbank.mjs — tracker modules -> a Maxmod soundbank, in one call.
// BROWSER-SAFE: romdev-maxmod is pure JS; bytes in, bytes out.
//
// Song order = array order: music(0) plays modules[0], music(1) modules[1], …
// (the Maxmod module id IS the position in the soundbank).

import { parseModule, writeSoundbank, detectModuleFormat } from "romdev-maxmod";

/**
 * Compile tracker modules (.xm/.mod/.it/.s3m) into a GBA Maxmod soundbank.
 * @param {Array<{name:string, bytes:Uint8Array}>} modules
 * @returns {{bin: Uint8Array, header: string}} soundbank.bin + the MOD_* defines
 */
export function buildSoundbank(modules) {
  if (!modules.length) throw new Error("buildSoundbank: no modules given");
  const mods = [];
  for (const m of modules) {
    const fmt = detectModuleFormat(m.bytes);
    if (!fmt) throw new Error(`buildSoundbank: ${m.name}: not a .xm/.mod/.it/.s3m module`);
    mods.push(parseModule(m.bytes, { format: fmt }));
  }
  const moduleMeta = modules.map((m) => ({ filename: m.name.replace(/\.[^.]+$/, "") }));
  return writeSoundbank(mods, [], { moduleMeta });
}

export { detectModuleFormat };
