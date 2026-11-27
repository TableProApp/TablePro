#!/usr/bin/env bash
#
# Checks the AppKit behavior SidebarOutlineView and WorkspacePaneHost rely on: a source list that takes focus inside
# its own move into a key window stays grey, and a refusing initial first responder hands first focus to the next key
# view unless that view names none before the window is on screen. Run on a new macOS release. It opens and closes a
# few windows of its own, so leave the Mac alone for the few seconds it takes.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/SidebarFocusProbe.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIdentifier</key><string>com.TablePro.probes.sidebar-focus</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
swiftc -swift-version 5 -O "$HERE/sidebar-focus-probe.swift" -o "$APP/Contents/MacOS/probe"

OUT="$WORK/out.txt"
open -W "$APP" --args "$OUT"
cat "$OUT"

expect() {
    grep -q -- "$1" "$OUT" || {
        echo "FAIL: expected a line matching: $1" >&2
        exit 1
    }
}
expect "active=true"
expect "first-focus plain: key=true atShow=field"
expect "first-focus none-until-visible: key=true atShow=window tabFromEmpty=field"
expect "emphasis inside-move: key=true firstResponderIsList=true rowEmphasized=false"
expect "emphasis deferred: key=true firstResponderIsList=true rowEmphasized=true"
echo "PASS"
