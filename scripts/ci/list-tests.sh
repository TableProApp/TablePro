#!/usr/bin/env bash
set -euo pipefail

# Prints the -only-testing arguments for one shard of a test target, one per line.
#
# The list comes from xcodebuild itself rather than from a file somebody maintains, so a test added
# tomorrow lands in a shard with nothing to update. A hand-written shard list is the failure mode
# worth avoiding here: a suite that falls out of every shard still reports green.
#
# Usage: list-tests.sh --xctestrun PATH --target NAME [--quarantine FILE] [--shard I/N]
#
#   --quarantine  one suite name per line, '#' starts a comment. Matched against the suite and
#                 against the full Target/Suite/case() identifier.
#   --shard I/N   round-robin over the sorted identifiers: shard I of N, zero-based. Round-robin
#                 rather than contiguous blocks because it spreads a slow suite's cases across
#                 shards instead of landing them all in one.

usage() {
    sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit "${1:-1}"
}

XCTESTRUN=""
TARGET=""
QUARANTINE=""
SHARD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --xctestrun) XCTESTRUN="${2:?--xctestrun needs a path}"; shift 2 ;;
        --target) TARGET="${2:?--target needs a name}"; shift 2 ;;
        --quarantine) QUARANTINE="${2:?--quarantine needs a path}"; shift 2 ;;
        --shard) SHARD="${2:?--shard needs I/N}"; shift 2 ;;
        -h | --help) usage 0 ;;
        *) echo "list-tests.sh: unknown argument '$1'" >&2; usage ;;
    esac
done

[ -n "$XCTESTRUN" ] || { echo "list-tests.sh: --xctestrun is required" >&2; usage; }
[ -n "$TARGET" ] || { echo "list-tests.sh: --target is required" >&2; usage; }
[ -f "$XCTESTRUN" ] || { echo "list-tests.sh: no such xctestrun: $XCTESTRUN" >&2; exit 1; }

# A directory, not mktemp: xcodebuild refuses to write its enumeration to a path that already
# exists, and mktemp creates the file it names.
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

TARGET="$TARGET" QUARANTINE="$QUARANTINE" SHARD="$SHARD" \
    python3 "$(dirname "${BASH_SOURCE[0]}")/list_tests.py" "$workdir/tests.json"
