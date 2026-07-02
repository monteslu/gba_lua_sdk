#!/bin/sh
# Build the cc65 toolchain into tools/cc65/ (same convention as the
# GameTank C SDK). Needs git, make, and a C compiler.
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/tools/cc65-src"
DEST="$REPO/tools/cc65"

if [ -x "$DEST/bin/cc65" ]; then
    echo "cc65 already installed at $DEST"
    exit 0
fi

mkdir -p "$REPO/tools"
if [ ! -d "$SRC" ]; then
    git clone --depth 1 https://github.com/cc65/cc65.git "$SRC"
fi

make -C "$SRC" -j"$(nproc 2>/dev/null || echo 4)" bin
make -C "$SRC" -j"$(nproc 2>/dev/null || echo 4)" lib

mkdir -p "$DEST/bin" "$DEST/lib"
cp "$SRC/bin/cc65" "$SRC/bin/ca65" "$SRC/bin/ld65" "$DEST/bin/"
cp "$SRC/lib/none.lib" "$DEST/lib/"
cp -r "$SRC/asminc" "$DEST/asminc"

echo "installed: $DEST ($("$DEST/bin/cc65" --version 2>&1))"
