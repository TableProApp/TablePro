#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/Native/DamengBridge"
# Not Libs/. That directory holds prebuilt slices downloaded and checksum-verified by
# download-libs.sh, and publish-libs.sh treats anything unrecognised there as an error.
# The bridge is compiled from in-tree Rust instead, so its output stays beside its source.
LIBS_DIR="${LIBS_DIR:-$BRIDGE_DIR/lib}"
OUTPUT="$LIBS_DIR/libdameng_bridge.a"
ARCH="${1:-both}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deployment-target.sh"

# rustup takes the toolchain, profile and targets from rust-toolchain.toml in the working directory.
(cd "$BRIDGE_DIR" && rustup toolchain install)

archive() {
    echo "$BRIDGE_DIR/target/$1/release/libtablepro_dameng_bridge.a"
}

build_slice() {
    (
        cd "$BRIDGE_DIR"
        env MACOSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" cargo build --locked --release --target "$1"
    )
    nm -gU "$(archive "$1")" | grep 'T _tp_dm_connect' > /dev/null
}

mkdir -p "$LIBS_DIR"

case "$ARCH" in
    arm64)
        build_slice aarch64-apple-darwin
        cp "$(archive aarch64-apple-darwin)" "$OUTPUT"
        ;;
    x86_64)
        build_slice x86_64-apple-darwin
        cp "$(archive x86_64-apple-darwin)" "$OUTPUT"
        ;;
    both)
        build_slice aarch64-apple-darwin
        build_slice x86_64-apple-darwin
        lipo -create "$(archive aarch64-apple-darwin)" "$(archive x86_64-apple-darwin)" -output "$OUTPUT"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]" >&2
        exit 1
        ;;
esac

lipo -info "$OUTPUT"
verify_deployment_target "$OUTPUT"
