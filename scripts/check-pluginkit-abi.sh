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
# Both sides are generated from their project.yml first, so this regenerates
# TablePro.xcodeproj in the working tree as well as in the base checkout.
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
    if ! (cd "$dir" && xcodegen generate --quiet --spec project.yml) >"$sym/generate.log" 2>&1; then
        RESULT="failed"
        tail -20 "$sym/generate.log"
        return
    fi
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

# This is run by hand, per CLAUDE.md, not by a workflow. It used to have a branch that passed when
# ABI_ACKNOWLEDGED_ADDITIVE=1, set by a CI job that no longer exists, alongside instructions to add
# an `abi-additive` label and re-run. Nothing can set the variable and nothing reads the label, so
# both were telling the reader to do something that has no effect.
cat <<'EOF'

TableProPluginKit public ABI changed vs base (diff above). Decide additive vs breaking:
  Additive: a new requirement with a default, a reordering, or a field on a non-frozen transfer
            struct. No version bump, nothing further to do.
  Breaking: a changed or removed requirement, a requirement without a default, a case on a @frozen
            enum, or a frozen type's layout. Bump currentPluginKitVersion and every plugin
            Info.plist TableProPluginKitVersion, then run scripts/release-all-plugins.sh <version>.
EOF
exit 1
