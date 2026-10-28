#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
EXEC_NAME="BrightBar"
APP_NAME="BrightBar"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)
EXEC="$BIN_PATH/$EXEC_NAME"

if [ ! -x "$EXEC" ]; then
    echo "Build did not produce executable at $EXEC" >&2
    exit 1
fi

if [ ! -f "App/Icon/AppIcon.icns" ]; then
    echo "==> Rendering app icon"
    swift App/Icon/make_icon.swift App/Icon
    iconutil -c icns App/Icon/AppIcon.iconset -o App/Icon/AppIcon.icns
fi

APP_DIR="./build/$APP_NAME.app"
echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXEC" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
cp "App/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "App/Icon/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo ""
echo "Built $APP_DIR"
echo "Run with:   open \"$APP_DIR\""
