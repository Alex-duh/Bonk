#!/bin/bash
# Convert a square PNG (ideally 1024×1024) into a .icns app icon.
# Usage: make_icns.sh input.png output.icns
set -euo pipefail

SRC="$1"
OUT="$2"
TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP"

for size in 16 32 128 256 512; do
    sips -z $size $size             "$SRC" --out "$TMP/icon_${size}x${size}.png"      >/dev/null
    sips -z $((size*2)) $((size*2)) "$SRC" --out "$TMP/icon_${size}x${size}@2x.png"   >/dev/null
done

iconutil -c icns "$TMP" -o "$OUT"
rm -rf "$(dirname "$TMP")"
echo "Icon written to $OUT"
