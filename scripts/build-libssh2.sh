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

# Build static libssh2 (with OpenSSL backend) for TablePro
#
# Produces architecture-specific and universal static libraries in Libs/:
#   libssh2_arm64.a, libssh2_x86_64.a, libssh2_universal.a
#
# OpenSSL is built from source to match the app's deployment target,
# preventing "Symbol not found" crashes from Homebrew-built libraries.
#
# All libraries are built with MACOSX_DEPLOYMENT_TARGET=14.0 to match
# the app's minimum deployment target.
#
# Usage:
#   ./scripts/build-libssh2.sh [arm64|x86_64|both]
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - CMake (brew install cmake)
#   - curl (for downloading source tarballs)

DEPLOY_TARGET="14.0"
LIBSSH2_VERSION="1.11.1"
OPENSSL_VERSION="3.4.1"
OPENSSL_SHA256="002a2d6b30b58bf4bea46c43bdd96365aaf8daa6c428782aa4feee06da197df3"
LIBSSH2_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"

ARCH="${1:-both}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBS_DIR="$PROJECT_DIR/Libs"
BUILD_DIR="$(mktemp -d)"
NCPU=$(sysctl -n hw.ncpu)

echo "🔧 Building static libssh2 $LIBSSH2_VERSION + OpenSSL $OPENSSL_VERSION"
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

    if [ ! -f "$BUILD_DIR/libssh2-$LIBSSH2_VERSION.tar.gz" ]; then
        curl -fSL "https://github.com/libssh2/libssh2/releases/download/libssh2-$LIBSSH2_VERSION/libssh2-$LIBSSH2_VERSION.tar.gz" \
            -o "$BUILD_DIR/libssh2-$LIBSSH2_VERSION.tar.gz"
    fi
    echo "$LIBSSH2_SHA256  $BUILD_DIR/libssh2-$LIBSSH2_VERSION.tar.gz" | shasum -a 256 -c -

    echo "✅ Sources downloaded"
}

build_openssl() {
    local arch=$1
    local prefix="$BUILD_DIR/install-openssl-$arch"

    echo ""
    echo "🔨 Building OpenSSL $OPENSSL_VERSION for $arch..."

    # Extract fresh copy for this arch
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
    ./Configure \
        "$target" \
        no-shared \
        no-tests \
        no-apps \
        no-docs \
        --prefix="$prefix" \
        -mmacosx-version-min=$DEPLOY_TARGET > /dev/null 2>&1

    run_quiet make -j"$NCPU"
    run_quiet make install_sw

    echo "✅ OpenSSL $arch: $(ls -lh "$prefix/lib/libssl.a" | awk '{print $5}') (libssl) $(ls -lh "$prefix/lib/libcrypto.a" | awk '{print $5}') (libcrypto)"
}

build_libssh2() {
    local arch=$1
    local openssl_prefix="$BUILD_DIR/install-openssl-$arch"
    local prefix="$BUILD_DIR/install-libssh2-$arch"

    echo ""
    echo "🔨 Building libssh2 $LIBSSH2_VERSION for $arch..."

    # Extract fresh copy for this arch
    rm -rf "$BUILD_DIR/libssh2-$LIBSSH2_VERSION-$arch"
    mkdir -p "$BUILD_DIR/libssh2-$LIBSSH2_VERSION-$arch"
    tar xzf "$BUILD_DIR/libssh2-$LIBSSH2_VERSION.tar.gz" -C "$BUILD_DIR/libssh2-$LIBSSH2_VERSION-$arch" --strip-components=1

    local build_dir="$BUILD_DIR/libssh2-$LIBSSH2_VERSION-$arch/cmake-build"
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
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF \
        -DCRYPTO_BACKEND=OpenSSL \
        -DENABLE_ZLIB_COMPRESSION=OFF \
        -DOPENSSL_ROOT_DIR="$openssl_prefix" \
        -DOPENSSL_INCLUDE_DIR="$openssl_prefix/include" \
        -DOPENSSL_SSL_LIBRARY="$openssl_lib_dir/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$openssl_lib_dir/libcrypto.a"

    run_quiet cmake --build . --parallel "$NCPU"
    run_quiet cmake --install .

    echo "✅ libssh2 $arch: $(ls -lh "$prefix/lib/libssh2.a" | awk '{print $5}') (libssh2)"
}

install_libs() {
    local arch=$1
    local prefix="$BUILD_DIR/install-libssh2-$arch"

    echo "📦 Installing $arch libraries to Libs/..."

    # Find the actual lib directory (may be lib/ or lib64/)
    local lib_dir="$prefix/lib"
    if [ -f "$prefix/lib64/libssh2.a" ]; then
        lib_dir="$prefix/lib64"
    fi

    cp "$lib_dir/libssh2.a" "$LIBS_DIR/libssh2_${arch}.a"
}

install_headers() {
    local arch=$1
    local prefix="$BUILD_DIR/install-libssh2-$arch"
    local dest="$PROJECT_DIR/TablePro/Core/SSH/CLibSSH2/include"

    echo "📦 Installing libssh2 headers..."

    mkdir -p "$dest"
    cp "$prefix/include/libssh2.h" "$dest/"
    cp "$prefix/include/libssh2_sftp.h" "$dest/"
    cp "$prefix/include/libssh2_publickey.h" "$dest/"

    echo "✅ Headers installed to $dest"
}

create_universal() {
    echo ""
    echo "🔗 Creating universal (fat) library..."
    if [ -f "$LIBS_DIR/libssh2_arm64.a" ] && [ -f "$LIBS_DIR/libssh2_x86_64.a" ]; then
        lipo -create \
            "$LIBS_DIR/libssh2_arm64.a" \
            "$LIBS_DIR/libssh2_x86_64.a" \
            -output "$LIBS_DIR/libssh2_universal.a"
        echo "   libssh2_universal.a ($(ls -lh "$LIBS_DIR/libssh2_universal.a" | awk '{print $5}'))"
    fi
}

build_for_arch() {
    local arch=$1
    build_openssl "$arch"
    build_libssh2 "$arch"
    install_libs "$arch"
    install_headers "$arch"
}

verify_deployment_target() {
    echo ""
    echo "🔍 Verifying deployment targets..."
    local failed=0
    for lib in "$LIBS_DIR"/libssh2_*.a; do
        [ -f "$lib" ] || continue
        local name min_ver
        name=$(basename "$lib")
        min_ver=$(otool -l "$lib" 2>/dev/null | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; found=0}' | sort -V | tail -1)
        if [ -z "$min_ver" ]; then
            min_ver=$(otool -l "$lib" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{found=1} found && /version/{print $2; found=0}' | sort -V | tail -1)
        fi
        if [ -n "$min_ver" ]; then
            if [ "$(printf '%s\n' "$DEPLOY_TARGET" "$min_ver" | sort -V | tail -1)" != "$DEPLOY_TARGET" ]; then
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
ls -lh "$LIBS_DIR"/libssh2*.a 2>/dev/null
