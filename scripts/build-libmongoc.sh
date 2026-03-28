#!/bin/bash
set -eo pipefail

# Run a command silently, showing output only on failure.
run_quiet() {
    local logfile
    logfile=$(mktemp)
    if ! "$@" > "$logfile" 2>&1; then
        tail -30 "$logfile"
        rm -f "$logfile"
        return 1
    fi
    rm -f "$logfile"
}

# Build static libmongoc and libbson for TablePro
#
# Produces architecture-specific and universal static libraries in Libs/:
#   libbson_arm64.a, libbson_x86_64.a, libbson_universal.a
#   libmongoc_arm64.a, libmongoc_x86_64.a, libmongoc_universal.a
#
# Uses macOS SecureTransport (ENABLE_SSL=DARWIN) for TLS so that
# certificate verification uses the system Keychain automatically.
# Note: SecureTransport is deprecated by Apple but still functional on
# macOS 14+. It supports TLS 1.2 (no 1.3). MongoDB Atlas accepts TLS 1.2.
# libmongoc does not support Network.framework as a TLS backend.
#
# All libraries are built with MACOSX_DEPLOYMENT_TARGET=14.0 to match
# the app's minimum deployment target.
#
# Usage:
#   ./scripts/build-libmongoc.sh [arm64|x86_64|both]
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - CMake (brew install cmake)
#   - curl (for downloading source tarballs)

DEPLOY_TARGET="14.0"
MONGOC_VERSION="1.28.1"
MONGOC_SHA256="a93259840f461b28e198311e32144f5f8dc9fbd74348029f2793774d781bb7da"

ARCH="${1:-both}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBS_DIR="$PROJECT_DIR/Libs"
BUILD_DIR="$(mktemp -d)"
NCPU=$(sysctl -n hw.ncpu)

echo "🔧 Building static libmongoc $MONGOC_VERSION (SecureTransport)"
echo "   Deployment target: macOS $DEPLOY_TARGET"
echo "   Architecture: $ARCH"
echo "   Build dir: $BUILD_DIR"
echo ""

cleanup() {
    echo "🧹 Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

download_sources() {
    echo "📥 Downloading source tarballs..."

    if [ ! -f "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION.tar.gz" ]; then
        curl -fSL "https://github.com/mongodb/mongo-c-driver/releases/download/$MONGOC_VERSION/mongo-c-driver-$MONGOC_VERSION.tar.gz" \
            -o "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION.tar.gz"
    fi
    echo "$MONGOC_SHA256  $BUILD_DIR/mongo-c-driver-$MONGOC_VERSION.tar.gz" | shasum -a 256 -c -

    echo "✅ Sources downloaded"
}

build_mongoc() {
    local arch=$1
    local prefix="$BUILD_DIR/install-mongoc-$arch"

    echo ""
    echo "🔨 Building libmongoc (mongo-c-driver $MONGOC_VERSION) for $arch..."

    # Extract fresh copy for this arch
    rm -rf "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION-$arch"
    mkdir -p "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION-$arch"
    tar xzf "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION.tar.gz" -C "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION-$arch" --strip-components=1

    # Patch deprecated cmake_policy(SET CMP0042 OLD) for CMake 4.x compatibility
    local src_root="$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION-$arch"
    sed -i '' 's/cmake_policy (SET CMP0042 OLD)/cmake_policy (SET CMP0042 NEW)/' "$src_root/src/libbson/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy(SET CMP0042 OLD)/cmake_policy(SET CMP0042 NEW)/' "$src_root/src/libbson/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy (SET CMP0042 OLD)/cmake_policy (SET CMP0042 NEW)/' "$src_root/src/libmongoc/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy(SET CMP0042 OLD)/cmake_policy(SET CMP0042 NEW)/' "$src_root/src/libmongoc/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy (SET CMP0042 OLD)/cmake_policy (SET CMP0042 NEW)/' "$src_root/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy(SET CMP0042 OLD)/cmake_policy(SET CMP0042 NEW)/' "$src_root/CMakeLists.txt" 2>/dev/null || true

    local build_dir="$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION-$arch/cmake-build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    run_quiet env MACOSX_DEPLOYMENT_TARGET=$DEPLOY_TARGET \
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
        -DCMAKE_C_FLAGS="-mmacosx-version-min=$DEPLOY_TARGET" \
        -DENABLE_STATIC=ON \
        -DENABLE_SHARED=OFF \
        -DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF \
        -DENABLE_SASL=OFF \
        -DENABLE_SRV=ON \
        -DENABLE_ZLIB=SYSTEM \
        -DENABLE_ZSTD=OFF \
        -DENABLE_SSL=DARWIN \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF

    run_quiet cmake --build . --parallel "$NCPU"
    run_quiet cmake --install .

    echo "✅ libmongoc $arch: $(ls -lh "$prefix/lib/libmongoc-static-1.0.a" 2>/dev/null || ls -lh "$prefix/lib64/libmongoc-static-1.0.a" 2>/dev/null | awk '{print $5}') (libmongoc) $(ls -lh "$prefix/lib/libbson-static-1.0.a" 2>/dev/null || ls -lh "$prefix/lib64/libbson-static-1.0.a" 2>/dev/null | awk '{print $5}') (libbson)"
}

install_libs() {
    local arch=$1
    local prefix="$BUILD_DIR/install-mongoc-$arch"

    echo "📦 Installing $arch libraries to Libs/..."

    # Find the actual lib directory (may be lib/ or lib64/)
    local lib_dir="$prefix/lib"
    if [ -f "$prefix/lib64/libmongoc-static-1.0.a" ]; then
        lib_dir="$prefix/lib64"
    fi

    cp "$lib_dir/libmongoc-static-1.0.a" "$LIBS_DIR/libmongoc_${arch}.a"
    cp "$lib_dir/libbson-static-1.0.a" "$LIBS_DIR/libbson_${arch}.a"
}

install_headers() {
    local arch=$1
    local prefix="$BUILD_DIR/install-mongoc-$arch"
    local dest="$PROJECT_DIR/Plugins/MongoDBDriverPlugin/CLibMongoc/include"

    echo "📦 Installing libmongoc headers..."

    # Find the actual include directory
    local inc_dir="$prefix/include"

    # Install mongoc headers
    mkdir -p "$dest/mongoc"
    cp "$inc_dir/libmongoc-1.0/mongoc/"*.h "$dest/mongoc/"

    # Install bson headers
    mkdir -p "$dest/bson"
    cp "$inc_dir/libbson-1.0/bson/"*.h "$dest/bson/"

    echo "✅ Headers installed to $dest"
}

create_universal() {
    echo ""
    echo "🔗 Creating universal (fat) libraries..."
    for lib in libmongoc libbson; do
        if [ -f "$LIBS_DIR/${lib}_arm64.a" ] && [ -f "$LIBS_DIR/${lib}_x86_64.a" ]; then
            lipo -create \
                "$LIBS_DIR/${lib}_arm64.a" \
                "$LIBS_DIR/${lib}_x86_64.a" \
                -output "$LIBS_DIR/${lib}_universal.a"
            echo "   ${lib}_universal.a ($(ls -lh "$LIBS_DIR/${lib}_universal.a" | awk '{print $5}'))"
        fi
    done
}

build_for_arch() {
    local arch=$1
    build_mongoc "$arch"
    install_libs "$arch"
    # Install headers once (they're arch-independent)
    if [ ! -f "$PROJECT_DIR/Plugins/MongoDBDriverPlugin/CLibMongoc/include/mongoc/mongoc.h" ]; then
        install_headers "$arch"
    fi
}

verify_deployment_target() {
    echo ""
    echo "🔍 Verifying deployment targets..."
    local failed=0
    for lib in "$LIBS_DIR"/lib{mongoc,bson}_*.a; do
        [ -f "$lib" ] || continue
        local name min_ver
        name=$(basename "$lib")
        min_ver=$(otool -l "$lib" 2>/dev/null | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; found=0}' | sort -V | tail -1)
        if [ -z "$min_ver" ]; then
            min_ver=$(otool -l "$lib" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{found=1} found && /version/{print $2; found=0}' | sort -V | tail -1)
        fi
        if [ -n "$min_ver" ]; then
            if [ "$(printf '%s\n' "$DEPLOY_TARGET" "$min_ver" | sort -V | head -1)" != "$DEPLOY_TARGET" ]; then
                echo "   ❌ $name targets macOS $min_ver (expected $DEPLOY_TARGET)"
                failed=1
            else
                echo "   ✅ $name targets macOS $min_ver"
            fi
        fi
    done
    if [ "$failed" -eq 1 ]; then
        echo "❌ FATAL: Some libraries have incorrect deployment targets"
        exit 1
    fi
}

# Main
mkdir -p "$LIBS_DIR"
download_sources

case "$ARCH" in
    arm64)
        build_for_arch arm64
        ;;
    x86_64)
        build_for_arch x86_64
        ;;
    both)
        build_for_arch arm64
        build_for_arch x86_64
        create_universal
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

verify_deployment_target

echo ""
echo "🎉 Build complete! Libraries in Libs/:"
ls -lh "$LIBS_DIR"/lib{mongoc,bson}*.a 2>/dev/null
