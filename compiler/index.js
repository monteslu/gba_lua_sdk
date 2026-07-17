// gbalua compiler entry - binds gbalua's identity + builtins to the shared
// luacretro front-end.

import { compile as core, formatDiagnostics } from "luacretro";
import { BUILTINS, CALLBACKS } from "./builtins.js";

export function compile(source, file = "main.lua", opts = {}) {
  return core(source, file, {
    target: "gba",
    sdkName: "gbalua",
    builtins: BUILTINS,
    callbacks: CALLBACKS,
    ...opts,
  });
}

export { formatDiagnostics };
