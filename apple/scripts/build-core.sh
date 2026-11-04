#!/usr/bin/env bash
# Builds the shared Rust core as the static library the Apple apps link, and its Swift bindings from that same
# library, into Packages/TableProFFI (core/docs/decisions/0010-macos-on-the-core.md). Neither is in git.
#
# Usage: build-core.sh [arm64|x86_64|both]    both, the default, is the universal slice the app ships
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APPLE_DIR/.." && pwd)"
PACKAGE_DIR="$APPLE_DIR/Packages/TableProFFI"
BUILD_DIR="$PACKAGE_DIR/Build"
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
ARCH="${1:-both}"
source "$APPLE_DIR/scripts/lib/deployment-target.sh"

case "$ARCH" in
    arm64) TRIPLES=(aarch64-apple-darwin) ;;
    x86_64) TRIPLES=(x86_64-apple-darwin) ;;
    both) TRIPLES=(aarch64-apple-darwin x86_64-apple-darwin) ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]" >&2
        exit 1
        ;;
esac

archive() {
    echo "$TARGET_DIR/$1/release/libtablepro_ffi.a"
}

cd "$REPO_ROOT"
# rustup takes the toolchain from rust-toolchain.toml here.
rustup target add "${TRIPLES[@]}"

for triple in "${TRIPLES[@]}"; do
    # The crate is a cdylib for Windows; the Apple apps link a static library, without the engines no slice moves yet.
    env MACOSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" cargo rustc --locked -p tablepro-ffi --lib --release \
        --no-default-features --target "$triple" --crate-type staticlib
done

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/lib" "$BUILD_DIR/include" "$PACKAGE_DIR/Sources/TableProFFI"
ARCHIVES=()
for triple in "${TRIPLES[@]}"; do
    ARCHIVES+=("$(archive "$triple")")
done
lipo -create "${ARCHIVES[@]}" -output "$BUILD_DIR/lib/libtablepro_ffi.a"
lipo -info "$BUILD_DIR/lib/libtablepro_ffi.a"
verify_deployment_target "$BUILD_DIR/lib/libtablepro_ffi.a"

# Generated from the library just built: UniFFI checks at load that the two carry the same API checksums.
cargo run --locked --quiet -p tablepro-bindgen --bin uniffi-bindgen-swift -- \
    --swift-sources --headers --modulemap --module-name TableProFFIC --modulemap-filename module.modulemap \
    "${ARCHIVES[0]}" "$BUILD_DIR/include"
mv "$BUILD_DIR/include/TableProFFI.swift" "$PACKAGE_DIR/Sources/TableProFFI/TableProFFI.swift"

xcodebuild -create-xcframework \
    -library "$BUILD_DIR/lib/libtablepro_ffi.a" -headers "$BUILD_DIR/include" \
    -output "$BUILD_DIR/TableProFFIC.xcframework"
echo "Built $BUILD_DIR/TableProFFIC.xcframework for macOS $DEPLOY_TARGET (${TRIPLES[*]})"
