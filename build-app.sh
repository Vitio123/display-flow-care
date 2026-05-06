#!/bin/bash
# Builds DisplayFlow.app from the Swift package and ad-hoc-signs it so
# macOS can attribute camera permission to a stable bundle identifier.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Display Flow"
BUNDLE_ID="com.longwave.displayflow"
BUILD_DIR=".build/release"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"

echo "==> Building (release)..."
swift build -c release

echo "==> Assembling bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/DisplayFlow" "$APP_DIR/Contents/MacOS/DisplayFlow"
cp Info.plist "$APP_DIR/Contents/Info.plist"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR"

echo
echo "Built: $APP_DIR"
echo "Run with:  open \"$APP_DIR\""
