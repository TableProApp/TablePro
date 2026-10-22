# macOS-only helpers for the native library build scripts.
#
# Sourced, never executed. A macOS build script picks this up with:
#
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos.sh"
#
# and gets everything in common.sh with it. The iOS scripts source common.sh directly, because a
# darwin64 OpenSSL target and a macOS deployment floor mean nothing to them.
#
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034  # DEPLOY_TARGET is read by the scripts that source this

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

source "$TABLEPRO_LIB_DIR/deployment-target.sh"

make_universal() {
    local lib
    for lib in "$@"; do
        if [ ! -f "$LIBS_DIR/${lib}_arm64.a" ] || [ ! -f "$LIBS_DIR/${lib}_x86_64.a" ]; then
            continue
        fi
        lipo -create \
            "$LIBS_DIR/${lib}_arm64.a" \
            "$LIBS_DIR/${lib}_x86_64.a" \
            -output "$LIBS_DIR/${lib}_universal.a"
        if ! [ "$LIBS_DIR/${lib}_universal.a" -ef "$LIBS_DIR/${lib}.a" ]; then
            cp "$LIBS_DIR/${lib}_universal.a" "$LIBS_DIR/${lib}.a"
        fi
        echo "   ${lib}_universal.a ($(du -h "$LIBS_DIR/${lib}_universal.a" | cut -f1))"
    done
}

fetch_openssl() {
    local tarball="$BUILD_DIR/openssl-$OPENSSL_VERSION.tar.gz"
    if [ ! -f "$tarball" ]; then
        echo "⬇️  Downloading OpenSSL $OPENSSL_VERSION..."
        curl -fSL "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
            -o "$tarball"
    fi
    # Verified on every call, not only after a download, so a cached tarball is checked too.
    verify_sha256 "$tarball" "$OPENSSL_SHA256"
}

# Expects BUILD_DIR, NCPU and the tarball fetched by fetch_openssl.
build_openssl() {
    local arch="$1"
    local prefix="$BUILD_DIR/install-openssl-$arch"
    local source_dir="$BUILD_DIR/openssl-$OPENSSL_VERSION-$arch"

    echo ""
    echo "🔨 Building OpenSSL $OPENSSL_VERSION for $arch..."

    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    tar xzf "$BUILD_DIR/openssl-$OPENSSL_VERSION.tar.gz" -C "$source_dir" --strip-components=1
    cd "$source_dir" || return 1

    local target="darwin64-x86_64-cc"
    [ "$arch" = "arm64" ] && target="darwin64-arm64-cc"

    MACOSX_DEPLOYMENT_TARGET=$DEPLOY_TARGET \
        run_quiet ./Configure \
        "$target" \
        no-shared \
        no-tests \
        no-apps \
        no-docs \
        --prefix="$prefix" \
        "-mmacosx-version-min=$DEPLOY_TARGET"

    run_quiet make -j"$NCPU"
    run_quiet make install_sw

    echo "✅ OpenSSL $arch: $(du -h "$prefix/lib/libssl.a" | cut -f1) (libssl) $(du -h "$prefix/lib/libcrypto.a" | cut -f1) (libcrypto)"
}

# The trap body is single-quoted so it reads BUILD_DIR when it fires, not when it is installed.
# It replaces any EXIT trap already in place, so a script that needs to remove more than this
# directory installs its own instead (build-freetds.sh does, for its tarball cache).
make_build_dir() {
    BUILD_DIR="$(mktemp -d)"
    trap 'rm -rf "$BUILD_DIR"' EXIT
}

# The SDK answers <gssapi.h> and <gssapi/gssapi.h> with the Kerberos.framework header, whose name
# types are data symbols of Kerberos.framework. Both point at the GSS framework's header here, so
# every GSS reference in the archive resolves against `-framework GSS`. Its guard keeps out
# gssapi_apple.h: neither library uses those extensions, and the CoreFoundation they pull in
# typedefs a Size that clashes with PostgreSQL's.
make_gss_include_dir() {
    local dir="$1" shim
    shim=$'#define __gssapi_apple_h__\n#include <GSS/gssapi.h>\n'
    mkdir -p "$dir/gssapi"
    printf '%s' "$shim" > "$dir/gssapi.h"
    printf '%s' "$shim" > "$dir/gssapi/gssapi.h"
}

NCPU="$(sysctl -n hw.ncpu)"
