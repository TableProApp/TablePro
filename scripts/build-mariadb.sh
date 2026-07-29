#!/usr/bin/env bash
set -eo pipefail

# Build static MariaDB Connector/C for macOS (arm64 + x86_64 + universal).
#
# Includes the mysql_clear_password client plugin (STATIC), required for AWS RDS
# IAM authentication. The previous Libs/libmariadb*.a were built without it, so
# IAM connections failed with "Plugin mysql_clear_password could not be loaded".
#
# Output (overwrites, since Libs/*.a are not in git):
#   Libs/libmariadb_arm64.a  Libs/libmariadb_x86_64.a
#   Libs/libmariadb_universal.a  Libs/libmariadb.a (= universal)
#
# Requires: cmake, OpenSSL 3 (defaults to Homebrew openssl@3; override OPENSSL_ROOT).
# After running: regenerate Libs/checksums.sha256 and re-upload to the libs-v1
# release (see CLAUDE.md "Updating Static Libraries").
#
# Usage: ./scripts/build-mariadb.sh

MARIADB_VERSION="3.4.4"
MIN_MACOS="14.0"
OPENSSL_ROOT="${OPENSSL_ROOT:-$(brew --prefix openssl@3 2>/dev/null || true)}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBS_DIR="$PROJECT_DIR/Libs"
BUILD_DIR="$(mktemp -d)"
NCPU=$(sysctl -n hw.ncpu)

if [ -z "$OPENSSL_ROOT" ] || [ ! -d "$OPENSSL_ROOT" ]; then
    echo "ERROR: OpenSSL 3 not found. Install with 'brew install openssl@3' or set OPENSSL_ROOT." >&2
    exit 1
fi

run_quiet() {
    local logfile
    logfile=$(mktemp)
    if ! "$@" > "$logfile" 2>&1; then
        echo "FAILED: $*"; tail -50 "$logfile"; rm -f "$logfile"; return 1
    fi
    rm -f "$logfile"
}

cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

echo "Building MariaDB Connector/C $MARIADB_VERSION for macOS (OpenSSL: $OPENSSL_ROOT)"

echo "=> Downloading source..."
curl -fSL "https://github.com/mariadb-corporation/mariadb-connector-c/archive/refs/tags/v$MARIADB_VERSION.tar.gz" \
    -o "$BUILD_DIR/mariadb.tar.gz"
tar xzf "$BUILD_DIR/mariadb.tar.gz" -C "$BUILD_DIR"
MARIADB_SRC="$BUILD_DIR/mariadb-connector-c-$MARIADB_VERSION"

build_slice() {
    local ARCH=$1
    local SRC_COPY="$BUILD_DIR/mariadb-$ARCH"
    cp -R "$MARIADB_SRC" "$SRC_COPY"
    local BUILD="$SRC_COPY/cmake-build"
    mkdir -p "$BUILD"; cd "$BUILD"

    echo "=> Building $ARCH..."
    run_quiet cmake .. \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_C_FLAGS="-w -Wno-error -Wno-inline-asm -Wno-deprecated-non-prototype -Wno-macro-redefined" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_EXTERNAL_ZLIB=ON \
        -DWITH_SSL=OPENSSL \
        -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT" \
        -DOPENSSL_SSL_LIBRARY="$OPENSSL_ROOT/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_ROOT/lib/libcrypto.a" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_ROOT/include" \
        -DWITH_UNIT_TESTS=OFF \
        -DWITH_CURL=OFF \
        -DCLIENT_PLUGIN_AUTH_GSSAPI_CLIENT=OFF \
        -DCLIENT_PLUGIN_DIALOG=STATIC \
        -DCLIENT_PLUGIN_MYSQL_CLEAR_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_CACHING_SHA2_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_SHA256_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_MYSQL_NATIVE_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_MYSQL_OLD_PASSWORD=STATIC \
        -DCLIENT_PLUGIN_PVIO_NPIPE=OFF \
        -DCLIENT_PLUGIN_PVIO_SHMEM=OFF

    run_quiet cmake --build . --target mariadbclient -j"$NCPU"
    cp libmariadb/libmariadbclient.a "$BUILD_DIR/libmariadb_$ARCH.a"
    echo "   built libmariadb_$ARCH.a"
}

build_slice arm64
build_slice x86_64

echo "=> Creating universal + installing into Libs/"
cp "$BUILD_DIR/libmariadb_arm64.a" "$LIBS_DIR/libmariadb_arm64.a"
cp "$BUILD_DIR/libmariadb_x86_64.a" "$LIBS_DIR/libmariadb_x86_64.a"
lipo -create "$BUILD_DIR/libmariadb_arm64.a" "$BUILD_DIR/libmariadb_x86_64.a" \
    -output "$LIBS_DIR/libmariadb_universal.a"
cp "$LIBS_DIR/libmariadb_universal.a" "$LIBS_DIR/libmariadb.a"

echo "=> Verifying mysql_clear_password is now built in:"
if [ "$(nm "$LIBS_DIR/libmariadb_arm64.a" 2>/dev/null | grep -c "clear_password_client_plugin")" -gt 0 ]; then
    echo "   OK: mysql_clear_password_client_plugin present"
else
    echo "   WARNING: clear_password plugin symbol not found; check the build" >&2
fi
lipo -info "$LIBS_DIR/libmariadb_universal.a"

echo ""
echo "Done. Libs/libmariadb*.a rebuilt with the cleartext plugin."
echo "Next: rebuild the app and test MySQL IAM. When confirmed working, publish the libs:"
echo "  shasum -a 256 Libs/*.a > Libs/checksums.sha256"
echo "  tar czf /tmp/tablepro-libs-v1.tar.gz -C Libs . && gh release upload libs-v1 /tmp/tablepro-libs-v1.tar.gz --clobber --repo TableProApp/TablePro"
echo "  git add Libs/checksums.sha256 && git commit -m 'build: rebuild libmariadb with cleartext auth plugin'"
