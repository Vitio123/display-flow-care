#!/bin/bash
# Build (if needed) and launch Display Flow.app
set -euo pipefail
cd "$(dirname "$0")"

APP=".build/release/Display Flow.app"

if [ ! -d "$APP" ]; then
    ./build-app.sh
fi

open "$APP"
echo "Display Flow launched. Look for the icon in the menu bar (top-right)."
