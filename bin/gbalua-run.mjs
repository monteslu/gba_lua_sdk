// gbalua-run.mjs - play a .gba in a window via the shared romdev SDL host.
//
// Thin shim over romdev-core-runner (the one SDL host in the ecosystem). There
// is no romdev-core-mgba package: the mGBA libretro core ships inside
// romdev-platform-gba (already a build dep), so we resolve its wasm via the
// package's ./wasm/* export and hand runRom a { jsPath, wasmPath } pair.
//
// Standard GBA pad: arrows = d-pad, Z = B, X = A, Enter = START,
// RShift/Backspace = SELECT, Q = L, W = R. If @kmamal/sdl isn't installed the
// runner throws { code:"SDL_UNAVAILABLE" }; we re-throw for the CLI fallback.

import { fileURLToPath } from "node:url";
import { runRom as runRomInWindow } from "romdev-core-runner";

const jsPath = fileURLToPath(import.meta.resolve("romdev-platform-gba/wasm/mgba_libretro.js"));
const wasmPath = fileURLToPath(import.meta.resolve("romdev-platform-gba/wasm/mgba_libretro.wasm"));

// Standard GBA pad -> libretro RetroPad bit (see romdev-core-runner bitToName).
const keyMap = { up: 4, down: 5, left: 6, right: 7, z: 0, x: 8, return: 3, rshift: 2, backspace: 2, q: 10, w: 11 };
const buttonMap = { dpadUp: 4, dpadDown: 5, dpadLeft: 6, dpadRight: 7, a: 0, b: 8, back: 2, guide: 2, start: 3, leftShoulder: 10, rightShoulder: 11 };

export async function runRom(romPath, opts = {}) {
  const session = await runRomInWindow(romPath, {
    core: { jsPath, wasmPath }, platform: "gba", keyMap, buttonMap, scale: 3, ...opts,
  });
  await session.closed;
}
