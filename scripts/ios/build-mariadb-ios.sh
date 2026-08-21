#!/usr/bin/env bash
set -eo pipefail

# Build static MariaDB Connector/C for iOS → xcframework
#
# Requires: OpenSSL xcframework already built
#
# Produces: Libs/ios/MariaDB.xcframework/
#
# Usage:
#   ./scripts/ios/build-mariadb-ios.sh

MARIADB_VERSION="3.4.4"
# MariaDB publishes a digest for this tarball independently of the tarball itself, at
# https://archive.mariadb.org/connector-c-$MARIADB_VERSION/sha256sums.txt, which is why the source
# moved here from the GitHub tag archive: GitHub publishes no digest, so pinning one would only
# record whatever was served the first time anybody looked. Note the upstream tarball unpacks to a
# "-src" directory, unlike the GitHub one.
MARIADB_SHA256="58876fad1c2d33979d78bbfa61d7a3476e8faa2cd0af0f7f8bfeb06deaa1034e"
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

echo "Building static MariaDB Connector/C $MARIADB_VERSION for iOS"
echo "   Build dir: $BUILD_DIR"

# --- Locate OpenSSL ---

setup_openssl_prefix() {
    local PLATFORM_KEY=$1
    local PREFIX_DIR="$BUILD_DIR/openssl-$PLATFORM_KEY"

    local SSL_LIB
    SSL_LIB=$(find "$LIBS_DIR/OpenSSL-SSL.xcframework" -path "*$PLATFORM_KEY*/libssl.a" | head -1)
    local CRYPTO_LIB
    CRYPTO_LIB=$(find "$LIBS_DIR/OpenSSL-Crypto.xcframework" -path "*$PLATFORM_KEY*/libcrypto.a" | head -1)
    local HEADERS
    HEADERS=$(find "$LIBS_DIR/OpenSSL-SSL.xcframework" -path "*$PLATFORM_KEY*/Headers" -type d | head -1)

    if [ -z "$SSL_LIB" ] || [ -z "$CRYPTO_LIB" ]; then
        echo "ERROR: OpenSSL not found for $PLATFORM_KEY. Run build-openssl-ios.sh first."
        exit 1
    fi

    mkdir -p "$PREFIX_DIR/lib" "$PREFIX_DIR/include"
    cp "$SSL_LIB" "$PREFIX_DIR/lib/"
    cp "$CRYPTO_LIB" "$PREFIX_DIR/lib/"
    [ -d "$HEADERS" ] && cp -R "$HEADERS/openssl" "$PREFIX_DIR/include/" 2>/dev/null || true

    OPENSSL_PREFIX="$PREFIX_DIR"
}

# --- Download MariaDB Connector/C ---

echo "=> Downloading MariaDB Connector/C $MARIADB_VERSION..."
curl -fSL "https://archive.mariadb.org/connector-c-$MARIADB_VERSION/mariadb-connector-c-$MARIADB_VERSION-src.tar.gz" \
    -o "$BUILD_DIR/mariadb.tar.gz"
echo "$MARIADB_SHA256  $BUILD_DIR/mariadb.tar.gz" | shasum -a 256 -c -

tar xzf "$BUILD_DIR/mariadb.tar.gz" -C "$BUILD_DIR"
MARIADB_SRC="$BUILD_DIR/mariadb-connector-c-$MARIADB_VERSION-src"

# --- Build function ---

build_mariadb_slice() {
    local SDK_NAME=$1       # iphoneos or iphonesimulator
    local ARCH=$2           # arm64
    local PLATFORM_KEY=$3   # ios-arm64 or ios-arm64-simulator
    local INSTALL_DIR="$BUILD_DIR/install-$SDK_NAME-$ARCH"

    echo "=> Building MariaDB Connector/C for $SDK_NAME ($ARCH)..."

    setup_openssl_prefix "$PLATFORM_KEY"

    local SDK_PATH
    SDK_PATH=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)

    local SRC_COPY="$BUILD_DIR/mariadb-$SDK_NAME-$ARCH"
    cp -R "$MARIADB_SRC" "$SRC_COPY"

    local BUILD="$SRC_COPY/cmake-build"
    mkdir -p "$BUILD"
    cd "$BUILD"

    run_quiet cmake .. \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOY_TARGET" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_C_FLAGS="-Wno-default-const-init-var-unsafe -Wno-inline-asm -Wno-error=inline-asm" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_EXTERNAL_ZLIB=ON \
        -DWITH_SSL=OPENSSL \
        -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
        -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.a" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include" \
        -DWITH_UNIT_TESTS=OFF \
        -DWITH_CURL=OFF \
        -DCLIENT_PLUGIN_AUTH_GSSAPI_CLIENT=OFF \
        -DCLIENT_PLUGIN_DIALOG=STATIC \
        -DCLIENT_PLUGIN_MYSQL_CLEAR_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_CACHING_SHA2_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_SHA256_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_MYSQL_NATIVE_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_MYSQL_OLD_PASSWORD=OFF \
        -DCLIENT_PLUGIN_PVIO_NPIPE=OFF \
        -DCLIENT_PLUGIN_PVIO_SHMEM=OFF

    run_quiet cmake --build . --target mariadb_obj -j"$NCPU"
    run_quiet cmake --build . --target mariadbclient -j"$NCPU"

    # Copy static lib and headers directly (cmake install fails looking for .so plugins)
    mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/include/mariadb"
    cp libmariadb/libmariadbclient.a "$INSTALL_DIR/lib/libmariadb.a"
    cp "$SRC_COPY/include/"*.h "$INSTALL_DIR/include/mariadb/" 2>/dev/null || true
    cp "$BUILD/include/"*.h "$INSTALL_DIR/include/mariadb/" 2>/dev/null || true

    echo "   Installed to $INSTALL_DIR"
}

# --- Build slices ---

build_mariadb_slice "iphoneos" "arm64" "ios-arm64"
build_mariadb_slice "iphonesimulator" "arm64" "ios-arm64-simulator"

# --- Create xcframework ---

DEVICE_DIR="$BUILD_DIR/install-iphoneos-arm64"
SIM_DIR="$BUILD_DIR/install-iphonesimulator-arm64"

rm -rf "$LIBS_DIR/MariaDB.xcframework"

# Find the actual .a file (may be in lib/ or lib/mariadb/)
DEVICE_LIB=$(find "$DEVICE_DIR" -name "libmariadb.a" -o -name "libmariadbclient.a" | head -1)
SIM_LIB=$(find "$SIM_DIR" -name "libmariadb.a" -o -name "libmariadbclient.a" | head -1)
DEVICE_HEADERS=$(find "$DEVICE_DIR" -path "*/mariadb/*.h" -exec dirname {} \; | sort -u | head -1)

if [ -z "$DEVICE_LIB" ] || [ -z "$SIM_LIB" ]; then
    echo "ERROR: libmariadb.a not found in install directories"
    echo "Device contents:"; find "$DEVICE_DIR" -name "*.a"
    echo "Sim contents:"; find "$SIM_DIR" -name "*.a"
    exit 1
fi

echo "=> Creating MariaDB.xcframework..."

xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" \
    -headers "$DEVICE_HEADERS" \
    -library "$SIM_LIB" \
    -headers "$(find "$SIM_DIR" -name "mysql.h" -exec dirname {} \; | head -1)" \
    -output "$LIBS_DIR/MariaDB.xcframework"

echo ""
echo "MariaDB Connector/C $MARIADB_VERSION for iOS built successfully!"
echo "   $LIBS_DIR/MariaDB.xcframework"

# --- Verify ---

echo ""
echo "=> Verifying device slice..."
lipo -info "$DEVICE_LIB"
otool -l "$DEVICE_LIB" | grep -A4 "LC_BUILD_VERSION" | head -5

echo ""
echo "Done!"
