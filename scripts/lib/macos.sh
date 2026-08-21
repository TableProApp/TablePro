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

# The app's floor, and the only place it is written down for these scripts. Configs/Base.xcconfig
# holds the same number for the Xcode build.
DEPLOY_TARGET="14.0"

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

# Reads the macOS version a Mach-O was built for. Prefers LC_BUILD_VERSION and falls back to the
# older LC_VERSION_MIN_MACOSX. `tail -1` takes the highest across the archive's members, which is
# the one that decides whether the whole library can run on the app's floor.
macho_min_version() {
    local lib="$1" version
    version=$(otool -l "$lib" 2>/dev/null |
        awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; found=0}' | sort -V | tail -1)
    if [ -z "$version" ]; then
        version=$(otool -l "$lib" 2>/dev/null |
            awk '/LC_VERSION_MIN_MACOSX/{found=1} found && /version/{print $2; found=0}' | sort -V | tail -1)
    fi
    printf '%s' "$version"
}

# Fails if any given library was built for a NEWER macOS than the app supports.
#
# The direction matters and three copies had it backwards. A library built for an older macOS is
# fine, it simply supports more systems; one built for a newer macOS cannot run on the app's floor.
# `max(target, minos) == target` is the question. The inverted form passed exactly the libraries
# that break.
verify_deployment_target() {
    local lib name version failed=0
    echo ""
    echo "🔍 Verifying deployment targets..."
    for lib in "$@"; do
        [ -f "$lib" ] || continue
        name=$(basename "$lib")
        version=$(macho_min_version "$lib")
        [ -n "$version" ] || continue
        if [ "$(printf '%s\n' "$DEPLOY_TARGET" "$version" | sort -V | tail -1)" != "$DEPLOY_TARGET" ]; then
            echo "   ❌ $name targets macOS $version (expected $DEPLOY_TARGET)"
            failed=1
        else
            echo "   ✅ $name targets macOS $version"
        fi
    done
    if [ "$failed" -eq 1 ]; then
        echo "❌ FATAL: some libraries have incorrect deployment targets" >&2
        return 1
    fi
}

OPENSSL_VERSION="3.4.3"
OPENSSL_SHA256="fa727ed1399a64e754030a033435003991aee36bda9a5b080995cb2ac5cf7f37"

# Downloads the OpenSSL tarball into BUILD_DIR once, verified against the pin above.
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

# Builds static OpenSSL for one architecture into $BUILD_DIR/install-openssl-<arch>.
#
# Expects BUILD_DIR, NCPU and the tarball fetched by fetch_openssl. Configure runs through
# run_quiet rather than being redirected to /dev/null: three copies discarded its output entirely,
# so a configure failure produced a bare non-zero exit with nothing to read.
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
