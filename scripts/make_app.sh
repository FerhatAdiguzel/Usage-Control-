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

# Ad-hoc sign so WebKit / keychain-backed cookie storage works locally.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "✅ Built $APP_DIR"
echo "   Run with: open \"$APP_DIR\"   (or ./build/${APP_NAME}.app/Contents/MacOS/${APP_NAME})"
