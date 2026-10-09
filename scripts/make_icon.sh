#!/bin/bash
# Regenerates Resources/AppIcon.icns from a square master PNG (1024x1024).
#   ./scripts/make_icon.sh [path/to/logo.png]
# Defaults to Resources/AppIcon-1024.png
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-Resources/AppIcon-1024.png}"
[ -f "$SRC" ] || { echo "❌ Kaynak bulunamadı: $SRC"; exit 1; }

TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP"

for s in 16 32 128 256 512; do
  sips -z $s $s           "$SRC" --out "$TMP/icon_${s}x${s}.png"    >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$TMP/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$TMP" -o Resources/AppIcon.icns
echo "✅ Resources/AppIcon.icns güncellendi ($SRC)"
echo "   Uygulamaya işlemek için: ./scripts/make_app.sh"
