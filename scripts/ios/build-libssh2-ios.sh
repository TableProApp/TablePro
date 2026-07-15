#!/bin/bash
set -eo pipefail

# Build static libssh2 for iOS → xcframework
#
# Requires: OpenSSL xcframework already built (run build-openssl-ios.sh first)
# Produces: Libs/ios/LibSSH2.xcframework/

LIBSSH2_VERSION="1.11.1"
LIBSSH2_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"
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

echo "Building static libssh2 $LIBSSH2_VERSION for iOS"
echo "   Build dir: $BUILD_DIR"

# --- Locate OpenSSL ---

resolve_openssl() {
    local PLATFORM_KEY=$1
    local PREFIX="$BUILD_DIR/openssl-$PLATFORM_KEY"

    local SSL_LIB=$(find "$LIBS_DIR/OpenSSL-SSL.xcframework" -path "*$PLATFORM_KEY*/libssl.a" | head -1)
    local CRYPTO_LIB=$(find "$LIBS_DIR/OpenSSL-Crypto.xcframework" -path "*$PLATFORM_KEY*/libcrypto.a" | head -1)
    local HEADERS=$(find "$LIBS_DIR/OpenSSL-SSL.xcframework" -path "*$PLATFORM_KEY*/Headers" -type d | head -1)

    if [ -z "$SSL_LIB" ] || [ -z "$CRYPTO_LIB" ]; then
        echo "ERROR: OpenSSL not found for $PLATFORM_KEY. Run build-openssl-ios.sh first."
        exit 1
    fi

    mkdir -p "$PREFIX/lib" "$PREFIX/include"
    cp "$SSL_LIB" "$PREFIX/lib/"
    cp "$CRYPTO_LIB" "$PREFIX/lib/"
    [ -d "$HEADERS" ] && cp -R "$HEADERS/openssl" "$PREFIX/include/" 2>/dev/null || true

    OPENSSL_PREFIX="$PREFIX"
}

# --- Download libssh2 ---

echo "=> Downloading libssh2 $LIBSSH2_VERSION..."
curl -fSL "https://github.com/libssh2/libssh2/releases/download/libssh2-$LIBSSH2_VERSION/libssh2-$LIBSSH2_VERSION.tar.gz" \
    -o "$BUILD_DIR/libssh2.tar.gz"
echo "$LIBSSH2_SHA256  $BUILD_DIR/libssh2.tar.gz" | shasum -a 256 -c - > /dev/null
tar xzf "$BUILD_DIR/libssh2.tar.gz" -C "$BUILD_DIR"
LIBSSH2_SRC="$BUILD_DIR/libssh2-$LIBSSH2_VERSION"

for patch in "$SCRIPT_DIR/../patches"/*.patch; do
    [ -e "$patch" ] || continue
    echo "=> Applying $(basename "$patch")"
    patch -p1 -d "$LIBSSH2_SRC" -i "$patch"
done

echo "   Done."

# --- Build function ---

build_libssh2_slice() {
    local SDK_NAME=$1       # iphoneos or iphonesimulator
    local ARCH=$2           # arm64
    local PLATFORM_KEY=$3   # ios-arm64 or ios-arm64-simulator
    local INSTALL_DIR="$BUILD_DIR/install-$SDK_NAME-$ARCH"

    echo "=> Building libssh2 for $SDK_NAME ($ARCH)..."

    resolve_openssl "$PLATFORM_KEY"

    local SDK_PATH
    SDK_PATH=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)

    local SRC_COPY="$BUILD_DIR/libssh2-$SDK_NAME-$ARCH"
    cp -R "$LIBSSH2_SRC" "$SRC_COPY"

    local BUILD_SUBDIR="$SRC_COPY/cmake-build"
    mkdir -p "$BUILD_SUBDIR"
    cd "$BUILD_SUBDIR"

    run_quiet cmake .. \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOY_TARGET" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DCRYPTO_BACKEND=OpenSSL \
        -DENABLE_ZLIB_COMPRESSION=OFF \
        -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
        -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.a" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include"

    run_quiet cmake --build . --config Release -j"$NCPU"
    run_quiet cmake --install . --config Release

    echo "   Installed to $INSTALL_DIR"
}

# --- Build slices ---

build_libssh2_slice "iphoneos" "arm64" "ios-arm64"
build_libssh2_slice "iphonesimulator" "arm64" "ios-arm64-simulator"

# --- Create xcframework ---

DEVICE_DIR="$BUILD_DIR/install-iphoneos-arm64"
SIM_DIR="$BUILD_DIR/install-iphonesimulator-arm64"

DEVICE_LIB=$(find "$DEVICE_DIR" -name "libssh2.a" | head -1)
SIM_LIB=$(find "$SIM_DIR" -name "libssh2.a" | head -1)
DEVICE_HEADERS=$(find "$DEVICE_DIR" -path "*/include" -type d | head -1)

if [ -z "$DEVICE_LIB" ] || [ -z "$SIM_LIB" ]; then
    echo "ERROR: libssh2.a not found"
    find "$DEVICE_DIR" -name "*.a"
    find "$SIM_DIR" -name "*.a"
    exit 1
fi

rm -rf "$LIBS_DIR/LibSSH2.xcframework"

echo "=> Creating LibSSH2.xcframework..."

xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" \
    -headers "$DEVICE_HEADERS" \
    -library "$SIM_LIB" \
    -headers "$(find "$SIM_DIR" -path "*/include" -type d | head -1)" \
    -output "$LIBS_DIR/LibSSH2.xcframework"

echo ""
echo "libssh2 $LIBSSH2_VERSION for iOS built successfully!"
echo "   $LIBS_DIR/LibSSH2.xcframework"

# --- Verify ---

echo ""
echo "=> Verifying device slice..."
lipo -info "$DEVICE_LIB"
otool -l "$DEVICE_LIB" | grep -A4 "LC_BUILD_VERSION" | head -5

echo ""
echo "Done!"
