#!/usr/bin/env bash
# Builds the shared Rust core as the static libraries the Apple apps link, and its Swift bindings from one of them,
# into Packages/TableProFFI (core/docs/decisions/0010-macos-on-the-core.md). Neither is in git.
#
# Usage: build-core.sh [slice...]
#   arm64, x86_64, both    the macOS slice for that architecture; both is the universal one the app ships
#   ios                    the iOS slice, for the iPhone and iPad
#   ios-simulator          the iOS Simulator slice, Apple silicon only like the other iOS libraries
# With no slice it builds both. Each run replaces the XCFramework, so name every slice this checkout builds.
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APPLE_DIR/.." && pwd)"
PACKAGE_DIR="$APPLE_DIR/Packages/TableProFFI"
BUILD_DIR="$PACKAGE_DIR/Build"
TARGET_DIR="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
source "$APPLE_DIR/scripts/lib/deployment-target.sh"
source "$APPLE_DIR/scripts/lib/system-sqlite.sh"

usage() {
    echo "Usage: $0 [arm64|x86_64|both] [ios] [ios-simulator]" >&2
    exit 1
}

MACOS_TRIPLES=()
IOS=false
IOS_SIMULATOR=false
[ $# -gt 0 ] || set -- both
for slice in "$@"; do
    case "$slice" in
        arm64 | x86_64 | both)
            [ ${#MACOS_TRIPLES[@]} -eq 0 ] || usage
            case "$slice" in
                arm64) MACOS_TRIPLES=(aarch64-apple-darwin) ;;
                x86_64) MACOS_TRIPLES=(x86_64-apple-darwin) ;;
                both) MACOS_TRIPLES=(aarch64-apple-darwin x86_64-apple-darwin) ;;
            esac
            ;;
        ios) IOS=true ;;
        ios-simulator) IOS_SIMULATOR=true ;;
        *) usage ;;
    esac
done

# Bash 3.2, which macOS ships, calls an empty array unbound under set -u, hence the ${a[@]+...} forms.
TRIPLES=(${MACOS_TRIPLES[@]+"${MACOS_TRIPLES[@]}"})
[ "$IOS" = false ] || TRIPLES+=(aarch64-apple-ios)
[ "$IOS_SIMULATOR" = false ] || TRIPLES+=(aarch64-apple-ios-sim)
if [ "$IOS" = true ] || [ "$IOS_SIMULATOR" = true ]; then
    IOS_TARGET="$(ios_deployment_target)"
fi

archive() {
    echo "$TARGET_DIR/$1/release/libtablepro_ffi.a"
}

cd "$REPO_ROOT"
# rustup takes the toolchain from rust-toolchain.toml here.
rustup target add "${TRIPLES[@]}"

for triple in "${TRIPLES[@]}"; do
    # rustc and the cc crate read the minimum OS from these, IPHONEOS_ for the device and the Simulator alike.
    case "$triple" in
        *-apple-darwin) minimum=(MACOSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET") ;;
        *) minimum=(IPHONEOS_DEPLOYMENT_TARGET="$IOS_TARGET") ;;
    esac
    # The crate is a cdylib for Windows; the Apple apps link a static library, without the engines no slice moves yet.
    env "${minimum[@]}" cargo rustc --locked -p tablepro-ffi --lib --release \
        --no-default-features --target "$triple" --crate-type staticlib
done

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/include" "$PACKAGE_DIR/Sources/TableProFFI"
LIBRARIES=()

if [ ${#MACOS_TRIPLES[@]} -gt 0 ]; then
    mkdir -p "$BUILD_DIR/macos"
    ARCHIVES=()
    for triple in ${MACOS_TRIPLES[@]+"${MACOS_TRIPLES[@]}"}; do
        ARCHIVES+=("$(archive "$triple")")
    done
    lipo -create "${ARCHIVES[@]}" -output "$BUILD_DIR/macos/libtablepro_ffi.a"
    lipo -info "$BUILD_DIR/macos/libtablepro_ffi.a"
    verify_deployment_target "$BUILD_DIR/macos/libtablepro_ffi.a"
    verify_system_sqlite "$BUILD_DIR/macos/libtablepro_ffi.a"
    LIBRARIES+=("$BUILD_DIR/macos/libtablepro_ffi.a")
fi

# The Simulator and the device read the same header, so one SDK's marks check both.
ios_slice() {
    mkdir -p "$BUILD_DIR/$1"
    cp "$(archive "$2")" "$BUILD_DIR/$1/libtablepro_ffi.a"
    verify_deployment_target_for iOS "$IOS_TARGET" "$BUILD_DIR/$1/libtablepro_ffi.a"
    verify_system_sqlite "$BUILD_DIR/$1/libtablepro_ffi.a" iphoneos ios "$IOS_TARGET" iOS
    LIBRARIES+=("$BUILD_DIR/$1/libtablepro_ffi.a")
}
[ "$IOS" = false ] || ios_slice ios aarch64-apple-ios
[ "$IOS_SIMULATOR" = false ] || ios_slice ios-simulator aarch64-apple-ios-sim

# Generated from a library just built: UniFFI checks at load that the two carry the same API checksums, and every
# slice exports the same API.
cargo run --locked --quiet -p tablepro-bindgen --bin uniffi-bindgen-swift -- \
    --swift-sources --headers --modulemap --module-name TableProFFIC --modulemap-filename module.modulemap \
    "$(archive "${TRIPLES[0]}")" "$BUILD_DIR/include"
mv "$BUILD_DIR/include/TableProFFI.swift" "$PACKAGE_DIR/Sources/TableProFFI/TableProFFI.swift"

XCFRAMEWORK_ARGS=()
for library in "${LIBRARIES[@]}"; do
    XCFRAMEWORK_ARGS+=(-library "$library" -headers "$BUILD_DIR/include")
done
xcodebuild -create-xcframework "${XCFRAMEWORK_ARGS[@]}" -output "$BUILD_DIR/TableProFFIC.xcframework"
echo "Built $BUILD_DIR/TableProFFIC.xcframework: $*"
