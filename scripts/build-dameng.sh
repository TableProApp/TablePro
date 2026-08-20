#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/Native/DamengBridge"
# Not Libs/. That directory holds prebuilt slices downloaded and checksum-verified by
# download-libs.sh, and publish-libs.sh treats anything unrecognised there as an error.
# The bridge is compiled from in-tree Rust instead, so its output stays beside its source.
LIBS_DIR="$BRIDGE_DIR/lib"
ARCH="${1:-both}"
MACOS_TARGET="14.0"
RUST_TOOLCHAIN="1.91.1"

if ! rustup toolchain list | grep -q "^${RUST_TOOLCHAIN}"; then
    rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
fi

build_slice() {
    local arch="$1"
    local target="$2"
    local output="$LIBS_DIR/libdameng_bridge_${arch}.a"

    if ! rustup target list --installed --toolchain "$RUST_TOOLCHAIN" | grep -qx "$target"; then
        rustup target add "$target" --toolchain "$RUST_TOOLCHAIN"
    fi

    env RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN" MACOSX_DEPLOYMENT_TARGET="$MACOS_TARGET" \
        cargo build \
        --manifest-path "$BRIDGE_DIR/Cargo.toml" \
        --locked \
        --release \
        --target "$target"

    cp "$BRIDGE_DIR/target/$target/release/libtablepro_dameng_bridge.a" "$output"
    nm -gU "$output" | grep 'T _tp_dm_connect' > /dev/null
}

mkdir -p "$LIBS_DIR"

case "$ARCH" in
    arm64)
        build_slice arm64 aarch64-apple-darwin
        cp "$LIBS_DIR/libdameng_bridge_arm64.a" "$LIBS_DIR/libdameng_bridge.a"
        ;;
    x86_64)
        build_slice x86_64 x86_64-apple-darwin
        cp "$LIBS_DIR/libdameng_bridge_x86_64.a" "$LIBS_DIR/libdameng_bridge.a"
        ;;
    both|universal)
        build_slice arm64 aarch64-apple-darwin
        build_slice x86_64 x86_64-apple-darwin
        lipo -create \
            "$LIBS_DIR/libdameng_bridge_arm64.a" \
            "$LIBS_DIR/libdameng_bridge_x86_64.a" \
            -output "$LIBS_DIR/libdameng_bridge_universal.a"
        cp "$LIBS_DIR/libdameng_bridge_universal.a" "$LIBS_DIR/libdameng_bridge.a"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]" >&2
        exit 1
        ;;
esac

file "$LIBS_DIR"/libdameng_bridge*.a
