#!/usr/bin/env bash
# Build FreeTDS static libraries for arm64 and x86_64, then lipo-merge to universal.
# Outputs to Libs/ and copies headers to TablePro/Core/Database/CFreeTDS/include/
#
# Usage: bash scripts/build-freetds.sh
# Prerequisites: brew install autoconf automake libtool

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIBS_DIR="$PROJECT_DIR/Libs"
FREETDS_VERSION="1.4.22"
FREETDS_SHA256="6acb9086350425f5178e544bbe2d54a001097e8e20277a2b766ad0799a2e7d87"
FREETDS_URL="https://www.freetds.org/files/stable/freetds-${FREETDS_VERSION}.tar.gz"
BUILD_DIR="/tmp/freetds-build"
INCLUDE_DST="$PROJECT_DIR/TablePro/Core/Database/CFreeTDS/include"

mkdir -p "$BUILD_DIR" "$LIBS_DIR" "$INCLUDE_DST"

echo "Downloading FreeTDS ${FREETDS_VERSION}..."
curl -fSL "$FREETDS_URL" -o "$BUILD_DIR/freetds-${FREETDS_VERSION}.tar.gz"
echo "$FREETDS_SHA256  $BUILD_DIR/freetds-${FREETDS_VERSION}.tar.gz" | shasum -a 256 -c -
tar xz -C "$BUILD_DIR" -f "$BUILD_DIR/freetds-${FREETDS_VERSION}.tar.gz"
SOURCE_DIR="$BUILD_DIR/freetds-${FREETDS_VERSION}"

build_arch() {
    local ARCH="$1"
    local PREFIX="/tmp/freetds-${ARCH}"
    local HOST_TRIPLE
    if [ "$ARCH" = "arm64" ]; then
        HOST_TRIPLE="aarch64-apple-darwin"
    else
        HOST_TRIPLE="x86_64-apple-darwin"
    fi

    echo "Building FreeTDS for ${ARCH}..."
    pushd "$SOURCE_DIR" > /dev/null
    make distclean 2>/dev/null || true
    ./configure \
        --prefix="$PREFIX" \
        --host="$HOST_TRIPLE" \
        --disable-shared \
        --enable-static \
        --disable-odbc \
        --with-tdsver=7.4 \
        CFLAGS="-arch ${ARCH} -mmacosx-version-min=14.0" \
        LDFLAGS="-arch ${ARCH}"
    make -j"$(sysctl -n hw.logicalcpu)"
    make install
    popd > /dev/null

    cp "$PREFIX/lib/libsybdb.a" "$LIBS_DIR/libsybdb_${ARCH}.a"
    echo "Built libsybdb_${ARCH}.a"
}

build_arch "arm64"
build_arch "x86_64"

echo "Creating universal binary..."
lipo -create \
    "$LIBS_DIR/libsybdb_arm64.a" \
    "$LIBS_DIR/libsybdb_x86_64.a" \
    -output "$LIBS_DIR/libsybdb_universal.a"

cp "$LIBS_DIR/libsybdb_universal.a" "$LIBS_DIR/libsybdb.a"

echo "Copying headers..."
cp /tmp/freetds-arm64/include/sybdb.h "$INCLUDE_DST/sybdb.h"
cp /tmp/freetds-arm64/include/sybfront.h "$INCLUDE_DST/sybfront.h"

echo "FreeTDS build complete!"
echo "Libraries in: $LIBS_DIR"
echo "Headers in: $INCLUDE_DST"
echo ""
echo "NEXT STEPS:"
echo "  1. Add the CFreeTDS module to Xcode project"
echo "  2. Add libsybdb.a to Link Binary With Libraries"
echo "  3. Add CFreeTDS/include/ to Header Search Paths"
