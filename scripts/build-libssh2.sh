#!/usr/bin/env bash
set -eo pipefail


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

LIBSSH2_VERSION="1.11.1"
# shellcheck source=lib/macos.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos.sh"
LIBSSH2_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"

ARCH="${1:-both}"
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

    fetch_openssl

    if [ ! -f "$BUILD_DIR/libssh2-$LIBSSH2_VERSION.tar.gz" ]; then
        curl -fSL "https://github.com/libssh2/libssh2/releases/download/libssh2-$LIBSSH2_VERSION/libssh2-$LIBSSH2_VERSION.tar.gz" \
            -o "$BUILD_DIR/libssh2-$LIBSSH2_VERSION.tar.gz"
    fi
    echo "$LIBSSH2_SHA256  $BUILD_DIR/libssh2-$LIBSSH2_VERSION.tar.gz" | shasum -a 256 -c -

    echo "✅ Sources downloaded"
}

# libssh2 1.11.1 is the newest release and is still vulnerable to CVE-2026-55200 (CVSS 9.2):
# ssh2_transport_read() enforces no upper bound on packet_length, so a malicious server can
# overflow the heap before authentication. Upstream fixed it in 97acf3df with no release cut
# since, so the fix rides as a patch on top of the pinned release tarball. Drop the patch once
# a release contains it.
#
# Patches live in scripts/patches/<library>/ so each build applies only its own. A flat
# directory would hand every patch to every library that calls this.
apply_patches() {
    local source_dir=$1
    local library=$2
    local patch_dir="$SCRIPT_DIR/patches/$library"
    local patch

    [ -d "$patch_dir" ] || return 0

    for patch in "$patch_dir"/*.patch; do
        [ -e "$patch" ] || continue
        echo "🩹 Applying $(basename "$patch") to $library"
        patch -p1 -d "$source_dir" -i "$patch"
    done
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

    apply_patches "$BUILD_DIR/libssh2-$LIBSSH2_VERSION-$arch" libssh2

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
    local dest="$REPO_ROOT/TablePro/Core/SSH/CLibSSH2/include"

    echo "📦 Installing libssh2 headers..."

    mkdir -p "$dest"
    cp "$prefix/include/libssh2.h" "$dest/"
    cp "$prefix/include/libssh2_sftp.h" "$dest/"
    cp "$prefix/include/libssh2_publickey.h" "$dest/"

    echo "✅ Headers installed to $dest"
}

build_for_arch() {
    local arch=$1
    build_openssl "$arch"
    build_libssh2 "$arch"
    install_libs "$arch"
    install_headers "$arch"
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
        make_universal libssh2
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

verify_deployment_target "$LIBS_DIR"/libssh2_*.a
echo ""
echo "🎉 Build complete! Libraries in Libs/:"
ls -lh "$LIBS_DIR"/libssh2*.a 2>/dev/null
