#!/usr/bin/env bash
set -euo pipefail

# System Settings pane addresses used by Settings > Sync.
#
# SyncSettingsView opens the iCloud pane for "Manage Storage…" and the Apple Account pane for
# "Open System Settings…". Apple documents neither address; Notes and Freeform use them. This opens
# each one and reads the title of the window System Settings shows, so a macOS release that moves a
# pane is caught before a user lands on the wrong page. It drives the UI: System Settings opens and
# is quit afterwards, and System Events needs Accessibility access for the terminal running it.
#
# Usage: scripts/probes/check-system-settings-icloud-panes.sh

cd "$(dirname "$0")/../.."

SOURCE="TablePro/Views/Settings/SyncSettingsView.swift"

if pgrep -x "System Settings" >/dev/null; then
    echo "System Settings is open. Quit it first so each address starts from a fresh window." >&2
    exit 2
fi

check() {
    local address="$1" expected="$2"
    grep -qF "\"$address\"" "$SOURCE" || { echo "FAIL: $SOURCE no longer opens $address" >&2; return 1; }
    open "$address"
    sleep 4
    local title
    # The title spells "Apple Account" with a no-break space.
    title="$(osascript -e 'tell application "System Events" to tell process "System Settings" to get name of window 1' | sed $'s/\xc2\xa0/ /g')"
    osascript -e 'tell application "System Settings" to quit' >/dev/null
    sleep 1
    if [[ "$title" == "$expected" ]]; then
        echo "ok: $address opens \"$title\""
    else
        echo "FAIL: $address opens \"$title\", expected \"$expected\"" >&2
        return 1
    fi
}

echo "macOS $(sw_vers -productVersion)"
check "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings*AppleIDSettings?iCloud" "iCloud"
check "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings" "Apple Account"
