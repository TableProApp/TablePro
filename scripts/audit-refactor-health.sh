#!/usr/bin/env bash
set -euo pipefail

# DatabaseType definition gate.
#
# DatabaseType is defined once in TableProCore, and the macOS app keeps one more definition that
# .github/duplicate-contract-baseline.txt lists. Any other `struct DatabaseType` or `enum
# DatabaseType` is a second contract that drifts from the first, so --check fails on it.
#
# Usage:
#   scripts/audit-refactor-health.sh           # list every DatabaseType definition
#   scripts/audit-refactor-health.sh --check   # also exit 1 on one the baseline does not list

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CHECK_MODE=false
case "${1:-}" in
    "") ;;
    --check) CHECK_MODE=true ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 2
        ;;
esac

BASELINE_FILE=".github/duplicate-contract-baseline.txt"
AUTHORITATIVE="Packages/TableProCore/Sources/TableProCoreTypes/DatabaseType.swift"

baseline_paths() {
    [ -f "$BASELINE_FILE" ] || return 0
    sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$BASELINE_FILE" |
        sed -n 's/^databasetype://p'
}

definitions() {
    grep -rlE '^(public )?(struct|enum) DatabaseType[ :<]' --include='*.swift' \
        TablePro Plugins Packages TableProMobile 2> /dev/null | sort -u || true
}

echo "DatabaseType definitions:"
found="$(definitions)"
if [ -z "$found" ]; then
    echo "  none found"
    $CHECK_MODE && exit 1
    exit 0
fi
printf '%s\n' "$found" | sed 's/^/  /'

$CHECK_MODE || exit 0

allowed="$(printf '%s\n%s\n' "$AUTHORITATIVE" "$(baseline_paths)")"
unlisted=0
while IFS= read -r path; do
    [ -n "$path" ] || continue
    if ! printf '%s\n' "$allowed" | grep -qxF "$path"; then
        echo "FAIL: DatabaseType defined outside $AUTHORITATIVE and $BASELINE_FILE: $path"
        unlisted=$((unlisted + 1))
    fi
done <<< "$found"

if [ "$unlisted" -gt 0 ]; then
    exit 1
fi
echo "ok: every DatabaseType definition is the authoritative one or listed in $BASELINE_FILE"
