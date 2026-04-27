#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-both}"
LIBS_DIR="Libs"
OUT_DIR="$LIBS_DIR/dylibs"
MIN_MACOS="14.0"

mkdir -p "$OUT_DIR"

create_dylibs_for_arch() {
    local arch=$1
    local suffix=""
    if [ "$ARCH" = "both" ] && [ "$arch" != "universal" ]; then
        suffix=".$arch"
    fi

    local crypto_static="$LIBS_DIR/libcrypto_${arch}.a"
    local ssl_static="$LIBS_DIR/libssl_${arch}.a"

    if [ ! -f "$crypto_static" ]; then
        if [ -f "$LIBS_DIR/libcrypto.a" ] && lipo -info "$LIBS_DIR/libcrypto.a" 2>/dev/null | grep -q "$arch"; then
            crypto_static="$LIBS_DIR/libcrypto.a"
        else
            echo "ERROR: No libcrypto static lib found for $arch"
            exit 1
        fi
    fi

    if [ ! -f "$ssl_static" ]; then
        if [ -f "$LIBS_DIR/libssl.a" ] && lipo -info "$LIBS_DIR/libssl.a" 2>/dev/null | grep -q "$arch"; then
            ssl_static="$LIBS_DIR/libssl.a"
        else
            echo "ERROR: No libssl static lib found for $arch"
            exit 1
        fi
    fi

    echo "Creating libcrypto.3${suffix}.dylib ($arch)..."
    clang -arch "$arch" -shared \
        -o "$OUT_DIR/libcrypto.3${suffix}.dylib" \
        -Wl,-all_load "$crypto_static" \
        -install_name @rpath/libcrypto.3.dylib \
        -compatibility_version 3.0.0 -current_version 3.4.0 \
        -lz -framework Security -framework CoreFoundation \
        -mmacosx-version-min="$MIN_MACOS"

    echo "Creating libssl.3${suffix}.dylib ($arch)..."
    clang -arch "$arch" -shared \
        -o "$OUT_DIR/libssl.3${suffix}.dylib" \
        -Wl,-all_load "$ssl_static" \
        -L"$OUT_DIR" -lcrypto.3"$suffix" \
        -install_name @rpath/libssl.3.dylib \
        -compatibility_version 3.0.0 -current_version 3.4.0 \
        -mmacosx-version-min="$MIN_MACOS"
}

case "$ARCH" in
    arm64|x86_64)
        create_dylibs_for_arch "$ARCH"
        echo "OpenSSL dylibs created for $ARCH in $OUT_DIR/"
        ls -lh "$OUT_DIR"/lib*.dylib
        ;;
    both)
        create_dylibs_for_arch arm64
        create_dylibs_for_arch x86_64

        echo "Creating universal dylibs..."
        lipo -create \
            "$OUT_DIR/libcrypto.3.arm64.dylib" \
            "$OUT_DIR/libcrypto.3.x86_64.dylib" \
            -output "$OUT_DIR/libcrypto.3.dylib"

        lipo -create \
            "$OUT_DIR/libssl.3.arm64.dylib" \
            "$OUT_DIR/libssl.3.x86_64.dylib" \
            -output "$OUT_DIR/libssl.3.dylib"

        rm -f "$OUT_DIR"/*.arm64.dylib "$OUT_DIR"/*.x86_64.dylib
        echo "Universal OpenSSL dylibs created in $OUT_DIR/"
        ls -lh "$OUT_DIR"/lib*.dylib
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac
