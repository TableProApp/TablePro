#!/usr/bin/env bash
set -euo pipefail

# Build DuckDB as an iOS xcframework for the TableProMobile app.
#
# Produces Libs/ios/DuckDB.xcframework with an ios-arm64 (device) and an
# ios-arm64-simulator slice. BUILD_X86_SIMULATOR=1 adds x86_64 to the simulator
# slice, which nothing links today: the other xcframeworks ship no x86_64
# simulator slice either.
#
# DuckDB ships no official iOS binary, so we compile it from source with the
# leetal/ios-cmake toolchain. The extensions in scripts/duckdb-ios-extensions.cmake
# link in statically. Automatic installs stay off at runtime (DuckDBDriver.connect):
# iOS apps may not download executable code (App Store Review Guideline 2.5.2), and
# this build links no way to load it.
#
# The extension archives register through DuckDB's generated static extension loader,
# duckdb_register_static_extensions, which the app calls before opening a database.
# Its declaration ships next to duckdb.h as duckdb_static_extensions.h.
#
# Requirements: macOS, Xcode command line tools, cmake, git, libtool, lipo, python3.
#
# DUCKDB_VERSION matches the bundled macOS libduckdb.a so both platforms behave
# identically.
#
# Usage:
#   scripts/build-duckdb-ios.sh [duckdb-version]
#   DUCKDB_VERSION=v2.0.0 BUILD_JOBS=3 scripts/build-duckdb-ios.sh

DUCKDB_VERSION="${1:-${DUCKDB_VERSION:-v2.0.0}}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-15.0}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Libs/ios"
EXTENSION_CONFIG="$REPO_ROOT/scripts/duckdb-ios-extensions.cmake"
BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
WORK_DIR="${DUCKDB_BUILD_DIR:-$(mktemp -d /tmp/duckdb-ios.XXXXXX)}"
TOOLCHAIN="$WORK_DIR/ios.toolchain.cmake"
TOOLCHAIN_URL="https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake"

# httplib is the HTTP client, kept for parity with the macOS build. loadable_extensions
# is left out: nothing on iOS may load a downloaded extension.
CAPABILITIES=(httplib)
read -r -a EXTENSIONS <<< "$(sed -nE 's/^duckdb_extension_load\(([a-z_]+)\)?.*/\1/p' "$EXTENSION_CONFIG" | paste -sd ' ' -)"
[ "${#EXTENSIONS[@]}" -gt 0 ] || { echo "error: no duckdb_extension_load entries in $EXTENSION_CONFIG" >&2; exit 1; }

export ZERO_AR_DATE=1

for tool in cmake git libtool lipo python3 xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is required" >&2; exit 1; }
done

echo "Building DuckDB $DUCKDB_VERSION for iOS (extensions: ${EXTENSIONS[*]})"
echo "Work dir: $WORK_DIR"

[ -f "$TOOLCHAIN" ] || { echo "Fetching ios-cmake toolchain..."; curl -fSL -o "$TOOLCHAIN" "$TOOLCHAIN_URL"; }

if [ ! -d "$WORK_DIR/duckdb" ]; then
  echo "Cloning DuckDB $DUCKDB_VERSION..."
  git clone --depth 1 --branch "$DUCKDB_VERSION" https://github.com/duckdb/duckdb.git "$WORK_DIR/duckdb"
fi

one_archive() {
  local dir=$1 name=$2 found
  found=$(find "$dir" -name "$name" -type f)
  if [ "$(printf '%s\n' "$found" | grep -c .)" -ne 1 ]; then
    echo "error: expected one $name under $dir, found: ${found:-none}" >&2
    exit 1
  fi
  echo "$found"
}

# Build one DuckDB static library for a single ios-cmake PLATFORM value and merge
# it with the extension archives and the generated loader into one archive.
#
# DUCKDB_EXPLICIT_PLATFORM is set: cross-compiled iOS binaries cannot run on the
# macOS build host, so DuckDB's default "build and run a probe binary" platform
# detection fails. The value only labels the build, so a descriptive string is enough.
build_platform() {
  local platform="$1" sdk="$2" target="$3" out_lib="$4" duckdb_platform="$5"
  local build_dir="$WORK_DIR/build-$platform"

  echo "Building DuckDB for PLATFORM=$platform..."
  # Without an explicit version DuckDB 2.0 names itself v2.0.0-dev<n>.
  cmake -S "$WORK_DIR/duckdb" -B "$build_dir" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DPLATFORM="$platform" \
    -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DENABLE_BITCODE=OFF \
    -DENABLE_ARC=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DDUCKDB_EXPLICIT_PLATFORM="$duckdb_platform" \
    -DDUCKDB_EXPLICIT_VERSION="$DUCKDB_VERSION" \
    -DBUILD_SHELL=0 \
    -DBUILD_UNITTESTS=0 \
    -DBUILD_BENCHMARKS=0 \
    -DDUCKDB_EXTENSION_CONFIGS="$EXTENSION_CONFIG"

  local targets=(duckdb_static) name
  for name in "${CAPABILITIES[@]}"; do targets+=("duckdb_$name"); done
  for name in "${EXTENSIONS[@]}"; do targets+=("${name}_extension"); done
  cmake --build "$build_dir" --config Release -j "$BUILD_JOBS" --target "${targets[@]}"

  local loader_dir="$build_dir/tablepro-loader"
  mkdir -p "$loader_dir"
  python3 "$WORK_DIR/duckdb/scripts/generate_static_extension_loader.py" \
    --output "$loader_dir/static_extension_loader.c" "${CAPABILITIES[@]}" "${EXTENSIONS[@]}"
  xcrun --sdk "$sdk" clang -target "$target" -O2 -I "$WORK_DIR/duckdb/src/include" \
    -c "$loader_dir/static_extension_loader.c" -o "$loader_dir/static_extension_loader.o"

  # libduckdb_static.a already holds every third_party object.
  local archives=()
  archives+=("$(one_archive "$build_dir/src" libduckdb_static.a)")
  for name in "${CAPABILITIES[@]}"; do archives+=("$(one_archive "$build_dir/src" "libduckdb_$name.a")"); done
  for name in "${EXTENSIONS[@]}"; do archives+=("$(one_archive "$build_dir/extension" "lib${name}_extension.a")"); done
  libtool -static -o "$out_lib" "${archives[@]}" "$loader_dir/static_extension_loader.o"

  # Link the way the app does, with no -force_load: the loader alone has to pull every
  # extension out of the archive, or a linked extension never registers.
  local link_dir
  link_dir=$(mktemp -d)
  cat > "$link_dir/link_probe.c" <<'PROBE'
#include <stdint.h>
#include "duckdb.h"
int32_t duckdb_register_static_extensions(void);
int main(void) {
  duckdb_database db;
  if (duckdb_register_static_extensions() != 0) return 1;
  return duckdb_open(NULL, &db) == DuckDBError;
}
PROBE
  if ! xcrun --sdk "$sdk" clang -target "$target" -I "$WORK_DIR/duckdb/src/include" \
      -o "$link_dir/link_probe" "$link_dir/link_probe.c" "$out_lib" -lc++ 2> "$link_dir/link.log"; then
    echo "error: $out_lib does not link for $target:" >&2
    tail -5 "$link_dir/link.log" >&2
    rm -rf "$link_dir"
    exit 1
  fi
  rm -rf "$link_dir"
  echo "Merged and link-checked $out_lib"
}

DEVICE_LIB="$WORK_DIR/libduckdb-device.a"
SIM_ARM64_LIB="$WORK_DIR/libduckdb-sim-arm64.a"
SIM_X86_LIB="$WORK_DIR/libduckdb-sim-x86_64.a"
SIM_LIB="$WORK_DIR/libduckdb-sim.a"

build_platform "OS64" iphoneos "arm64-apple-ios$DEPLOYMENT_TARGET" "$DEVICE_LIB" "ios_arm64"
build_platform "SIMULATORARM64" iphonesimulator "arm64-apple-ios$DEPLOYMENT_TARGET-simulator" "$SIM_ARM64_LIB" "iossimulator_arm64"

if [ "${BUILD_X86_SIMULATOR:-0}" = "1" ]; then
  build_platform "SIMULATOR64" iphonesimulator "x86_64-apple-ios$DEPLOYMENT_TARGET-simulator" "$SIM_X86_LIB" "iossimulator_amd64"
  echo "Combining simulator slices..."
  lipo -create "$SIM_ARM64_LIB" "$SIM_X86_LIB" -output "$SIM_LIB"
else
  cp "$SIM_ARM64_LIB" "$SIM_LIB"
fi

# The public C API, plus the declaration of the generated loader the app calls.
HEADERS_DIR="$WORK_DIR/include"
mkdir -p "$HEADERS_DIR"
cp "$WORK_DIR/duckdb/src/include/duckdb.h" "$HEADERS_DIR/duckdb.h"
cat > "$HEADERS_DIR/duckdb_static_extensions.h" <<'HEADER'
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

//! Registers the extensions linked into this library. Call before opening a database. Returns 0 on success.
int32_t duckdb_register_static_extensions(void);

#ifdef __cplusplus
}
#endif
HEADER

echo "Creating xcframework..."
rm -rf "$OUT_DIR/DuckDB.xcframework"
mkdir -p "$OUT_DIR"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$HEADERS_DIR" \
  -library "$SIM_LIB" -headers "$HEADERS_DIR" \
  -output "$OUT_DIR/DuckDB.xcframework"

echo
echo "Done: $OUT_DIR/DuckDB.xcframework"
echo
echo "Build TableProMobile in Xcode, then publish: scripts/publish-libs.sh DuckDB.xcframework"
[ -n "${DUCKDB_BUILD_DIR:-}" ] || rm -rf "$WORK_DIR"
