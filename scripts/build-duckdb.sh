#!/bin/bash
set -euo pipefail

# Build DuckDB static library for TablePro
# Usage: ./scripts/build-duckdb.sh [arm64|x86_64|both]

DUCKDB_VERSION="v1.5.0"
BUILD_DIR="/tmp/duckdb-build"
LIBS_DIR="$(cd "$(dirname "$0")/.." && pwd)/Libs"
ARCH="${1:-both}"

echo "Building DuckDB $DUCKDB_VERSION static library..."

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Download source amalgamation if not present
if [ ! -f "duckdb.cpp" ]; then
    echo "Downloading DuckDB source amalgamation..."
    curl -sL "https://github.com/duckdb/duckdb/releases/download/$DUCKDB_VERSION/libduckdb-src.zip" -o libduckdb-src.zip
    unzip -o libduckdb-src.zip
fi

build_arch() {
    local arch=$1
    echo "Building for $arch..."
    clang++ -c -arch "$arch" -O2 -DDUCKDB_BUILD_LIBRARY -std=c++17 -stdlib=libc++ duckdb.cpp -o "duckdb_${arch}.o"
    ar rcs "libduckdb_${arch}.a" "duckdb_${arch}.o"
    cp "libduckdb_${arch}.a" "$LIBS_DIR/"
    echo "Created libduckdb_${arch}.a"
}

case "$ARCH" in
    arm64)
        build_arch arm64
        cp "$LIBS_DIR/libduckdb_arm64.a" "$LIBS_DIR/libduckdb.a"
        ;;
    x86_64)
        build_arch x86_64
        cp "$LIBS_DIR/libduckdb_x86_64.a" "$LIBS_DIR/libduckdb.a"
        ;;
    both|universal)
        build_arch arm64
        build_arch x86_64
        echo "Creating universal binary..."
        lipo -create "$LIBS_DIR/libduckdb_arm64.a" "$LIBS_DIR/libduckdb_x86_64.a" -output "$LIBS_DIR/libduckdb_universal.a"
        cp "$LIBS_DIR/libduckdb_universal.a" "$LIBS_DIR/libduckdb.a"
        echo "Created libduckdb_universal.a"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

echo "DuckDB static library built successfully!"
echo "Libraries are in: $LIBS_DIR"
ls -lh "$LIBS_DIR"/libduckdb*.a
