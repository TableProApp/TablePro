#!/usr/bin/env bash
set -euo pipefail

# Launch the locally built Debug app for manual testing.
#
# A command-line `xcodebuild build` with CODE_SIGNING_ALLOWED=NO leaves the
# bundle unsigned and without OpenSSL dylibs embedded, so the app dies on launch
# (TablePro.debug.dylib has no signature) and the MySQL plugin fails to load
# (libssl.3/libcrypto.3 missing from rpath). This script patches both so a CLI
# build runs locally:
#   1. copy libssl.3/libcrypto.3 into Contents/Frameworks
#   2. ad-hoc sign the whole bundle
#   3. (re)launch
#
# Usage: scripts/run-local.sh
# Build the project first (xcodebuild build); this only patches the product.
# A clean build fixes the plugin rpath outright, so step 1 is a fallback.

CONFIGURATION="${CONFIGURATION:-Debug}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

APP_PATH="${APP_PATH:-$(ls -dt "$HOME/Library/Developer/Xcode/DerivedData"/TablePro*/Build/Products/"$CONFIGURATION"/TablePro.app 2>/dev/null | head -1)}"

if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
    echo "error: TablePro.app ($CONFIGURATION) not found. Build it first." >&2
    exit 1
fi

echo "App: $APP_PATH"

mkdir -p "$APP_PATH/Contents/Frameworks"
for dylib in libssl.3.dylib libcrypto.3.dylib; do
    src="$REPO_ROOT/Libs/dylibs/$dylib"
    dest="$APP_PATH/Contents/Frameworks/$dylib"
    if [[ -f "$src" ]]; then
        cp "$src" "$dest"
        echo "copied $dylib"
    else
        echo "warning: $src missing, skipped" >&2
    fi
done

codesign --force --deep --sign - "$APP_PATH"
echo "ad-hoc signed"

pkill -f "$APP_PATH/Contents/MacOS/TablePro" 2>/dev/null || true
sleep 1
open "$APP_PATH"
echo "launched"
