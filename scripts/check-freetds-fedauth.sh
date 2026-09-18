#!/usr/bin/env bash
# Proves scripts/patches/freetds/freetds-fedauth.patch still produces the LOGIN7 bytes
# Microsoft Entra ID authentication needs, and that it leaves password logins alone.
#
# FreeTDS has never implemented the TDS FEDAUTH login extension (upstream issues #360 and
# #509), so TablePro carries its own. There is no live Azure SQL server in CI, so this
# checks the one thing that can be checked without a tenant: the bytes on the wire, against
# MS-TDS 2.2.6.4 and 2.2.6.5.
#
# Builds a throwaway FreeTDS without TLS so the login packet can be read in the clear. The
# FEDAUTH block sits inside the login packet, so it is identical with encryption on.
#
# Run after changing the patch, after bumping FREETDS_VERSION, or before releasing the
# MSSQL driver plugin. It does not touch Libs/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_DIR="$SCRIPT_DIR/freetds-fedauth-check"
PATCH_FILE="$SCRIPT_DIR/patches/freetds/freetds-fedauth.patch"
BUILD_DIR="${TMPDIR:-/tmp}/freetds-fedauth-check"

# single source of truth: the pin the real build uses
FREETDS_VERSION="$(sed -n 's/^FREETDS_VERSION="\(.*\)"$/\1/p' "$SCRIPT_DIR/build-freetds.sh")"
FREETDS_SHA256="$(sed -n 's/^FREETDS_SHA256="\(.*\)"$/\1/p' "$SCRIPT_DIR/build-freetds.sh")"
FREETDS_URL="https://www.freetds.org/files/stable/freetds-${FREETDS_VERSION}.tar.gz"

if [ -z "$FREETDS_VERSION" ] || [ -z "$FREETDS_SHA256" ]; then
    echo "ERROR: could not read the FreeTDS pin from build-freetds.sh" >&2
    exit 1
fi
if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: $PATCH_FILE not found" >&2
    exit 1
fi

SOURCE_DIR="$BUILD_DIR/freetds-${FREETDS_VERSION}"
TARBALL="$BUILD_DIR/freetds-${FREETDS_VERSION}.tar.gz"

echo "==> Checking FreeTDS ${FREETDS_VERSION} FEDAUTH patch"
mkdir -p "$BUILD_DIR"

if [ ! -f "$TARBALL" ]; then
    echo "==> Downloading FreeTDS ${FREETDS_VERSION}..."
    curl -fSL "$FREETDS_URL" -o "$TARBALL"
fi
echo "$FREETDS_SHA256  $TARBALL" | shasum -a 256 -c -

rm -rf "$SOURCE_DIR"
tar xz -C "$BUILD_DIR" -f "$TARBALL"

echo "==> Applying $(basename "$PATCH_FILE")"
patch -p1 -d "$SOURCE_DIR" -i "$PATCH_FILE"

echo "==> Building (no TLS, static, db-lib only)..."
(
    cd "$SOURCE_DIR"
    ./configure --prefix="$BUILD_DIR/install" \
        --disable-odbc --disable-apps --disable-server \
        --without-openssl --without-gnutls --disable-krb5 \
        --disable-shared --enable-static > "$BUILD_DIR/configure.log" 2>&1
    make -j"$(sysctl -n hw.ncpu)" > "$BUILD_DIR/make.log" 2>&1
)

LIBSYBDB="$SOURCE_DIR/src/dblib/.libs/libsybdb.a"
# grep without -q so it drains nm's full output, per the note in build-freetds.sh: under
# `set -o pipefail`, -q closes the pipe on the first match and nm dies with SIGPIPE, which
# reports failure for a perfectly good library.
if ! nm -gU "$LIBSYBDB" 2>/dev/null | grep 'T _dbsetlfedauthtoken' > /dev/null; then
    echo "FAIL: the patched library does not export dbsetlfedauthtoken" >&2
    exit 1
fi
echo "==> libsybdb.a exports dbsetlfedauthtoken"

cc "$CHECK_DIR/fedauth-client.c" -I "$SOURCE_DIR/include" -o "$BUILD_DIR/fedauth-client" \
    "$LIBSYBDB" -liconv -lm

# a token long enough to prove it is not going through dbsetlname, which caps at 128 bytes
TOKEN="eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.$(printf 'A%.0s' $(seq 1 900)).$(printf 'S%.0s' $(seq 1 170))"

run_case() {
    local mode=$1 expect=$2
    shift 2
    python3 "$CHECK_DIR/fake-tds-server.py" "$mode" "$expect" "$BUILD_DIR/results-$mode.json" \
        > "$BUILD_DIR/server-$mode.log" 2>&1 &
    local srv=$!
    local port=""
    for _ in $(seq 1 100); do
        port=$(head -1 "$BUILD_DIR/server-$mode.log" 2>/dev/null)
        [ -n "$port" ] && break
    done
    if [ -z "$port" ]; then
        kill $srv 2>/dev/null || true
        echo "FAIL: harness never reported a port for the $mode case" >&2
        return 1
    fi
    "$BUILD_DIR/fedauth-client" "127.0.0.1:$port" "$@" > "$BUILD_DIR/client-$mode.log" 2>&1 || true

    local rc=0
    wait $srv || rc=$?
    echo ""
    echo "--- $mode ---"
    tail -n +2 "$BUILD_DIR/server-$mode.log"
    return $rc
}

status=0
run_case fedauth "$TOKEN" fedauth "$TOKEN" || status=1
run_case sql "sa" sql "sa" "hunter2" || status=1

echo ""
if [ "$status" -eq 0 ]; then
    echo "✅ FEDAUTH wire format matches MS-TDS, password logins unchanged"
else
    echo "❌ FEDAUTH check failed, see $BUILD_DIR" >&2
fi
exit "$status"
