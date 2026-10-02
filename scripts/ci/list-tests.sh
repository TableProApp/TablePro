#!/usr/bin/env bash
set -euo pipefail

# Prints xcodebuild test arguments for a target, one per line, from xcodebuild's own enumeration.
#
# Usage: list-tests.sh --xctestrun PATH --target NAME [--quarantine FILE] [--shard I/N] [--skip]
#
#   --quarantine  a quarantine list; fails on an entry that matches no enumerated case.
#   --shard I/N   -only-testing for shard I of N (zero-based, round-robin) of the unquarantined cases.
#   --skip        -skip-testing for the quarantined cases instead.

usage() {
    sed -n '4,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit "${1:-1}"
}

XCTESTRUN=""
TARGET=""
QUARANTINE=""
SHARD=""
MODE="only"

while [ $# -gt 0 ]; do
    case "$1" in
        --xctestrun) XCTESTRUN="${2:?--xctestrun needs a path}"; shift 2 ;;
        --target) TARGET="${2:?--target needs a name}"; shift 2 ;;
        --quarantine) QUARANTINE="${2:?--quarantine needs a path}"; shift 2 ;;
        --shard) SHARD="${2:?--shard needs I/N}"; shift 2 ;;
        --skip) MODE="skip"; shift ;;
        -h | --help) usage 0 ;;
        *) echo "list-tests.sh: unknown argument '$1'" >&2; usage ;;
    esac
done

[ -n "$XCTESTRUN" ] || { echo "list-tests.sh: --xctestrun is required" >&2; usage; }
[ -n "$TARGET" ] || { echo "list-tests.sh: --target is required" >&2; usage; }
[ -f "$XCTESTRUN" ] || { echo "list-tests.sh: no such xctestrun: $XCTESTRUN" >&2; exit 1; }
[ -z "$QUARANTINE" ] || [ -f "$QUARANTINE" ] || { echo "list-tests.sh: no such file: $QUARANTINE" >&2; exit 1; }

# A directory, because xcodebuild refuses to write its enumeration to a path that already exists.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "platform=macOS" \
    -only-testing:"$TARGET" \
    -enumerate-tests \
    -test-enumeration-style flat \
    -test-enumeration-format json \
    -test-enumeration-output-path "$workdir/tests.json" > "$workdir/enumerate.log" 2>&1 || {
    echo "list-tests.sh: test enumeration failed for $TARGET" >&2
    tail -40 "$workdir/enumerate.log" >&2
    exit 1
}

TARGET="$TARGET" QUARANTINE="$QUARANTINE" SHARD="$SHARD" MODE="$MODE" \
    python3 "$(dirname "${BASH_SOURCE[0]}")/list_tests.py" "$workdir/tests.json"
