#!/bin/bash
# Support/Icon/AppIcon-source.png から Support/Icon/AppIcon.icns を作る。アイコンを差し替えたら実行する。
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="Support/Icon/AppIcon-source.png"
OUTPUT="Support/Icon/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift scripts/pad-icon.swift "$SOURCE" "$WORK/icon-1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "created: $OUTPUT"
