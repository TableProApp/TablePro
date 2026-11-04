#!/usr/bin/env bash
set -euo pipefail

# Build the DuckDB static library for TablePro's macOS plugin.
#
# Usage: ./scripts/build-duckdb.sh [arm64|x86_64|both]
#
# This compiles DuckDB from source with CMake so the extensions in
# scripts/duckdb-macos-extensions.cmake link in statically. Without them core_functions
# (`sum`, `avg`, `date_trunc` and most of the rest) would download from
# extensions.duckdb.org on first use and fail offline.
#
# Runtime autoloading stays on, unlike the iOS build, so httpfs and quack still
# download on demand for remote Quack connections.
#
# Requirements: macOS, Xcode command line tools, cmake, git, libtool, lipo, python3.
#
# After building, publish with scripts/publish-libs.sh (never regenerate
# Libs/checksums.sha256 by hand):
#   scripts/publish-libs.sh libduckdb_arm64.a libduckdb_x86_64.a libduckdb_universal.a libduckdb.a

DUCKDB_VERSION="v2.0.0"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deployment-target.sh"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$DEPLOY_TARGET}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so a verification run can write somewhere else. Libs/*.a is shared with
# every other checkout on the machine and its checksums are pinned by publish-libs.sh.
LIBS_DIR="${LIBS_DIR:-$REPO_ROOT/Libs}"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
EXTENSION_CONFIG="$REPO_ROOT/scripts/duckdb-macos-extensions.cmake"
ARCH="${1:-both}"
WORK_DIR="${DUCKDB_BUILD_DIR:-$(mktemp -d /tmp/duckdb-macos.XXXXXX)}"

# Linked and registered the way extensions are. httplib is the HTTP client automatic installs
# download with, loadable_extensions loads what they download. local_extension_repository is left
# out: it points automatic installs at the build machine's own extension directory.
CAPABILITIES=(httplib loadable_extensions)
read -r -a EXTENSIONS <<< "$(sed -nE 's/^duckdb_extension_load\(([a-z_]+)\)?.*/\1/p' "$EXTENSION_CONFIG" | paste -sd ' ' -)"
[ "${#EXTENSIONS[@]}" -gt 0 ] || {
    echo "error: no duckdb_extension_load entries in $EXTENSION_CONFIG" >&2
    exit 1
}

# Byte-identical archives on a rebuild.
export ZERO_AR_DATE=1

for tool in cmake git libtool lipo python3; do
    command -v "$tool" > /dev/null 2>&1 || {
        echo "error: '$tool' is required" >&2
        exit 1
    }
done

echo "Building DuckDB $DUCKDB_VERSION for macOS (extensions: ${EXTENSIONS[*]})"
echo "Work dir: $WORK_DIR"

if [ ! -d "$WORK_DIR/duckdb" ]; then
    echo "Cloning DuckDB $DUCKDB_VERSION..."
    git clone --depth 1 --branch "$DUCKDB_VERSION" https://github.com/duckdb/duckdb.git "$WORK_DIR/duckdb"
fi

# Each extension archive carries a describe function that nothing references. DuckDB's
# generated loader passes them to duckdb_register_static_extension, and its autoregister
# object calls the loader before main. Both go into the archive: the plugin links it with
# -force_load, so neither is dropped (extension/README.md, Linking the static archives by hand).
build_loader() {
    local arch=$1 loader_dir=$2
    mkdir -p "$loader_dir"
    python3 "$WORK_DIR/duckdb/scripts/generate_static_extension_loader.py" \
        --output "$loader_dir/static_extension_loader.c" "${CAPABILITIES[@]}" "${EXTENSIONS[@]}"
    clang -arch "$arch" -mmacosx-version-min="$DEPLOYMENT_TARGET" -O2 \
        -I "$WORK_DIR/duckdb/src/include" \
        -c "$loader_dir/static_extension_loader.c" -o "$loader_dir/static_extension_loader.o"
    clang++ -arch "$arch" -mmacosx-version-min="$DEPLOYMENT_TARGET" -O2 -std=c++17 \
        -c "$WORK_DIR/duckdb/extension/loader/static_extension_autoregister.cpp" \
        -o "$loader_dir/static_extension_autoregister.o"
}

# Exactly one archive per name, or the merge would silently drop or duplicate one.
one_archive() {
    local dir=$1 name=$2 found
    found=$(find "$dir" -name "$name" -type f)
    if [ "$(printf '%s\n' "$found" | grep -c .)" -ne 1 ]; then
        echo "error: expected one $name under $dir, found: ${found:-none}" >&2
        exit 1
    fi
    echo "$found"
}

build_arch() {
    local arch=$1
    local build_dir="$WORK_DIR/build-$arch"
    local out_lib="$LIBS_DIR/libduckdb_${arch}.a"

    echo "Building for $arch..."
    # Without an explicit version DuckDB 2.0 names itself v2.0.0-dev<n>, and automatic installs then
    # look for httpfs and quack in a folder named after the commit instead of the release.
    cmake -S "$WORK_DIR/duckdb" -B "$build_dir" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DBUILD_SHELL=0 \
        -DBUILD_UNITTESTS=0 \
        -DBUILD_BENCHMARKS=0 \
        -DDUCKDB_EXPLICIT_VERSION="$DUCKDB_VERSION" \
        -DDUCKDB_EXTENSION_CONFIGS="$EXTENSION_CONFIG"

    local targets=(duckdb_static)
    local name
    for name in "${CAPABILITIES[@]}"; do targets+=("duckdb_$name"); done
    for name in "${EXTENSIONS[@]}"; do targets+=("${name}_extension"); done
    cmake --build "$build_dir" --config Release -j "$BUILD_JOBS" --target "${targets[@]}"

    local loader_dir="$build_dir/tablepro-loader"
    build_loader "$arch" "$loader_dir"

    # libduckdb_static.a already holds every third_party object, so a third_party/*.a on top
    # duplicates them: `libtool -static` accepts that silently and the plugin then fails to
    # link with duplicate symbols under -force_load.
    local archives=()
    archives+=("$(one_archive "$build_dir/src" libduckdb_static.a)")
    for name in "${CAPABILITIES[@]}"; do archives+=("$(one_archive "$build_dir/src" "libduckdb_$name.a")"); done
    for name in "${EXTENSIONS[@]}"; do archives+=("$(one_archive "$build_dir/extension" "lib${name}_extension.a")"); done
    libtool -static -o "$out_lib" "${archives[@]}" \
        "$loader_dir/static_extension_loader.o" "$loader_dir/static_extension_autoregister.o"

    # A library with no core_functions in it is the bug this script exists to fix, and it
    # fails silently at runtime on whichever Mac cannot reach the registry.
    #
    # Counted rather than matched with `grep -q`: that exits on the first hit, `nm` then dies
    # of SIGPIPE, and `set -o pipefail` reports 141 for a library that was in fact correct.
    local core_symbols
    core_symbols=$(nm -jU "$out_lib" 2> /dev/null | grep -ci corefunctions || true)
    if [ "$core_symbols" -eq 0 ]; then
        echo "error: $out_lib links no core_functions extension." >&2
        echo "       Check $EXTENSION_CONFIG." >&2
        exit 1
    fi
    echo "Verified $core_symbols core_functions symbol(s) in $(basename "$out_lib")"

    # Link the way the plugin links, -force_load included: a duplicated symbol is a hard link
    # failure `libtool -static` never reports. Then run it, offline, where this Mac can: an
    # extension that links but never registers fails only at runtime.
    local link_dir
    link_dir=$(mktemp -d)
    local expected
    expected=$(printf "'%s'," "${EXTENSIONS[@]}")
    cat > "$link_dir/link_probe.c" << PROBE
#include <stdio.h>
#include <string.h>
#include "duckdb.h"
static int run(duckdb_connection con, const char *sql) {
    duckdb_result result;
    duckdb_state state = duckdb_query(con, sql, &result);
    if (state == DuckDBError) fprintf(stderr, "%s: %s\n", sql, duckdb_result_error(&result));
    duckdb_destroy_result(&result);
    return state == DuckDBError;
}
int main(void) {
    duckdb_database db;
    duckdb_connection con;
    if (duckdb_open(NULL, &db) == DuckDBError || duckdb_connect(db, &con) == DuckDBError) return 2;
    int failed = run(con, "SET autoinstall_known_extensions = false");
    failed |= run(con, "SET autoload_known_extensions = false");
    failed |= run(con, "SELECT sum(1)");
    failed |= run(con, "SELECT CASE WHEN count(*) = ${#EXTENSIONS[@]} THEN 1 ELSE error('a linked extension did not load') END "
                       "FROM duckdb_extensions() WHERE loaded AND install_mode = 'STATICALLY_LINKED' "
                       "AND extension_name IN (${expected%,})");
    if (strcmp(duckdb_library_version(), "$DUCKDB_VERSION") != 0) {
        fprintf(stderr, "reports %s, not $DUCKDB_VERSION\n", duckdb_library_version());
        failed = 1;
    }
    duckdb_disconnect(&con);
    duckdb_close(&db);
    return failed;
}
PROBE
    if ! clang -arch "$arch" -mmacosx-version-min="$DEPLOYMENT_TARGET" -I "$WORK_DIR/duckdb/src/include" \
        -o "$link_dir/link_probe" "$link_dir/link_probe.c" \
        -Wl,-force_load,"$out_lib" -lc++ 2> "$link_dir/link.log"; then
        echo "error: $out_lib does not link under -force_load, which is how the plugin links it:" >&2
        tail -5 "$link_dir/link.log" >&2
        rm -rf "$link_dir"
        exit 1
    fi
    echo "Verified $(basename "$out_lib") links under -force_load"
    if arch "-$arch" /usr/bin/true 2> /dev/null; then
        if ! arch "-$arch" "$link_dir/link_probe"; then
            echo "error: $out_lib links but does not load ${EXTENSIONS[*]} without the network, or misreports its version." >&2
            rm -rf "$link_dir"
            exit 1
        fi
        echo "Verified $(basename "$out_lib") loads ${EXTENSIONS[*]} offline"
    else
        echo "warning: this Mac cannot run $arch, so the offline load check was skipped" >&2
    fi
    rm -rf "$link_dir"

    echo "Created $(basename "$out_lib") ($(du -h "$out_lib" | cut -f1))"
}

copy_unless_same_file() {
    [ "$1" -ef "$2" ] || cp "$1" "$2"
}

mkdir -p "$LIBS_DIR"

case "$ARCH" in
    arm64)
        build_arch arm64
        copy_unless_same_file "$LIBS_DIR/libduckdb_arm64.a" "$LIBS_DIR/libduckdb.a"
        ;;
    x86_64)
        build_arch x86_64
        copy_unless_same_file "$LIBS_DIR/libduckdb_x86_64.a" "$LIBS_DIR/libduckdb.a"
        ;;
    both | universal)
        build_arch arm64
        build_arch x86_64
        echo "Creating universal binary..."
        lipo -create "$LIBS_DIR/libduckdb_arm64.a" "$LIBS_DIR/libduckdb_x86_64.a" \
            -output "$LIBS_DIR/libduckdb_universal.a"
        copy_unless_same_file "$LIBS_DIR/libduckdb_universal.a" "$LIBS_DIR/libduckdb.a"
        echo "Created libduckdb_universal.a"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

echo
echo "DuckDB static library built successfully."
ls -lh "$LIBS_DIR"/libduckdb*.a
echo
echo "Verify with: scripts/probes/check-duckdb-extensions.sh"
echo "Publish with: scripts/publish-libs.sh libduckdb_arm64.a libduckdb_x86_64.a libduckdb_universal.a libduckdb.a"
