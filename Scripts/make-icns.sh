#!/usr/bin/env bash
# Render the app icon and build Resources/AppIcon.icns (all macOS sizes).
# Re-run after editing Scripts/make-icon.swift to regenerate the icon.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
MASTER="$TMP/icon.png"
ICONSET="$TMP/AppIcon.iconset"
OUT="Resources/AppIcon.icns"
mkdir -p "$ICONSET"

echo "Rendering master 1024x1024..."
swift Scripts/make-icon.swift "$MASTER"

echo "Building iconset..."
gen() { sips -z "$2" "$2" "$MASTER" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png 16
gen icon_16x16@2x.png 32
gen icon_32x32.png 32
gen icon_32x32@2x.png 64
gen icon_128x128.png 128
gen icon_128x128@2x.png 256
gen icon_256x256.png 256
gen icon_256x256@2x.png 512
gen icon_512x512.png 512
gen icon_512x512@2x.png 1024

echo "Packing $OUT..."
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$TMP"
echo "Wrote $OUT"
