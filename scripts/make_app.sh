#!/bin/bash
# Builds UsageMonitor and wraps the executable into a proper .app bundle so it
# runs as a menu-bar agent (LSUIElement) with a persistent WebKit cookie store.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="UsageMonitor"
BUILD_DIR=".build/${CONFIG}"
APP_DIR="build/${APP_NAME}.app"

echo "▶ Building ($CONFIG)…"
swift build -c "$CONFIG"

echo "▶ Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so WebKit / keychain-backed cookie storage works locally.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

# Tek kurulu kopya /Applications altında dursun; build/ sadece ara çıktı.
INSTALL_DIR="/Applications/${APP_NAME}.app"
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"
rm -rf "$APP_DIR"

echo "✅ Kuruldu: $INSTALL_DIR"
echo "   Çalıştır: open \"$INSTALL_DIR\""
