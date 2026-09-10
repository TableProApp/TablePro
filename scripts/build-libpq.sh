#!/usr/bin/env bash
set -eo pipefail


# Build static libpq and OpenSSL for TablePro
#
# Produces architecture-specific and universal static libraries in Libs/:
#   libpq_arm64.a, libpq_x86_64.a, libpq_universal.a
#   libssl_arm64.a, libssl_x86_64.a, libssl_universal.a
#   libcrypto_arm64.a, libcrypto_x86_64.a, libcrypto_universal.a
#   libpgcommon_arm64.a, libpgcommon_x86_64.a, libpgcommon_universal.a
#   libpgport_arm64.a, libpgport_x86_64.a, libpgport_universal.a
#
# All libraries are built with MACOSX_DEPLOYMENT_TARGET=14.0 to match
# the app's minimum deployment target. This prevents the "Symbol not found"
# crash (e.g. _strchrnul) that occurs when Homebrew libraries built for
# the host OS are bundled into the app.
#
# Usage:
#   ./scripts/build-libpq.sh [arm64|x86_64|both]
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - curl (for downloading source tarballs)

PG_VERSION="17.4"
# shellcheck source=lib/macos.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos.sh"
PG_SHA256="c4605b73fea11963406699f949b966e5d173a7ee0ccaef8938dec0ca8a995fe7"

ARCH="${1:-both}"
# The PostgreSQL driver became a plugin, and its headers moved with it. This pointed at
# TablePro/Core/Database/CLibPQ/include, which no longer exists, so every rebuild recreated a dead
# directory and never updated the headers the plugin actually compiles against.
HEADER_DIR="$REPO_ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ/include"
make_build_dir

echo "🔧 Building static libpq $PG_VERSION + OpenSSL $OPENSSL_VERSION"
echo "   Deployment target: macOS $DEPLOY_TARGET"
echo "   Architecture: $ARCH"
echo "   Build dir: $BUILD_DIR"
echo ""


download_sources() {
    echo "📥 Downloading source tarballs..."

    fetch_openssl

    if [ ! -f "$BUILD_DIR/postgresql-$PG_VERSION.tar.bz2" ]; then
        curl -fSL "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2" \
            -o "$BUILD_DIR/postgresql-$PG_VERSION.tar.bz2"
    fi
    echo "$PG_SHA256  $BUILD_DIR/postgresql-$PG_VERSION.tar.bz2" | shasum -a 256 -c -

    echo "✅ Sources downloaded"
}

build_libpq() {
    local arch=$1
    local openssl_prefix="$BUILD_DIR/install-openssl-$arch"
    local prefix="$BUILD_DIR/install-libpq-$arch"

    echo ""
    echo "🔨 Building libpq (PostgreSQL $PG_VERSION) for $arch..."

    # Extract fresh copy for this arch
    rm -rf "$BUILD_DIR/postgresql-$PG_VERSION-$arch"
    mkdir -p "$BUILD_DIR/postgresql-$PG_VERSION-$arch"
    tar xjf "$BUILD_DIR/postgresql-$PG_VERSION.tar.bz2" -C "$BUILD_DIR/postgresql-$PG_VERSION-$arch" --strip-components=1

    cd "$BUILD_DIR/postgresql-$PG_VERSION-$arch"

    local host
    if [ "$arch" = "arm64" ]; then
        host="aarch64-apple-darwin"
    else
        host="x86_64-apple-darwin"
    fi

    # Tell configure strchrnul is available. PG will use an extern declaration
    # instead of its own static inline (which conflicts with the macOS SDK's
    # non-static declaration). We provide our own implementation below.
    MACOSX_DEPLOYMENT_TARGET=$DEPLOY_TARGET \
    CFLAGS="-arch $arch -mmacosx-version-min=$DEPLOY_TARGET -Wno-unguarded-availability-new -I$openssl_prefix/include" \
    LDFLAGS="-arch $arch -L$openssl_prefix/lib" \
    PKG_CONFIG_PATH="$openssl_prefix/lib64/pkgconfig:$openssl_prefix/lib/pkgconfig" \
    ac_cv_func_strchrnul=yes \
    ./configure \
        --prefix="$prefix" \
        --host="$host" \
        --with-ssl=openssl \
        --without-readline \
        --without-icu \
        --without-gssapi > /dev/null 2>&1

    # Provide strchrnul implementation for macOS < 15.4 (where it doesn't exist
    # in the system library). This gets archived into libpgport.a so the final
    # binary has the symbol available at link time.
    cat > src/port/strchrnul_compat.c << 'COMPAT_EOF'
#include <stddef.h>
char *strchrnul(const char *s, int c) {
    while (*s && *s != (char)c) s++;
    return (char *)s;
}
COMPAT_EOF

    # Build only static libraries (skip dylib which fails in cross-compilation)
    run_quiet make -C src/include -j"$NCPU"
    run_quiet make -C src/common -j"$NCPU"
    run_quiet make -C src/port -j"$NCPU"
    run_quiet make -C src/interfaces/libpq all-static-lib -j"$NCPU"

    # Compile and add strchrnul compat to both libpgport variants
    cc -arch "$arch" -mmacosx-version-min="$DEPLOY_TARGET" \
        -c -o src/port/strchrnul_compat.o src/port/strchrnul_compat.c
    run_quiet ar rs src/port/libpgport_shlib.a src/port/strchrnul_compat.o

    mkdir -p "$prefix/lib"
    cp src/interfaces/libpq/libpq.a "$prefix/lib/"
    # Use the _shlib variants: they export nominal function names (e.g.
    # pg_char_to_encoding) that libpq expects. The non-shlib variants
    # export _private-suffixed names meant for standalone frontend tools.
    cp src/common/libpgcommon_shlib.a "$prefix/lib/libpgcommon.a"
    cp src/port/libpgport_shlib.a "$prefix/lib/libpgport.a"

    echo "✅ libpq $arch: $(ls -lh "$prefix/lib/libpq.a" | awk '{print $5}') (libpq) $(ls -lh "$prefix/lib/libpgcommon.a" | awk '{print $5}') (pgcommon) $(ls -lh "$prefix/lib/libpgport.a" | awk '{print $5}') (pgport)"
}

install_libs() {
    local arch=$1
    local openssl_prefix="$BUILD_DIR/install-openssl-$arch"
    local libpq_prefix="$BUILD_DIR/install-libpq-$arch"

    echo "📦 Installing $arch libraries to Libs/..."
    cp "$libpq_prefix/lib/libpq.a" "$LIBS_DIR/libpq_${arch}.a"
    cp "$libpq_prefix/lib/libpgcommon.a" "$LIBS_DIR/libpgcommon_${arch}.a"
    cp "$libpq_prefix/lib/libpgport.a" "$LIBS_DIR/libpgport_${arch}.a"
    cp "$openssl_prefix/lib/libssl.a" "$LIBS_DIR/libssl_${arch}.a"
    cp "$openssl_prefix/lib/libcrypto.a" "$LIBS_DIR/libcrypto_${arch}.a"
}

install_headers() {
    local arch=$1
    local pg_src="$BUILD_DIR/postgresql-$PG_VERSION-$arch"
    local dest="$HEADER_DIR"

    echo "📦 Installing libpq headers..."
    mkdir -p "$dest"
    cp "$pg_src/src/interfaces/libpq/libpq-fe.h" "$dest/"
    cp "$pg_src/src/interfaces/libpq/libpq-events.h" "$dest/"
    cp "$pg_src/src/include/postgres_ext.h" "$dest/"
    cp "$pg_src/src/include/pg_config_ext.h" "$dest/"
    echo "✅ Headers installed to $dest"
}

build_for_arch() {
    local arch=$1
    build_openssl "$arch"
    build_libpq "$arch"
    install_libs "$arch"
    # Unconditional. Skipping when a header already exists meant a version bump shipped new
    # binaries against the previous release's headers.
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
        make_universal libpq libpgcommon libpgport libssl libcrypto
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

verify_deployment_target "$LIBS_DIR"/libpq_*.a "$LIBS_DIR"/libpgcommon_*.a "$LIBS_DIR"/libpgport_*.a "$LIBS_DIR"/libssl_*.a "$LIBS_DIR"/libcrypto_*.a
echo ""
echo "🎉 Build complete! Libraries in Libs/:"
ls -lh "$LIBS_DIR"/lib{pq,pgcommon,pgport,ssl,crypto}*.a 2>/dev/null
