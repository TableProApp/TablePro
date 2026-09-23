#!/usr/bin/env bash
set -euo pipefail

# Build the SQLite static library the SQLite and libSQL plugins link.
#
# Usage: ./scripts/build-sqlite.sh [arm64|x86_64|both]
#
# Produces Libs/libsqlite3_vendored_{arm64,x86_64,universal}.a and Libs/libsqlite3_vendored.a,
# and installs the matching sqlite3.h into the CSQLite module in Packages/TableProCore.
#
# macOS's own libsqlite3 is compiled with SQLITE_OMIT_LOAD_EXTENSION: sqlite3_load_extension is
# neither declared in the SDK header nor exported from the dylib, so a plugin that links it can
# never load sqlite-vec, SpatiaLite or any other extension. This build keeps extension loading and
# otherwise carries the options the system build offers, so switching the plugins over takes
# nothing away. ENABLE_FTS3_TOKENIZER is left out on purpose: it lets SQL register an arbitrary
# pointer as a tokenizer.
#
# It builds from the canonical source tree rather than the published amalgamation, because
# ENABLE_UPDATE_DELETE_LIMIT changes the generated parser and the amalgamation ships without it.
#
# The archive is named libsqlite3_vendored, never libsqlite3: several plugin targets put Libs/ on
# their library search path, and an archive called libsqlite3.a there would win a -lsqlite3 lookup
# over the SDK's dylib.
#
# Symbols are hidden, so neither plugin bundle exports a second sqlite3_open into the process. A
# loadable extension reaches SQLite through the sqlite3_api_routines table it is handed, never by
# symbol, so hiding them costs it nothing.
#
# After building, check it and publish it (never regenerate Libs/checksums.sha256 by hand):
#   scripts/check-sqlite-build.sh
#   scripts/publish-libs.sh libsqlite3_vendored_arm64.a libsqlite3_vendored_x86_64.a \
#       libsqlite3_vendored_universal.a libsqlite3_vendored.a

# shellcheck source=lib/macos.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos.sh"

# Digest computed locally: sqlite.org publishes only SHA3-256, which shasum cannot check. The
# download was verified against the published SHA3-256
# b834d474b9b393d85a9e3ee4cc11f1329e007e9376a424ee740796f5c4bda3a8 before this was pinned.
SQLITE_VERSION="3.53.4"
SQLITE_RELEASE_YEAR="2026"
SQLITE_SHA256="d18fa15aec74d8c17e1463f861095adc01b5ad190256acb4f91d22f0368d232b"

ARCH="${1:-both}"
LIB_NAME="libsqlite3_vendored"
HEADER_DIR="$REPO_ROOT/Packages/TableProCore/Sources/CSQLite/include"

SQLITE_OPTIONS=(
    -DSQLITE_THREADSAFE=2
    -DSQLITE_DQS=3
    -DSQLITE_DEFAULT_MEMSTATUS=0
    -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1
    -DSQLITE_DEFAULT_CKPTFULLFSYNC=1
    -DSQLITE_DEFAULT_JOURNAL_SIZE_LIMIT=32768
    -DSQLITE_MAX_VARIABLE_NUMBER=500000
    -DSQLITE_USE_URI=1
    -DSQLITE_ENABLE_LOCKING_STYLE=1
    -DSQLITE_ENABLE_API_ARMOR
    -DSQLITE_ENABLE_BYTECODE_VTAB
    -DSQLITE_ENABLE_CARRAY
    -DSQLITE_ENABLE_COLUMN_METADATA
    -DSQLITE_ENABLE_DBSTAT_VTAB
    -DSQLITE_ENABLE_FTS3
    -DSQLITE_ENABLE_FTS3_PARENTHESIS
    -DSQLITE_ENABLE_FTS4
    -DSQLITE_ENABLE_FTS5
    -DSQLITE_ENABLE_MATH_FUNCTIONS
    -DSQLITE_ENABLE_NORMALIZE
    -DSQLITE_ENABLE_PERCENTILE
    -DSQLITE_ENABLE_PREUPDATE_HOOK
    -DSQLITE_ENABLE_RTREE
    -DSQLITE_ENABLE_SESSION
    -DSQLITE_ENABLE_SNAPSHOT
    -DSQLITE_ENABLE_STMT_SCANSTATUS
    -DSQLITE_ENABLE_UNKNOWN_SQL_FUNCTION
    -DSQLITE_ENABLE_UPDATE_DELETE_LIMIT
    -DHAVE_USLEEP=1
)

make_build_dir

echo "🔧 Building SQLite $SQLITE_VERSION"
echo "   Deployment target: macOS $DEPLOY_TARGET"
echo "   Architecture: $ARCH"
echo "   Build dir: $BUILD_DIR"

source_zip_name() {
    local major minor patch
    IFS=. read -r major minor patch <<< "$SQLITE_VERSION"
    printf 'sqlite-src-%d%02d%02d00.zip' "$major" "$minor" "$patch"
}

generate_amalgamation() {
    local zip
    zip="$(source_zip_name)"
    echo ""
    echo "📥 Downloading $zip..."
    curl -fSL "https://sqlite.org/$SQLITE_RELEASE_YEAR/$zip" -o "$BUILD_DIR/$zip"
    verify_sha256 "$BUILD_DIR/$zip" "$SQLITE_SHA256"

    echo "🔨 Generating the amalgamation with UPDATE/DELETE ... LIMIT..."
    (cd "$BUILD_DIR" && unzip -q "$zip")
    local source_dir="$BUILD_DIR/${zip%.zip}"
    (cd "$source_dir" && run_quiet ./configure --enable-update-limit && run_quiet make sqlite3.c)
    cp "$source_dir/sqlite3.c" "$source_dir/sqlite3.h" "$source_dir/sqlite3ext.h" "$BUILD_DIR/"
}

build_arch() {
    local arch="$1"
    echo ""
    echo "🔨 Compiling SQLite for $arch..."
    xcrun clang -c "$BUILD_DIR/sqlite3.c" -o "$BUILD_DIR/sqlite3_$arch.o" \
        -arch "$arch" \
        -mmacosx-version-min="$DEPLOY_TARGET" \
        -O2 \
        -fvisibility=hidden \
        "${SQLITE_OPTIONS[@]}"
    rm -f "$LIBS_DIR/${LIB_NAME}_$arch.a"
    ZERO_AR_DATE=1 xcrun ar rcs "$LIBS_DIR/${LIB_NAME}_$arch.a" "$BUILD_DIR/sqlite3_$arch.o"
    echo "✅ ${LIB_NAME}_$arch.a ($(du -h "$LIBS_DIR/${LIB_NAME}_$arch.a" | cut -f1))"
}

# sqlite3ext.h is installed beside sqlite3.h for scripts/check-sqlite-build.sh, which builds a
# test extension against it. The module map names only sqlite3.h, because sqlite3ext.h redefines
# every sqlite3_ function as a macro through the extension API table.
install_headers() {
    mkdir -p "$HEADER_DIR"
    cp "$BUILD_DIR/sqlite3.h" "$BUILD_DIR/sqlite3ext.h" "$HEADER_DIR/"
    echo "📦 Installed sqlite3.h and sqlite3ext.h into ${HEADER_DIR#"$REPO_ROOT"/}"
}

mkdir -p "$LIBS_DIR"
generate_amalgamation

case "$ARCH" in
    arm64 | x86_64)
        build_arch "$ARCH"
        cp "$LIBS_DIR/${LIB_NAME}_$ARCH.a" "$LIBS_DIR/$LIB_NAME.a"
        ;;
    both)
        build_arch arm64
        build_arch x86_64
        make_universal "$LIB_NAME"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

install_headers
verify_deployment_target "$LIBS_DIR"/"$LIB_NAME"*.a

echo ""
echo "🎉 SQLite $SQLITE_VERSION built. Next: scripts/check-sqlite-build.sh"
