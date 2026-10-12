#!/usr/bin/env bash
#
# Extracts an update archive the way Sparkle's installer does and checks the app inside still
# passes code signing, its stapled ticket and Gatekeeper.
#
# Usage: verify-update-archive.sh <archive.tar.xz>

set -euo pipefail

ARCHIVE="${1:?Usage: verify-update-archive.sh <archive.tar.xz>}"

if [ ! -f "$ARCHIVE" ]; then
    echo "::error::$ARCHIVE does not exist"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# SUPipedUnarchiver pipes a .tar.xz into exactly this command, from Sparkle 2.8.1 through 2.10.0.
/usr/bin/tar -zxC "$WORK" < "$ARCHIVE"

ENTRIES="$(find "$WORK" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
APP="$(find "$WORK" -mindepth 1 -maxdepth 1 -name '*.app' -type d)"
if [ "$ENTRIES" -ne 1 ] || [ -z "$APP" ]; then
    echo "::error::$ARCHIVE must hold one app bundle and nothing else"
    ls -la "$WORK"
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"

if ! ASSESSMENT="$(spctl -a -vvv -t exec "$APP" 2>&1)"; then
    echo "::error::Gatekeeper rejects the app extracted from $ARCHIVE"
    echo "$ASSESSMENT"
    exit 1
fi
echo "$ASSESSMENT"
echo "✅ $(basename "$ARCHIVE") extracts to an app that passes codesign, stapler and spctl"
