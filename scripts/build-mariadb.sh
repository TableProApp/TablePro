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
# MariaDB publishes a digest for this tarball independently of the tarball itself, at
# https://archive.mariadb.org/connector-c-$MARIADB_VERSION/sha256sums.txt, which is why the source
# moved here from the GitHub tag archive: GitHub publishes no digest, so pinning one would only
# record whatever was served the first time anybody looked. Note the upstream tarball unpacks to a
# "-src" directory, unlike the GitHub one.
MARIADB_SHA256="58876fad1c2d33979d78bbfa61d7a3476e8faa2cd0af0f7f8bfeb06deaa1034e"
OPENSSL_ROOT="${OPENSSL_ROOT:-$(brew --prefix openssl@3 2>/dev/null || true)}"

# shellcheck source=lib/macos.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBS_DIR="$PROJECT_DIR/Libs"
BUILD_DIR="$(mktemp -d)"
NCPU=$(sysctl -n hw.ncpu)

if [ -z "$OPENSSL_ROOT" ] || [ ! -d "$OPENSSL_ROOT" ]; then
    echo "ERROR: OpenSSL 3 not found. Install with 'brew install openssl@3' or set OPENSSL_ROOT." >&2
    exit 1
fi

cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

echo "Building MariaDB Connector/C $MARIADB_VERSION for macOS (OpenSSL: $OPENSSL_ROOT)"

echo "=> Downloading source..."
curl -fSL "https://archive.mariadb.org/connector-c-$MARIADB_VERSION/mariadb-connector-c-$MARIADB_VERSION-src.tar.gz" \
    -o "$BUILD_DIR/mariadb.tar.gz"
echo "$MARIADB_SHA256  $BUILD_DIR/mariadb.tar.gz" | shasum -a 256 -c -
tar xzf "$BUILD_DIR/mariadb.tar.gz" -C "$BUILD_DIR"
MARIADB_SRC="$BUILD_DIR/mariadb-connector-c-$MARIADB_VERSION-src"

build_slice() {
    local ARCH=$1
    local SRC_COPY="$BUILD_DIR/mariadb-$ARCH"
    cp -R "$MARIADB_SRC" "$SRC_COPY"
    local BUILD="$SRC_COPY/cmake-build"
    mkdir -p "$BUILD"; cd "$BUILD"

    echo "=> Building $ARCH..."
    run_quiet cmake .. \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
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

# The cleartext plugin is the whole reason this script exists, so a build without it is a failed
# build, not a warning somebody might read in a 200 line log.
echo "=> Verifying mysql_clear_password is now built in:"
if [ "$(nm "$LIBS_DIR/libmariadb_arm64.a" 2>/dev/null | grep -c "clear_password_client_plugin")" -eq 0 ]; then
    echo "ERROR: mysql_clear_password_client_plugin is missing from the build" >&2
    exit 1
fi
echo "   OK: mysql_clear_password_client_plugin present"
lipo -info "$LIBS_DIR/libmariadb_universal.a"

echo ""
echo "Done. Libs/libmariadb*.a rebuilt with the cleartext plugin."
echo "Next: rebuild the app and test MySQL IAM. When confirmed working, publish the libs:"
echo "  scripts/publish-libs.sh libmariadb_arm64.a libmariadb_x86_64.a libmariadb_universal.a libmariadb.a"
echo "  git add Libs/checksums.sha256 && git commit -m 'build: update static library checksums'"
