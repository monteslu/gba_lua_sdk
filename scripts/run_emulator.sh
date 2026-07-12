#!/usr/bin/env bash
# Launch a GameTank emulator with a .gtr ROM file.
# Resolution order: GAMETANK_EMULATOR env var, then `gte` on PATH, then
# `GameTankEmulator` on PATH.  https://github.com/clydeshaffer/GameTankEmulator

set -e

rom="$1"
if [ -z "$rom" ]; then
  echo "usage: run_emulator.sh <game.gtr>" >&2
  exit 2
fi

if [ -n "$GAMETANK_EMULATOR" ]; then
  emu="$GAMETANK_EMULATOR"
elif command -v gte >/dev/null 2>&1; then
  emu="gte"
elif command -v GameTankEmulator >/dev/null 2>&1; then
  emu="GameTankEmulator"
else
  echo "ERROR: no GameTank emulator found." >&2
  echo "Set GAMETANK_EMULATOR to your emulator, or put gte / GameTankEmulator on PATH." >&2
  echo "Emulator: https://github.com/clydeshaffer/GameTankEmulator" >&2
  exit 1
fi

exec "$emu" "$rom"
