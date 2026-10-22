#!/usr/bin/env bash
set -eo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

# Build static libmongoc + libbson for iOS → xcframeworks
#
# Requires: OpenSSL xcframeworks in Libs/ios (scripts/download-libs.sh)
#
# Produces:
#   Libs/ios/LibMongoc.xcframework/ (with the mongoc/ and bson/ headers)
#   Libs/ios/LibBson.xcframework/
#
# Same version and options as scripts/build-libmongoc.sh, so both apps speak to a server the same
# way. TLS is OpenSSL on iOS too: Secure Transport fails the handshake against MongoDB Atlas.
#
# CMake must be 3.x: see the prerequisites in scripts/build-libmongoc.sh. Point CMAKE_BIN at one.
#
# Usage:
#   ./scripts/ios/build-libmongoc-ios.sh

CMAKE_BIN="${CMAKE_BIN:-cmake}"
MONGOC_VERSION="1.28.1"
MONGOC_SHA256="a93259840f461b28e198311e32144f5f8dc9fbd74348029f2793774d781bb7da"
IOS_DEPLOY_TARGET="17.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIBS_DIR="$PROJECT_DIR/Libs/ios"
BUILD_DIR="$(mktemp -d)"
NCPU=$(sysctl -n hw.ncpu)
# Archive members get no timestamps, so a rebuild of the same sources is byte-identical.
export ZERO_AR_DATE=1

cleanup() {
    echo "   Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

case "$("$CMAKE_BIN" --version | head -1)" in
    "cmake version 3."*) ;;
    *)
        echo "ERROR: $CMAKE_BIN is not CMake 3.x. Set CMAKE_BIN to a 3.x binary." >&2
        exit 1
        ;;
esac

echo "Building static libmongoc $MONGOC_VERSION for iOS"
echo "   Build dir: $BUILD_DIR"

OPENSSL_SSL_XCFRAMEWORK="$LIBS_DIR/OpenSSL-SSL.xcframework"
OPENSSL_CRYPTO_XCFRAMEWORK="$LIBS_DIR/OpenSSL-Crypto.xcframework"
for xcframework in "$OPENSSL_SSL_XCFRAMEWORK" "$OPENSSL_CRYPTO_XCFRAMEWORK"; do
    [ -d "$xcframework" ] || { echo "ERROR: missing $xcframework; run scripts/download-libs.sh" >&2; exit 1; }
done

echo "=> Downloading mongo-c-driver $MONGOC_VERSION..."
curl -fSL "https://github.com/mongodb/mongo-c-driver/releases/download/$MONGOC_VERSION/mongo-c-driver-$MONGOC_VERSION.tar.gz" \
    -o "$BUILD_DIR/mongo-c-driver.tar.gz"
verify_sha256 "$BUILD_DIR/mongo-c-driver.tar.gz" "$MONGOC_SHA256"

build_mongoc_slice() {
    local SDK_NAME=$1      # iphoneos or iphonesimulator
    local PLATFORM_KEY=$2  # ios-arm64 or ios-arm64-simulator
    local INSTALL_DIR="$BUILD_DIR/install-$SDK_NAME"
    local SRC="$BUILD_DIR/mongo-c-driver-$SDK_NAME"

    echo "=> Building libmongoc for $SDK_NAME (arm64)..."

    # A prefix holding exactly the OpenSSL this app links, so CMake cannot find another one.
    local OPENSSL_PREFIX="$BUILD_DIR/openssl-$SDK_NAME"
    mkdir -p "$OPENSSL_PREFIX/lib" "$OPENSSL_PREFIX/include"
    cp "$OPENSSL_SSL_XCFRAMEWORK/$PLATFORM_KEY/libssl.a" "$OPENSSL_PREFIX/lib/"
    cp "$OPENSSL_CRYPTO_XCFRAMEWORK/$PLATFORM_KEY/libcrypto.a" "$OPENSSL_PREFIX/lib/"
    cp -R "$OPENSSL_SSL_XCFRAMEWORK/$PLATFORM_KEY/Headers/openssl" "$OPENSSL_PREFIX/include/"

    mkdir -p "$SRC"
    tar xzf "$BUILD_DIR/mongo-c-driver.tar.gz" -C "$SRC" --strip-components=1
    mkdir -p "$SRC/cmake-build"
    cd "$SRC/cmake-build"

    local SDK_PATH
    SDK_PATH=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)

    # Options match scripts/build-libmongoc.sh. Client-side encryption needs libmongocrypt, which
    # neither app ships, and shared-memory counters need shm_open, which the sandbox refuses, so
    # both are pinned off rather than left to detection.
    # The top-level CMakeLists.txt adds _DARWIN_C_SOURCE only when CMAKE_SYSTEM_NAME is Darwin.
    # Without it, _XOPEN_SOURCE=700 hides u_char from arpa/nameser.h, the res_nsearch check fails,
    # and ENABLE_SRV stops the configure.
    run_quiet "$CMAKE_BIN" .. \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOY_TARGET" \
        -DCMAKE_C_FLAGS="-D_DARWIN_C_SOURCE" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DENABLE_STATIC=ON \
        -DENABLE_SHARED=OFF \
        -DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF \
        -DENABLE_SASL=OFF \
        -DENABLE_SRV=ON \
        -DENABLE_ZLIB=SYSTEM \
        -DENABLE_ZSTD=OFF \
        -DENABLE_SNAPPY=OFF \
        -DENABLE_SSL=OPENSSL \
        -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF \
        -DENABLE_SHM_COUNTERS=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include" \
        -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.a"

    run_quiet "$CMAKE_BIN" --build . --config Release --parallel "$NCPU"
    run_quiet "$CMAKE_BIN" --install . --config Release

    # One header tree per slice, laid out the way `#include <mongoc/mongoc.h>` expects.
    mkdir -p "$INSTALL_DIR/headers"
    cp -R "$INSTALL_DIR/include/libmongoc-1.0/mongoc" "$INSTALL_DIR/headers/"
    cp -R "$INSTALL_DIR/include/libbson-1.0/bson" "$INSTALL_DIR/headers/"

    echo "   Installed to $INSTALL_DIR"
}

build_mongoc_slice "iphoneos" "ios-arm64"
build_mongoc_slice "iphonesimulator" "ios-arm64-simulator"

DEVICE_DIR="$BUILD_DIR/install-iphoneos"
SIM_DIR="$BUILD_DIR/install-iphonesimulator"

for slice in "$DEVICE_DIR" "$SIM_DIR"; do
    symbols=$(nm "$slice/lib/libmongoc-static-1.0.a" 2>/dev/null || true)
    if ! grep -q "_SSL_CTX_new" <<< "$symbols"; then
        echo "ERROR: $slice libmongoc does not reference OpenSSL (SSL_CTX_new)" >&2
        exit 1
    fi
    if grep -qE "_SSLHandshake|_SSLCreateContext" <<< "$symbols"; then
        echo "ERROR: $slice libmongoc references Secure Transport" >&2
        exit 1
    fi
done

rm -rf "$LIBS_DIR/LibMongoc.xcframework" "$LIBS_DIR/LibBson.xcframework"

echo "=> Creating LibMongoc.xcframework..."
xcodebuild -create-xcframework \
    -library "$DEVICE_DIR/lib/libmongoc-static-1.0.a" \
    -headers "$DEVICE_DIR/headers" \
    -library "$SIM_DIR/lib/libmongoc-static-1.0.a" \
    -headers "$SIM_DIR/headers" \
    -output "$LIBS_DIR/LibMongoc.xcframework"

echo "=> Creating LibBson.xcframework..."
xcodebuild -create-xcframework \
    -library "$DEVICE_DIR/lib/libbson-static-1.0.a" \
    -library "$SIM_DIR/lib/libbson-static-1.0.a" \
    -output "$LIBS_DIR/LibBson.xcframework"

echo ""
echo "=> Verifying device slice..."
lipo -info "$DEVICE_DIR/lib/libmongoc-static-1.0.a"
otool -l "$DEVICE_DIR/lib/libmongoc-static-1.0.a" | grep -A4 "LC_BUILD_VERSION" | head -5

echo ""
echo "libmongoc $MONGOC_VERSION for iOS built:"
echo "   $LIBS_DIR/LibMongoc.xcframework"
echo "   $LIBS_DIR/LibBson.xcframework"
