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

# Install to ~/Applications so the app is findable from Spotlight, Launchpad,
# and Finder without ever opening a terminal. ~/Applications doesn't need
# admin privileges and is indexed by macOS just like /Applications.
mkdir -p "$HOME/Applications"
INSTALLED_APP="$HOME/Applications/${APP_NAME}.app"
echo "==> Installing to $INSTALLED_APP"
rm -rf "$INSTALLED_APP"
cp -R "$APP_DIR" "$INSTALLED_APP"

echo
echo "Built:     $APP_DIR"
echo "Installed: $INSTALLED_APP"
echo
echo "You can now find Display Flow in Spotlight (⌘Space) or Launchpad."
