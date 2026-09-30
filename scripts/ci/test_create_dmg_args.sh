#!/usr/bin/env bash
#
# Checks how create-dmg.sh reads its arguments, with every tool that would touch the system stubbed.
#
# build-release.sh writes one bundle per architecture, build/Release/TablePro-<arch>.app, and
# nothing builds a universal TablePro.app, so the architecture picks the bundle and has no default.
#
# Each case runs in a scratch directory on a PATH holding only stubs and the plain file tools the
# script needs. SetFile is kept off it on purpose: create-dmg.sh falls back to an Applications
# symlink when the Finder alias fails, and with SetFile present it copies an icon through it.
#
# Usage: test_create_dmg_args.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/create-dmg.sh"
BASH_BIN="$(command -v bash)"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

TOOLS="$SCRATCH/tools"
mkdir -p "$TOOLS"
for tool in awk cp dirname du ln mkdir rm sed tr; do
    ln -s "$(command -v "$tool")" "$TOOLS/$tool"
done

write_stub() {
    { printf '#!/bin/sh\n'; cat; } > "$TOOLS/$1"
    chmod +x "$TOOLS/$1"
}
write_stub osascript <<< 'exit 0'
write_stub codesign <<< 'exit 0'
write_stub hdiutil <<< 'exit 1'
write_stub create-dmg <<'STUB'
eval "dmg=\${$(($# - 1))}"
: > "$dmg"
STUB

FAILURES=0
OUTPUT=""
STATUS=0

run_case() {
    local work="$SCRATCH/work-$1"
    shift
    mkdir -p "$work/build/Release/TablePro-arm64.app" "$work/build/Release/TablePro-x86_64.app"
    mkdir -p "$work/custom/Built.app"
    STATUS=0
    OUTPUT="$(cd "$work" && NOTARIZE=false PATH="$TOOLS" "$BASH_BIN" "$SCRIPT" "$@" 2>&1)" || STATUS=$?
    WORK="$work"
}

fail() {
    echo "FAIL: $1" >&2
    printf '    %s\n' "${OUTPUT//$'\n'/$'\n    '}" >&2
    FAILURES=$((FAILURES + 1))
}

expect_output() {
    case "$OUTPUT" in
        *"$2"*) ;;
        *) fail "$1: output lacks '$2'" ;;
    esac
}

run_case arm64 0.0.0 arm64
[ "$STATUS" -eq 0 ] || fail "arm64: exited $STATUS"
expect_output arm64 "Source: build/Release/TablePro-arm64.app"
[ -f "$WORK/build/Release/TablePro-0.0.0-arm64.dmg" ] || fail "arm64: no TablePro-0.0.0-arm64.dmg"

run_case x86_64 0.0.0 x86_64
[ "$STATUS" -eq 0 ] || fail "x86_64: exited $STATUS"
expect_output x86_64 "Source: build/Release/TablePro-x86_64.app"

run_case explicit 0.0.0 arm64 custom/Built.app
[ "$STATUS" -eq 0 ] || fail "explicit source: exited $STATUS"
expect_output "explicit source" "Source: custom/Built.app"

for arguments in "" "0.0.0" "0.0.0 universal"; do
    read -r -a argv <<< "$arguments"
    run_case "usage-${arguments// /-}" ${argv[@]+"${argv[@]}"}
    [ "$STATUS" -ne 0 ] || fail "'$arguments': exited 0"
    expect_output "'$arguments'" "Usage: create-dmg.sh <version> <arm64|x86_64> [source_app]"
done

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES create-dmg.sh argument check(s) failed." >&2
    exit 1
fi

echo "create-dmg.sh takes its architecture and bundle as build-release.sh writes them."
