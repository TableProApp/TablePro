#!/usr/bin/env bash
set -eo pipefail

# Build static hiredis (with SSL support) for TablePro
#
# Produces architecture-specific and universal static libraries in Libs/:
#   libhiredis_arm64.a, libhiredis_x86_64.a, libhiredis_universal.a
#   libhiredis_ssl_arm64.a, libhiredis_ssl_x86_64.a, libhiredis_ssl_universal.a
#
# OpenSSL is built from source to match the app's deployment target,
# preventing "Symbol not found" crashes from Homebrew-built libraries.
#
# All libraries are built with MACOSX_DEPLOYMENT_TARGET=14.0 to match
# the app's minimum deployment target.
#
# Usage:
#   ./scripts/build-hiredis.sh [arm64|x86_64|both]
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - CMake (brew install cmake)
#   - curl (for downloading source tarballs)

# shellcheck source=lib/macos.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos.sh"

HIREDIS_VERSION="1.2.0"
HIREDIS_SHA256="82ad632d31ee05da13b537c124f819eb88e18851d9cb0c30ae0552084811588c"

ARCH="${1:-both}"
# The headers the Redis plugin compiles against. The old path under TablePro/Core/Database was
# deleted when the driver moved into a plugin bundle, so this script was installing them where
# nothing read them and leaving the real ones untouched.
HEADER_DIR="$REPO_ROOT/Plugins/RedisDriverPlugin/CRedis/include/hiredis"
make_build_dir

echo "🔧 Building static hiredis $HIREDIS_VERSION + OpenSSL $OPENSSL_VERSION"
echo "   Deployment target: macOS $DEPLOY_TARGET"
echo "   Architecture: $ARCH"
echo "   Build dir: $BUILD_DIR"
echo ""


download_sources() {
    echo "📥 Downloading source tarballs..."

    fetch_openssl

    if [ ! -f "$BUILD_DIR/hiredis-$HIREDIS_VERSION.tar.gz" ]; then
        curl -fSL "https://github.com/redis/hiredis/archive/refs/tags/v$HIREDIS_VERSION.tar.gz" \
            -o "$BUILD_DIR/hiredis-$HIREDIS_VERSION.tar.gz"
    fi
    echo "$HIREDIS_SHA256  $BUILD_DIR/hiredis-$HIREDIS_VERSION.tar.gz" | shasum -a 256 -c -

    echo "✅ Sources downloaded"
}

build_hiredis() {
    local arch=$1
    local openssl_prefix="$BUILD_DIR/install-openssl-$arch"
    local prefix="$BUILD_DIR/install-hiredis-$arch"

    echo ""
    echo "🔨 Building hiredis $HIREDIS_VERSION for $arch..."

    # Extract fresh copy for this arch
    rm -rf "$BUILD_DIR/hiredis-$HIREDIS_VERSION-$arch"
    mkdir -p "$BUILD_DIR/hiredis-$HIREDIS_VERSION-$arch"
    tar xzf "$BUILD_DIR/hiredis-$HIREDIS_VERSION.tar.gz" -C "$BUILD_DIR/hiredis-$HIREDIS_VERSION-$arch" --strip-components=1

    local build_dir="$BUILD_DIR/hiredis-$HIREDIS_VERSION-$arch/cmake-build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    # Resolve OpenSSL library path (may be lib/ or lib64/)
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
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_SSL=ON \
        -DDISABLE_TESTS=ON \
        -DENABLE_EXAMPLES=OFF \
        -DOPENSSL_ROOT_DIR="$openssl_prefix" \
        -DOPENSSL_INCLUDE_DIR="$openssl_prefix/include" \
        -DOPENSSL_SSL_LIBRARY="$openssl_lib_dir/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$openssl_lib_dir/libcrypto.a"

    run_quiet cmake --build . --parallel "$NCPU"
    run_quiet cmake --install .

    echo "✅ hiredis $arch: $(ls -lh "$prefix/lib/libhiredis.a" | awk '{print $5}') (libhiredis) $(ls -lh "$prefix/lib/libhiredis_ssl.a" | awk '{print $5}') (libhiredis_ssl)"
}

install_libs() {
    local arch=$1
    local prefix="$BUILD_DIR/install-hiredis-$arch"

    echo "📦 Installing $arch libraries to Libs/..."

    # Find the actual lib directory (may be lib/ or lib64/)
    local lib_dir="$prefix/lib"
    if [ -f "$prefix/lib64/libhiredis.a" ]; then
        lib_dir="$prefix/lib64"
    fi

    cp "$lib_dir/libhiredis.a" "$LIBS_DIR/libhiredis_${arch}.a"
    cp "$lib_dir/libhiredis_ssl.a" "$LIBS_DIR/libhiredis_ssl_${arch}.a"
}

install_headers() {
    local arch=$1
    local prefix="$BUILD_DIR/install-hiredis-$arch"
    local dest="$HEADER_DIR"

    echo "📦 Installing hiredis headers..."

    mkdir -p "$dest"
    cp "$prefix/include/hiredis/"*.h "$dest/"

    echo "✅ Headers installed to $dest"
}

build_for_arch() {
    local arch=$1
    build_openssl "$arch"
    build_hiredis "$arch"
    install_libs "$arch"
    # Install headers once (they're arch-independent)
    if [ ! -f "$HEADER_DIR/hiredis.h" ]; then
        install_headers "$arch"
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
        make_universal libhiredis libhiredis_ssl
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

verify_deployment_target "$LIBS_DIR"/libhiredis_*.a "$LIBS_DIR"/libhiredis_ssl_*.a

echo ""
echo "🎉 Build complete! Libraries in Libs/:"
ls -lh "$LIBS_DIR"/lib{hiredis,hiredis_ssl}*.a 2>/dev/null
