#!/usr/bin/env bash
set -euo pipefail

# PluginKit ABI gate.
#
# Builds TableProPluginKit and compares its generated public interface against
# the committed baseline. Any divergence is an ABI change that must be
# acknowledged before merge:
#
#   Additive (a new requirement WITH a default implementation, a new field on a
#   non-@frozen struct, a new case on a non-@frozen enum): no version bump.
#   Refresh the baseline with `scripts/check-pluginkit-abi.sh --update` and commit it.
#
#   Breaking (changed/removed/renamed signature, a new case on a @frozen enum, a
#   changed frozen layout): also bump currentPluginKitVersion in PluginManager.swift,
#   raise TableProPluginKitVersion in every plugin Info.plist, refresh the baseline,
#   then run `scripts/release-all-plugins.sh <newVersion>`.
#
# Usage:
#   scripts/check-pluginkit-abi.sh            verify the interface matches the baseline
#   scripts/check-pluginkit-abi.sh --update   regenerate the baseline from the current source

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$PROJECT_DIR/Plugins/TableProPluginKit/ABI-Baseline.swiftinterface"

mode="check"
if [ "${1:-}" = "--update" ]; then
    mode="update"
fi

derived="$(mktemp -d)"
build_log="$(mktemp)"
trap 'rm -rf "$derived" "$build_log"' EXIT

echo "Building TableProPluginKit..."
if ! xcodebuild -project "$PROJECT_DIR/TablePro.xcodeproj" \
        -target TableProPluginKit -configuration Debug \
        -skipPackagePluginValidation build SYMROOT="$derived" \
        >"$build_log" 2>&1; then
    echo "::error::TableProPluginKit build failed"
    tail -30 "$build_log"
    exit 1
fi

fresh="$derived/Debug/TableProPluginKit.framework/Versions/A/Modules/TableProPluginKit.swiftmodule/arm64-apple-macos.swiftinterface"
if [ ! -f "$fresh" ]; then
    echo "::error::No .swiftinterface produced at $fresh"
    exit 1
fi

# Strip the toolchain-specific header (compiler version, module flags, paths) so the
# baseline only captures the public declarations, not the build environment.
normalized="$derived/normalized.swiftinterface"
grep -v '^// swift-' "$fresh" > "$normalized"

if [ "$mode" = "update" ]; then
    cp "$normalized" "$BASELINE"
    echo "Baseline updated: ${BASELINE#"$PROJECT_DIR"/}"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "::error::No ABI baseline at ${BASELINE#"$PROJECT_DIR"/}. Generate it with: scripts/check-pluginkit-abi.sh --update"
    exit 1
fi

if diff -u "$BASELINE" "$normalized"; then
    echo "PluginKit ABI matches the baseline."
    exit 0
fi

cat <<'EOF'

::error::TableProPluginKit public ABI changed (diff above). Decide additive vs breaking:
  Additive  (new requirement with a default, new field on a non-@frozen struct, new
            case on a non-@frozen enum): refresh the baseline and commit it ->
                scripts/check-pluginkit-abi.sh --update
  Breaking  (changed/removed/renamed signature, new case on a @frozen enum, changed
            frozen layout): ALSO bump currentPluginKitVersion in PluginManager.swift,
            raise TableProPluginKitVersion in every plugin Info.plist, refresh the
            baseline, then run scripts/release-all-plugins.sh <newVersion>.
EOF
exit 1
