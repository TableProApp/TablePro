#!/usr/bin/env bash
set -euo pipefail

# PluginKit ABI gate (toolchain-independent).
#
# Builds TableProPluginKit at the current tree AND at a base ref with the SAME toolchain, then
# diffs their public Swift interfaces. Comparing two builds from one compiler means Swift version
# drift between a dev machine and CI cannot produce a false diff, so there is no committed baseline
# to keep in sync. A reported diff is a real ABI change to act on:
#
#   Additive (a new requirement WITH a default implementation, a new field on a non-@frozen struct,
#   a new case on a non-@frozen enum): no version bump needed.
#   Breaking (changed/removed/renamed signature, a new case on a @frozen enum, a changed frozen
#   layout): bump currentPluginKitVersion in PluginManager.swift, raise TableProPluginKitVersion in
#   every plugin Info.plist, then run scripts/release-all-plugins.sh <newVersion>.
#
# Usage: scripts/check-pluginkit-abi.sh [base-ref]   (default: origin/main)

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_REF="${1:-origin/main}"

RESULT=""

# Build TableProPluginKit in project dir $1, writing its normalized public interface to $2.
# Sets RESULT to ok | none (no interface emitted, i.e. Library Evolution off) | failed.
# The .swiftinterface lives under an arch-named subdir (arm64-apple-macos on Apple Silicon,
# x86_64-apple-macos on Intel), so locate it by glob instead of hardcoding the host arch.
build_interface() {
    local dir="$1" out="$2" sym interface
    sym="$(mktemp -d)"
    [ -f "$dir/Secrets.xcconfig" ] || touch "$dir/Secrets.xcconfig"
    if ! xcodebuild -project "$dir/TablePro.xcodeproj" -target TableProPluginKit -configuration Debug \
            -skipPackagePluginValidation build SYMROOT="$sym" >"$sym/build.log" 2>&1; then
        RESULT="failed"
        tail -20 "$sym/build.log"
        return
    fi
    interface="$(find "$sym/Debug/TableProPluginKit.framework" -name '*.swiftinterface' 2>/dev/null | head -1)"
    if [ -n "$interface" ]; then
        grep -v '^// swift-' "$interface" > "$out"
        RESULT="ok"
    else
        RESULT="none"
    fi
}

if ! git -C "$PROJECT_DIR" diff --quiet HEAD; then
    echo "::error::Working tree has uncommitted changes; commit or stash before running the ABI gate."
    exit 1
fi

base_sha="$(git -C "$PROJECT_DIR" rev-parse --verify "$BASE_REF" 2>/dev/null)" || {
    echo "::error::cannot resolve base ref '$BASE_REF'"; exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Building current TableProPluginKit..."
build_interface "$PROJECT_DIR" "$work/head.txt"
[ "$RESULT" = "failed" ] && { echo "::error::current TableProPluginKit build failed"; exit 1; }
head_result="$RESULT"

echo "Building base ($BASE_REF -> ${base_sha:0:8})..."
git clone --quiet --local --no-hardlinks "$PROJECT_DIR" "$work/base"
git -C "$work/base" checkout --quiet "$base_sha"
build_interface "$work/base" "$work/base.txt"
[ "$RESULT" = "failed" ] && { echo "::error::base TableProPluginKit build failed at $BASE_REF"; exit 1; }
base_result="$RESULT"

if [ "$base_result" = "none" ]; then
    echo "Base has no resilient interface (Library Evolution not enabled there). Bootstrap, nothing to compare. Pass."
    exit 0
fi

if [ "$head_result" = "none" ]; then
    echo "::error::current build produced no .swiftinterface but the base did. Was BUILD_LIBRARY_FOR_DISTRIBUTION turned off?"
    exit 1
fi

if diff -u "$work/base.txt" "$work/head.txt"; then
    echo "PluginKit ABI unchanged vs $BASE_REF."
    exit 0
fi

if [ "${ABI_ACKNOWLEDGED_ADDITIVE:-}" = "1" ]; then
    cat <<'EOF'

::notice::TableProPluginKit public ABI changed vs base (diff above).
The PR carries the abi-additive label: a maintainer reviewed the diff as additive (new defaulted
requirements or non-frozen types), so no version bump is required and the gate passes.
Remove the label if the diff gains a breaking change; the gate will fail again.
EOF
    exit 0
fi

cat <<'EOF'

::error::TableProPluginKit public ABI changed vs base (diff above). Decide additive vs breaking:
  Additive: no version bump. After review, add the abi-additive label to the PR and re-run.
  Breaking: bump currentPluginKitVersion + every plugin Info.plist TableProPluginKitVersion,
            then run scripts/release-all-plugins.sh <newVersion>.
EOF
exit 1
