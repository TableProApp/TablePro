#!/usr/bin/env bash
#
# Run the app's on-device model code (TablePro/Core/AI/OnDevice) against the Apple Intelligence model
# on this Mac. Prints availability, the context size, characters per token for SQL, a structure
# table and CJK text (OnDeviceTokenBudget.estimatedTokens rests on these), whether an oversized
# request is refused before generation, and a short streamed reply.
#
# Usage:
#   scripts/probes/check-on-device-model.sh
#
# Needs macOS 26 or later with Apple Intelligence on and its model downloaded, and xcrun swiftc.
# Exits 0 when a reply streams, 1 when it does not, 3 when the model is unavailable.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -parse-as-library -target arm64-apple-macos13 -O \
    "$ROOT"/TablePro/Core/AI/OnDevice/*.swift \
    "$ROOT"/scripts/probes/on-device-model/main.swift \
    -o "$WORK/probe" || exit 3

"$WORK/probe"
