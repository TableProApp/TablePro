#!/bin/bash
set -eo pipefail

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

# Build static libmongoc + libbson for TablePro
#
# Produces architecture-specific and universal static libraries in Libs/:
#   libbson_arm64.a, libbson_x86_64.a, libbson_universal.a
#   libmongoc_arm64.a, libmongoc_x86_64.a, libmongoc_universal.a
#
# TLS backend: OpenSSL (ENABLE_SSL=OPENSSL). The previous Secure Transport
# build broke TLS handshakes against MongoDB Atlas on macOS 26 with
# errSSLPeerInternalError (-9838). OpenSSL handshakes succeed and TablePro
# already bundles OpenSSL 3 dylibs for Redis/MSSQL/MySQL.
#
# OpenSSL is rebuilt from source for each arch with the correct deployment
# target instead of relying on Homebrew or system OpenSSL.
#
# All libraries are built with MACOSX_DEPLOYMENT_TARGET=14.0 to match
# the app's minimum deployment target.
#
# Usage:
#   ./scripts/build-libmongoc.sh [arm64|x86_64|both]
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - CMake 3.15+ (brew install cmake)
#   - curl

DEPLOY_TARGET="14.0"
MONGOC_VERSION="1.28.1"
MONGOC_SHA256="a93259840f461b28e198311e32144f5f8dc9fbd74348029f2793774d781bb7da"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/openssl-version.sh"

ARCH="${1:-both}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBS_DIR="$PROJECT_DIR/Libs"
BUILD_DIR="$(mktemp -d)"
NCPU=$(sysctl -n hw.ncpu)

echo "🔧 Building static libmongoc $MONGOC_VERSION + OpenSSL $OPENSSL_VERSION"
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

    if [ ! -f "$BUILD_DIR/openssl-$OPENSSL_VERSION.tar.gz" ]; then
        curl -fSL "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
            -o "$BUILD_DIR/openssl-$OPENSSL_VERSION.tar.gz"
    fi
    echo "$OPENSSL_SHA256  $BUILD_DIR/openssl-$OPENSSL_VERSION.tar.gz" | shasum -a 256 -c -

    if [ ! -f "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION.tar.gz" ]; then
        curl -fSL "https://github.com/mongodb/mongo-c-driver/releases/download/$MONGOC_VERSION/mongo-c-driver-$MONGOC_VERSION.tar.gz" \
            -o "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION.tar.gz"
    fi
    echo "$MONGOC_SHA256  $BUILD_DIR/mongo-c-driver-$MONGOC_VERSION.tar.gz" | shasum -a 256 -c -

    echo "✅ Sources downloaded"
}

build_openssl() {
    local arch=$1
    local prefix="$BUILD_DIR/install-openssl-$arch"

    echo ""
    echo "🔨 Building OpenSSL $OPENSSL_VERSION for $arch..."

    rm -rf "$BUILD_DIR/openssl-$OPENSSL_VERSION-$arch"
    mkdir -p "$BUILD_DIR/openssl-$OPENSSL_VERSION-$arch"
    tar xzf "$BUILD_DIR/openssl-$OPENSSL_VERSION.tar.gz" -C "$BUILD_DIR/openssl-$OPENSSL_VERSION-$arch" --strip-components=1

    cd "$BUILD_DIR/openssl-$OPENSSL_VERSION-$arch"

    local target
    if [ "$arch" = "arm64" ]; then
        target="darwin64-arm64-cc"
    else
        target="darwin64-x86_64-cc"
    fi

    MACOSX_DEPLOYMENT_TARGET=$DEPLOY_TARGET \
    run_quiet ./Configure \
        "$target" \
        no-shared \
        no-tests \
        no-apps \
        no-docs \
        --prefix="$prefix" \
        -mmacosx-version-min=$DEPLOY_TARGET

    run_quiet make -j"$NCPU"
    run_quiet make install_sw

    echo "✅ OpenSSL $arch: $(ls -lh "$prefix/lib/libssl.a" | awk '{print $5}') (libssl) $(ls -lh "$prefix/lib/libcrypto.a" | awk '{print $5}') (libcrypto)"
}

build_mongoc() {
    local arch=$1
    local openssl_prefix="$BUILD_DIR/install-openssl-$arch"
    local prefix="$BUILD_DIR/install-mongoc-$arch"

    echo ""
    echo "🔨 Building libmongoc $MONGOC_VERSION for $arch (OpenSSL backend)..."

    rm -rf "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION-$arch"
    mkdir -p "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION-$arch"
    tar xzf "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION.tar.gz" -C "$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION-$arch" --strip-components=1

    local src_root="$BUILD_DIR/mongo-c-driver-$MONGOC_VERSION-$arch"
    sed -i '' 's/cmake_policy (SET CMP0042 OLD)/cmake_policy (SET CMP0042 NEW)/' "$src_root/src/libbson/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy(SET CMP0042 OLD)/cmake_policy(SET CMP0042 NEW)/' "$src_root/src/libbson/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy (SET CMP0042 OLD)/cmake_policy (SET CMP0042 NEW)/' "$src_root/src/libmongoc/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy(SET CMP0042 OLD)/cmake_policy(SET CMP0042 NEW)/' "$src_root/src/libmongoc/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy (SET CMP0042 OLD)/cmake_policy (SET CMP0042 NEW)/' "$src_root/CMakeLists.txt" 2>/dev/null || true
    sed -i '' 's/cmake_policy(SET CMP0042 OLD)/cmake_policy(SET CMP0042 NEW)/' "$src_root/CMakeLists.txt" 2>/dev/null || true

    local build_dir="$src_root/cmake-build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    local openssl_lib_dir="$openssl_prefix/lib"
    if [ -f "$openssl_prefix/lib64/libssl.a" ]; then
        openssl_lib_dir="$openssl_prefix/lib64"
    fi

    run_quiet env MACOSX_DEPLOYMENT_TARGET=$DEPLOY_TARGET \
    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
        -DCMAKE_C_FLAGS="-mmacosx-version-min=$DEPLOY_TARGET" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DENABLE_STATIC=ON \
        -DENABLE_SHARED=OFF \
        -DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF \
        -DENABLE_SASL=OFF \
        -DENABLE_SRV=ON \
        -DENABLE_ZLIB=SYSTEM \
        -DENABLE_ZSTD=OFF \
        -DENABLE_SSL=OPENSSL \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DOPENSSL_ROOT_DIR="$openssl_prefix" \
        -DOPENSSL_INCLUDE_DIR="$openssl_prefix/include" \
        -DOPENSSL_SSL_LIBRARY="$openssl_lib_dir/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$openssl_lib_dir/libcrypto.a"

    run_quiet cmake --build . --parallel "$NCPU"
    run_quiet cmake --install .

    echo "✅ libmongoc $arch: $(ls -lh "$prefix/lib/libmongoc-static-1.0.a" 2>/dev/null || ls -lh "$prefix/lib64/libmongoc-static-1.0.a" 2>/dev/null | awk '{print $5}') (libmongoc) $(ls -lh "$prefix/lib/libbson-static-1.0.a" 2>/dev/null || ls -lh "$prefix/lib64/libbson-static-1.0.a" 2>/dev/null | awk '{print $5}') (libbson)"
}

install_libs() {
    local arch=$1
    local prefix="$BUILD_DIR/install-mongoc-$arch"

    echo "📦 Installing $arch libraries to Libs/..."

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

    local inc_dir="$prefix/include"

    mkdir -p "$dest/mongoc"
    cp "$inc_dir/libmongoc-1.0/mongoc/"*.h "$dest/mongoc/"

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
    build_openssl "$arch"
    build_mongoc "$arch"
    install_libs "$arch"
    install_headers "$arch"
}

verify_tls_backend() {
    echo ""
    echo "🔍 Verifying TLS backend in built libraries..."
    local lib="$LIBS_DIR/libmongoc_arm64.a"
    [ -f "$lib" ] || lib="$LIBS_DIR/libmongoc_x86_64.a"
    [ -f "$lib" ] || { echo "   ⚠️  no libmongoc_*.a found"; return; }

    local symbols
    symbols=$(nm "$lib" 2>/dev/null || true)
    if echo "$symbols" | grep -q "_SSL_CTX_new"; then
        echo "   ✅ libmongoc references OpenSSL symbols (SSL_CTX_new)"
    else
        echo "   ❌ libmongoc does NOT reference OpenSSL symbols"
        exit 1
    fi
    if echo "$symbols" | grep -qE "_SSLHandshake|_SSLCreateContext"; then
        echo "   ❌ libmongoc still references Secure Transport symbols"
        exit 1
    fi
    echo "   ✅ libmongoc has no Secure Transport references"
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

verify_tls_backend
verify_deployment_target

echo ""
echo "🎉 Build complete! Libraries in Libs/:"
ls -lh "$LIBS_DIR"/lib{mongoc,bson}*.a 2>/dev/null
