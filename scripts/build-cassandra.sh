#!/bin/bash
set -euo pipefail

# Build DataStax C/C++ driver (cassandra-cpp-driver) static library for TablePro
# Usage: ./scripts/build-cassandra.sh [arm64|x86_64|both]
#
# Dependencies: cmake, libuv (built automatically), OpenSSL (from Libs/)

CASSANDRA_VERSION="2.17.1"
CASSANDRA_SHA256="e6ab5f5c60a916dd6c0dd9a19a883a4a1ab3d6b4e95cab925a186fecff08344e"
LIBUV_VERSION="1.48.0"
LIBUV_SHA256="7f1db8ac368d89d1baf163bac1ea5fe5120697a73910c8ae6b2fffb3551d59fb"
BUILD_DIR="/tmp/cassandra-build"
LIBS_DIR="$(cd "$(dirname "$0")/.." && pwd)/Libs"
HEADERS_DIR="$(cd "$(dirname "$0")/.." && pwd)/Plugins/CassandraDriverPlugin/CCassandra/include"
ARCH="${1:-both}"
MACOS_TARGET="14.0"

echo "Building DataStax Cassandra C driver $CASSANDRA_VERSION..."

mkdir -p "$BUILD_DIR"
mkdir -p "$LIBS_DIR"
mkdir -p "$HEADERS_DIR"

# --- Build libuv ---
build_libuv() {
    local arch=$1
    local uv_build_dir="$BUILD_DIR/libuv-build-${arch}"

    if [ -f "$LIBS_DIR/libuv_${arch}.a" ]; then
        echo "✅ libuv_${arch}.a already exists, skipping"
        return 0
    fi

    echo "📦 Building libuv $LIBUV_VERSION for $arch..."
    cd "$BUILD_DIR"

    if [ ! -d "libuv-v${LIBUV_VERSION}" ]; then
        curl -fSL "https://dist.libuv.org/dist/v${LIBUV_VERSION}/libuv-v${LIBUV_VERSION}.tar.gz" -o libuv.tar.gz
        echo "$LIBUV_SHA256  libuv.tar.gz" | shasum -a 256 -c -
        tar xzf libuv.tar.gz
    fi

    rm -rf "$uv_build_dir"
    mkdir -p "$uv_build_dir"

    cmake -S "libuv-v${LIBUV_VERSION}" -B "$uv_build_dir" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DLIBUV_BUILD_TESTS=OFF \
        -DLIBUV_BUILD_BENCH=OFF \
        -DBUILD_TESTING=OFF

    cmake --build "$uv_build_dir" --config Release -j "$(sysctl -n hw.ncpu)"

    cp "$uv_build_dir/libuv_a.a" "$LIBS_DIR/libuv_${arch}.a" 2>/dev/null \
        || cp "$uv_build_dir/libuv.a" "$LIBS_DIR/libuv_${arch}.a"

    echo "✅ Created libuv_${arch}.a"
}

# --- Build cassandra-cpp-driver ---
build_cassandra() {
    local arch=$1
    local cass_build_dir="$BUILD_DIR/cassandra-build-${arch}"

    if [ -f "$LIBS_DIR/libcassandra_${arch}.a" ]; then
        echo "✅ libcassandra_${arch}.a already exists, skipping"
        return 0
    fi

    echo "📦 Building cassandra-cpp-driver $CASSANDRA_VERSION for $arch..."
    cd "$BUILD_DIR"

    if [ ! -d "cassandra-cpp-driver-${CASSANDRA_VERSION}" ]; then
        curl -fSL "https://github.com/datastax/cpp-driver/archive/refs/tags/${CASSANDRA_VERSION}.tar.gz" -o cpp-driver.tar.gz
        echo "$CASSANDRA_SHA256  cpp-driver.tar.gz" | shasum -a 256 -c -
        tar xzf cpp-driver.tar.gz
    fi

    # Patch CMakeLists.txt to accept AppleClang (macOS default compiler)
    sed -i '' 's/"${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang"/"${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang" OR "${CMAKE_CXX_COMPILER_ID}" STREQUAL "AppleClang"/g' \
        "cassandra-cpp-driver-${CASSANDRA_VERSION}/CMakeLists.txt"

    rm -rf "$cass_build_dir"
    mkdir -p "$cass_build_dir"

    cmake -S "cassandra-cpp-driver-${CASSANDRA_VERSION}" -B "$cass_build_dir" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCASS_BUILD_STATIC=ON \
        -DCASS_BUILD_SHARED=OFF \
        -DCASS_BUILD_TESTS=OFF \
        -DCASS_BUILD_EXAMPLES=OFF \
        -DCASS_USE_OPENSSL=ON \
        -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3 2>/dev/null || echo /usr/local/opt/openssl)" \
        -DLIBUV_ROOT_DIR="$BUILD_DIR/libuv-v${LIBUV_VERSION}" \
        -DLIBUV_LIBRARY="$LIBS_DIR/libuv_${arch}.a" \
        -DLIBUV_INCLUDE_DIR="$BUILD_DIR/libuv-v${LIBUV_VERSION}/include"

    cmake --build "$cass_build_dir" --config Release -j "$(sysctl -n hw.ncpu)"

    cp "$cass_build_dir/libcassandra_static.a" "$LIBS_DIR/libcassandra_${arch}.a" 2>/dev/null \
        || cp "$cass_build_dir/libcassandra.a" "$LIBS_DIR/libcassandra_${arch}.a"

    echo "✅ Created libcassandra_${arch}.a"
}

# --- Copy headers ---
copy_headers() {
    echo "📋 Copying cassandra.h header..."

    if [ -f "$HEADERS_DIR/cassandra.h" ]; then
        echo "✅ cassandra.h already exists, skipping"
        return 0
    fi

    cd "$BUILD_DIR"

    if [ -f "cassandra-cpp-driver-${CASSANDRA_VERSION}/include/cassandra.h" ]; then
        cp "cassandra-cpp-driver-${CASSANDRA_VERSION}/include/cassandra.h" "$HEADERS_DIR/"
        echo "✅ Copied cassandra.h"
    else
        echo "❌ cassandra.h not found!"
        exit 1
    fi
}

# --- Main ---
case "$ARCH" in
    arm64)
        build_libuv arm64
        build_cassandra arm64
        cp "$LIBS_DIR/libcassandra_arm64.a" "$LIBS_DIR/libcassandra.a"
        cp "$LIBS_DIR/libuv_arm64.a" "$LIBS_DIR/libuv.a"
        copy_headers
        ;;
    x86_64)
        build_libuv x86_64
        build_cassandra x86_64
        cp "$LIBS_DIR/libcassandra_x86_64.a" "$LIBS_DIR/libcassandra.a"
        cp "$LIBS_DIR/libuv_x86_64.a" "$LIBS_DIR/libuv.a"
        copy_headers
        ;;
    both|universal)
        build_libuv arm64
        build_libuv x86_64
        build_cassandra arm64
        build_cassandra x86_64

        echo "Creating universal binaries..."
        lipo -create "$LIBS_DIR/libcassandra_arm64.a" "$LIBS_DIR/libcassandra_x86_64.a" \
            -output "$LIBS_DIR/libcassandra_universal.a"
        cp "$LIBS_DIR/libcassandra_universal.a" "$LIBS_DIR/libcassandra.a"

        lipo -create "$LIBS_DIR/libuv_arm64.a" "$LIBS_DIR/libuv_x86_64.a" \
            -output "$LIBS_DIR/libuv_universal.a"
        cp "$LIBS_DIR/libuv_universal.a" "$LIBS_DIR/libuv.a"

        echo "✅ Created universal binaries"
        copy_headers
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

echo ""
echo "Cassandra driver built successfully!"
echo "Libraries:"
ls -lh "$LIBS_DIR"/libcassandra*.a "$LIBS_DIR"/libuv*.a 2>/dev/null
echo ""
echo "Headers:"
ls -lh "$HEADERS_DIR"/cassandra.h 2>/dev/null
