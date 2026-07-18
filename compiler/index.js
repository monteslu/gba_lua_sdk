// gbalua compiler entry - binds gbalua's identity + builtins to the shared
// luacretro front-end.

import { compile as core, formatDiagnostics } from "luacretro";
import { BUILTINS, CALLBACKS } from "./builtins.js";

// The GBA target descriptor (arm-gcc / libtonc). Hardware divide, no zero page,
// per-call cName covers every emission (no final rename). Its own SDK owns it.
const TARGET = {
  caps: {
    zpFastcall: false, zpUserFn: true, fixedZp: false,
    banked: false, nativeDiv: true, colorBake: false, framebuffer: true,
    prefix: "gba", finalRename: false,
  },
  harness: {
    signature: "int main(void)",
    init: ["gba_init"],
    onAudio: null, onMusic: null, onFps30: null,
    loopTop: ["gba_vsync"], frameEnd: "gba_endframe",
    fps30Style: "runtime", returns: true, includes: ["gba_api.h"],
  },
};

export function compile(source, file = "main.lua", opts = {}) {
  return core(source, file, {
    sdkName: "gbalua",
    builtins: BUILTINS,
    callbacks: CALLBACKS,
    ...opts,
    target: TARGET,   // the SDK OWNS its target - not overridable by callers
  });
}

export { formatDiagnostics };
