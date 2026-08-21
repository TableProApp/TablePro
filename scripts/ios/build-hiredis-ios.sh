#!/usr/bin/env bash
set -eo pipefail

# Build static hiredis (with SSL) for iOS → xcframework
#
# Requires: OpenSSL xcframework already built (run build-openssl-ios.sh first)
#
# Produces: Libs/ios/Hiredis.xcframework/
#
# Usage:
#   ./scripts/ios/build-hiredis-ios.sh

HIREDIS_VERSION="1.2.0"
HIREDIS_SHA256="82ad632d31ee05da13b537c124f819eb88e18851d9cb0c30ae0552084811588c"
IOS_DEPLOY_TARGET="17.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIBS_DIR="$PROJECT_DIR/Libs/ios"
BUILD_DIR="$(mktemp -d)"
NCPU=$(sysctl -n hw.ncpu)

run_quiet() {
    local logfile
    logfile=$(mktemp)
    if ! "$@" > "$logfile" 2>&1; then
        echo "FAILED: $*"
        tail -50 "$logfile"
        rm -f "$logfile"
        return 1
    fi
    rm -f "$logfile"
}

cleanup() {
    echo "   Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

echo "Building static hiredis $HIREDIS_VERSION for iOS"
echo "   Build dir: $BUILD_DIR"

# --- Locate OpenSSL from xcframework ---

resolve_openssl() {
    local PLATFORM=$1  # ios-arm64 or ios-arm64-simulator
    local XCFW_SSL="$LIBS_DIR/OpenSSL-SSL.xcframework"
    local XCFW_CRYPTO="$LIBS_DIR/OpenSSL-Crypto.xcframework"

    if [ ! -d "$XCFW_SSL" ] || [ ! -d "$XCFW_CRYPTO" ]; then
        echo "ERROR: OpenSSL xcframeworks not found. Run build-openssl-ios.sh first."
        exit 1
    fi

    # Find the correct slice directory
    local SSL_LIB
    SSL_LIB=$(find "$XCFW_SSL" -path "*$PLATFORM*/libssl.a" | head -1)
    local CRYPTO_LIB
    CRYPTO_LIB=$(find "$XCFW_CRYPTO" -path "*$PLATFORM*/libcrypto.a" | head -1)
    local HEADERS
    HEADERS=$(find "$XCFW_SSL" -path "*$PLATFORM*/Headers" -type d | head -1)

    if [ -z "$SSL_LIB" ] || [ -z "$CRYPTO_LIB" ]; then
        echo "ERROR: Could not find OpenSSL libs for platform $PLATFORM"
        exit 1
    fi

    OPENSSL_SSL_LIB="$SSL_LIB"
    OPENSSL_CRYPTO_LIB="$CRYPTO_LIB"
    OPENSSL_INCLUDE="$HEADERS"
}

# --- Download hiredis ---

echo "=> Downloading hiredis $HIREDIS_VERSION..."
curl -fSL "https://github.com/redis/hiredis/archive/refs/tags/v$HIREDIS_VERSION.tar.gz" \
    -o "$BUILD_DIR/hiredis.tar.gz"
echo "$HIREDIS_SHA256  $BUILD_DIR/hiredis.tar.gz" | shasum -a 256 -c - > /dev/null

tar xzf "$BUILD_DIR/hiredis.tar.gz" -C "$BUILD_DIR"
HIREDIS_SRC="$BUILD_DIR/hiredis-$HIREDIS_VERSION"

# --- Build function ---

build_hiredis_slice() {
    local SDK_NAME=$1       # iphoneos or iphonesimulator
    local ARCH=$2           # arm64
    local PLATFORM_KEY=$3   # ios-arm64 or ios-arm64-simulator
    local INSTALL_DIR="$BUILD_DIR/install-$SDK_NAME-$ARCH"

    echo "=> Building hiredis for $SDK_NAME ($ARCH)..."

    resolve_openssl "$PLATFORM_KEY"

    local SDK_PATH
    SDK_PATH=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)

    local SRC_COPY="$BUILD_DIR/hiredis-$SDK_NAME-$ARCH"
    cp -R "$HIREDIS_SRC" "$SRC_COPY"

    local BUILD="$SRC_COPY/cmake-build"
    mkdir -p "$BUILD"
    cd "$BUILD"

    # Create a temporary OpenSSL prefix that cmake can find
    local OPENSSL_PREFIX="$BUILD_DIR/openssl-prefix-$SDK_NAME-$ARCH"
    mkdir -p "$OPENSSL_PREFIX/lib" "$OPENSSL_PREFIX/include"
    cp "$OPENSSL_SSL_LIB" "$OPENSSL_PREFIX/lib/"
    cp "$OPENSSL_CRYPTO_LIB" "$OPENSSL_PREFIX/lib/"
    if [ -d "$OPENSSL_INCLUDE" ]; then
        cp -R "$OPENSSL_INCLUDE/openssl" "$OPENSSL_PREFIX/include/" 2>/dev/null || true
    fi

    run_quiet cmake .. \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOY_TARGET" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_SSL=ON \
        -DDISABLE_TESTS=ON \
        -DENABLE_EXAMPLES=OFF \
        -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
        -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.a" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include"

    run_quiet cmake --build . --config Release -j"$NCPU"
    run_quiet cmake --install . --config Release

    echo "   Installed to $INSTALL_DIR"
}

# --- Build slices ---

build_hiredis_slice "iphoneos" "arm64" "ios-arm64"
build_hiredis_slice "iphonesimulator" "arm64" "ios-arm64-simulator"

# --- Create xcframeworks ---

DEVICE_DIR="$BUILD_DIR/install-iphoneos-arm64"
SIM_DIR="$BUILD_DIR/install-iphonesimulator-arm64"

rm -rf "$LIBS_DIR/Hiredis.xcframework"
rm -rf "$LIBS_DIR/Hiredis-SSL.xcframework"

echo "=> Creating Hiredis.xcframework..."

xcodebuild -create-xcframework \
    -library "$DEVICE_DIR/lib/libhiredis.a" \
    -headers "$DEVICE_DIR/include" \
    -library "$SIM_DIR/lib/libhiredis.a" \
    -headers "$SIM_DIR/include" \
    -output "$LIBS_DIR/Hiredis.xcframework"

echo "=> Creating Hiredis-SSL.xcframework..."

xcodebuild -create-xcframework \
    -library "$DEVICE_DIR/lib/libhiredis_ssl.a" \
    -library "$SIM_DIR/lib/libhiredis_ssl.a" \
    -output "$LIBS_DIR/Hiredis-SSL.xcframework"

echo ""
echo "hiredis $HIREDIS_VERSION for iOS built successfully!"
echo "   $LIBS_DIR/Hiredis.xcframework"
echo "   $LIBS_DIR/Hiredis-SSL.xcframework"

# --- Verify ---

echo ""
echo "=> Verifying device slice..."
lipo -info "$DEVICE_DIR/lib/libhiredis.a"
otool -l "$DEVICE_DIR/lib/libhiredis.a" | grep -A4 "LC_BUILD_VERSION" | head -5

echo ""
echo "Done!"
