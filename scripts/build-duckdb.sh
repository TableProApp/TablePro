#!/usr/bin/env bash
set -euo pipefail

# Build the DuckDB static library for TablePro's macOS plugin.
#
# Usage: ./scripts/build-duckdb.sh [arm64|x86_64|both]
#
# This compiles DuckDB from source with CMake so the extensions in
# scripts/duckdb-macos-extensions.cmake link in statically. The previous version
# compiled the single-file amalgamation with plain clang++, and the amalgamation
# carries no extensions: `sum`, `avg`, `round`, `date_trunc`, `current_database`
# and most of the rest live in core_functions, which DuckDB then downloaded from
# extensions.duckdb.org on first use. On a Mac that could not reach the registry
# every one of them failed and a DuckDB connection was unusable.
#
# Runtime autoloading stays on, unlike the iOS build, so httpfs and quack still
# download on demand for remote Quack connections.
#
# Requirements: macOS, Xcode command line tools, cmake, git, libtool, lipo.
#
# After building, publish with scripts/publish-libs.sh (never regenerate
# Libs/checksums.sha256 by hand):
#   scripts/publish-libs.sh libduckdb_arm64.a libduckdb_x86_64.a libduckdb_universal.a libduckdb.a

DUCKDB_VERSION="${DUCKDB_VERSION:-v1.5.2}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so a verification run can write somewhere else. Libs/*.a is shared with
# every other checkout on the machine and its checksums are pinned by publish-libs.sh.
LIBS_DIR="${LIBS_DIR:-$REPO_ROOT/Libs}"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
EXTENSION_CONFIG="$REPO_ROOT/scripts/duckdb-macos-extensions.cmake"
ARCH="${1:-both}"
WORK_DIR="${DUCKDB_BUILD_DIR:-$(mktemp -d /tmp/duckdb-macos.XXXXXX)}"

for tool in cmake git libtool lipo; do
    command -v "$tool" > /dev/null 2>&1 || {
        echo "error: '$tool' is required" >&2
        exit 1
    }
done

echo "Building DuckDB $DUCKDB_VERSION for macOS (extensions: $EXTENSION_CONFIG)"
echo "Work dir: $WORK_DIR"

if [ ! -d "$WORK_DIR/duckdb" ]; then
    echo "Cloning DuckDB $DUCKDB_VERSION..."
    git clone --depth 1 --branch "$DUCKDB_VERSION" https://github.com/duckdb/duckdb.git "$WORK_DIR/duckdb"
fi

# The linked-extension registration in DuckDB core (extension_helper.cpp) is gated
# on GENERATED_EXTENSION_HEADERS plus a DUCKDB_EXTENSION_<NAME>_LINKED define per
# extension. CMake enables those only inside the extension/ subdir scope, which is
# processed after src/, so core compiles with the registration call sites disabled
# and the extensions never self-register. Enabling the defines globally makes core
# register them at startup. The header gate pulls in
# <build>/codegen/include/generated_extension_headers.hpp, which includes each
# extension's entry header, so core also needs those include dirs.
linked_defines_for() {
    local build_dir="$1"
    local ext_root="$WORK_DIR/duckdb/extension"
    local defines="-DGENERATED_EXTENSION_HEADERS=1"
    defines+=" -DDUCKDB_EXTENSION_CORE_FUNCTIONS_LINKED=1"
    defines+=" -DDUCKDB_EXTENSION_JSON_LINKED=1"
    defines+=" -DDUCKDB_EXTENSION_PARQUET_LINKED=1"
    defines+=" -DDUCKDB_EXTENSION_ICU_LINKED=1"
    defines+=" -DDUCKDB_EXTENSION_AUTOCOMPLETE_LINKED=1"
    defines+=" -I$build_dir/codegen/include"
    defines+=" -I$ext_root/core_functions/include"
    defines+=" -I$ext_root/json/include"
    defines+=" -I$ext_root/parquet/include"
    defines+=" -I$ext_root/icu/include"
    defines+=" -I$ext_root/autocomplete/include"
    echo "$defines"
}

build_arch() {
    local arch=$1
    local build_dir="$WORK_DIR/build-$arch"
    local out_lib="$LIBS_DIR/libduckdb_${arch}.a"
    local defines
    defines=$(linked_defines_for "$build_dir")

    echo "Building for $arch..."
    cmake -S "$WORK_DIR/duckdb" -B "$build_dir" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_C_FLAGS="$defines" \
        -DCMAKE_CXX_FLAGS="$defines" \
        -DBUILD_SHELL=0 \
        -DBUILD_UNITTESTS=0 \
        -DBUILD_BENCHMARKS=0 \
        -DENABLE_EXTENSION_AUTOLOADING=1 \
        -DENABLE_EXTENSION_AUTOINSTALL=1 \
        -DEXTENSION_CONFIGS="$EXTENSION_CONFIG"

    cmake --build "$build_dir" --config Release -j "$BUILD_JOBS"

    # Merge exactly three kinds of archive and nothing else.
    #
    # libduckdb_static.a already contains every third_party object, so adding
    # third_party/*.a as well duplicates them: `libtool -static` accepts it silently and
    # the plugin then fails to link with 1821 duplicate symbols, because it links this
    # library with -force_load and that pulls in every member.
    #
    # libdummy_static_extension_loader.a is left out on purpose. DuckDB ships two
    # definitions of ExtensionHelper::LoadAllExtensions: the real
    # generated_extension_loader, which registers the statically linked extensions, and
    # this no-op fallback for builds without them. With both present the linker may
    # resolve the no-op, leaving the extensions unregistered and DuckDB back on the
    # network, which is the whole failure this build exists to remove.
    local archives
    archives=$(
        find "$build_dir/src" -name 'libduckdb_static.a' -type f
        find "$build_dir/extension" -name 'libduckdb_generated_extension_loader.a' -type f
        find "$build_dir/extension" -name 'lib*_extension.a' -type f
    )
    if [ -z "$archives" ]; then
        echo "error: no static archives produced for $arch" >&2
        exit 1
    fi
    # shellcheck disable=SC2086
    libtool -static -o "$out_lib" $archives

    if ar -t "$out_lib" | grep -q '^dummy_static_extension_loader.cpp.o$'; then
        echo "error: $out_lib contains the no-op extension loader; the merge picked up the wrong archive." >&2
        exit 1
    fi

    # A library with no core_functions in it is the bug this script exists to fix, and it
    # fails silently at runtime on whichever Mac cannot reach the registry.
    #
    # Counted rather than matched with `grep -q`: that exits on the first hit, `nm` then dies
    # of SIGPIPE, and `set -o pipefail` reports 141 for a library that was in fact correct.
    local core_symbols
    core_symbols=$(nm -jU "$out_lib" 2> /dev/null | grep -ci corefunctions || true)
    if [ "$core_symbols" -eq 0 ]; then
        echo "error: $out_lib links no core_functions extension." >&2
        echo "       Check EXTENSION_CONFIGS and the DUCKDB_EXTENSION_*_LINKED defines." >&2
        exit 1
    fi
    echo "Verified $core_symbols core_functions symbol(s) in $(basename "$out_lib")"

    # The plugin links this with -force_load, which pulls in every member rather than letting
    # the linker pick a winner, so a duplicated symbol is a hard link failure. Merging one
    # archive too many produced 1821 of them and `libtool -static` reported nothing at all,
    # so the only honest check is to link the way the plugin links. Member names are not the
    # test: brotli and DuckDB core both ship a `platform.cpp.o` and coexist fine.
    local link_dir
    link_dir=$(mktemp -d)
    cat > "$link_dir/link_probe.c" <<'PROBE'
#include "duckdb.h"
int main(void) { return duckdb_library_version() == 0; }
PROBE
    if ! clang -arch "$arch" -I "$WORK_DIR/duckdb/src/include" \
        -o "$link_dir/link_probe" "$link_dir/link_probe.c" \
        -Wl,-force_load,"$out_lib" -lc++ 2> "$link_dir/link.log"; then
        echo "error: $out_lib does not link under -force_load, which is how the plugin links it:" >&2
        tail -5 "$link_dir/link.log" >&2
        rm -rf "$link_dir"
        exit 1
    fi
    rm -rf "$link_dir"
    echo "Verified $(basename "$out_lib") links under -force_load"

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
echo "Verify with: scripts/check-duckdb-offline-metadata.sh"
echo "Publish with: scripts/publish-libs.sh libduckdb_arm64.a libduckdb_x86_64.a libduckdb_universal.a libduckdb.a"
