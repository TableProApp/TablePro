#!/usr/bin/env bash
set -euo pipefail

# Build DuckDB as an iOS xcframework for the TableProMobile app.
#
# Produces Libs/ios/DuckDB.xcframework with three slices:
#   - ios-arm64                    (device)
#   - ios-arm64_x86_64-simulator   (Apple Silicon + Intel simulators)
#
# DuckDB ships no official iOS binary, so we compile it from source with the
# leetal/ios-cmake toolchain. Extensions are linked statically through
# scripts/duckdb-ios-extensions.cmake (core_functions, json, parquet, icu,
# autocomplete, httpfs, quack). Remote extension autoloading/autoinstall is
# disabled: iOS apps may not download executable code (App Store Review
# Guideline 2.5.2), and the sandbox blocks it anyway. Static linking is what
# lets remote Quack connections work on iOS without a download.
#
# quack needs httpfs, and httpfs needs OpenSSL for TLS. We link the OpenSSL that
# already ships in Libs/ios (OpenSSL-SSL/OpenSSL-Crypto.xcframework). Those slices
# are ios-arm64 (device) and ios-arm64-simulator (arm64 simulator). There is no
# x86_64 simulator OpenSSL slice, so the x86_64 simulator DuckDB slice cannot
# link httpfs/quack. Build OpenSSL for x86_64-simulator first, or drop the
# SIMULATOR64 slice if Intel-simulator support is not needed.
#
# Requirements: macOS, Xcode command line tools, cmake, git, libtool, lipo, and
# Libs/ios populated (scripts/download-libs.sh).
#
# IMPORTANT: DUCKDB_VERSION must match the bundled macOS libduckdb.a so both
# platforms behave identically. Confirm with the version shown in the app
# (duckdb_library_version) on macOS, then pin the same tag here. When you bump
# DuckDB, also update the httpfs/quack pins in duckdb-ios-extensions.cmake.
#
# Usage:
#   scripts/build-duckdb-ios.sh [duckdb-version]
#   DUCKDB_VERSION=v1.5.3 scripts/build-duckdb-ios.sh

DUCKDB_VERSION="${1:-${DUCKDB_VERSION:-v1.5.3}}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-15.0}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/Libs/ios"
EXTENSION_CONFIG="$REPO_ROOT/scripts/duckdb-ios-extensions.cmake"
OPENSSL_SSL_XCFRAMEWORK="$OUT_DIR/OpenSSL-SSL.xcframework"
OPENSSL_CRYPTO_XCFRAMEWORK="$OUT_DIR/OpenSSL-Crypto.xcframework"
WORK_DIR="$(mktemp -d /tmp/duckdb-ios.XXXXXX)"
TOOLCHAIN="$WORK_DIR/ios.toolchain.cmake"
TOOLCHAIN_URL="https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake"

for tool in cmake git libtool lipo xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' is required" >&2; exit 1; }
done

echo "Building DuckDB $DUCKDB_VERSION for iOS (extensions: $EXTENSION_CONFIG)"
echo "Work dir: $WORK_DIR"

for xcframework in "$OPENSSL_SSL_XCFRAMEWORK" "$OPENSSL_CRYPTO_XCFRAMEWORK"; do
  [ -d "$xcframework" ] || { echo "error: missing $xcframework; run scripts/download-libs.sh" >&2; exit 1; }
done

echo "Fetching ios-cmake toolchain..."
curl -fSL -o "$TOOLCHAIN" "$TOOLCHAIN_URL"

echo "Cloning DuckDB $DUCKDB_VERSION..."
git clone --depth 1 --branch "$DUCKDB_VERSION" https://github.com/duckdb/duckdb.git "$WORK_DIR/duckdb"

# Build one DuckDB static library for a single ios-cmake PLATFORM value, then
# merge DuckDB's per-component archives into a single fat .a.
#
# DUCKDB_EXPLICIT_PLATFORM is set: cross-compiled iOS binaries cannot run on the
# macOS build host, so DuckDB's default "build and run a probe binary" platform
# detection fails. The value only labels the build (extension autoloading is
# off), so a descriptive string is enough.
build_platform() {
  local platform="$1" archs="$2" out_lib="$3" duckdb_platform="$4" openssl_slice="$5"
  local build_dir="$WORK_DIR/build-$platform"

  local openssl_include="$OPENSSL_SSL_XCFRAMEWORK/$openssl_slice/Headers"
  local openssl_ssl_lib="$OPENSSL_SSL_XCFRAMEWORK/$openssl_slice/libssl.a"
  local openssl_crypto_lib="$OPENSSL_CRYPTO_XCFRAMEWORK/$openssl_slice/libcrypto.a"
  for path in "$openssl_include" "$openssl_ssl_lib" "$openssl_crypto_lib"; do
    [ -e "$path" ] || { echo "error: OpenSSL slice missing $path (need an OpenSSL build for $openssl_slice)" >&2; exit 1; }
  done

  # The linked-extension registration in DuckDB core (extension_helper.cpp) is
  # gated on GENERATED_EXTENSION_HEADERS plus a DUCKDB_EXTENSION_<NAME>_LINKED
  # define per extension. CMake enables those only inside the extension/ subdir
  # scope, which is processed after src/, so core compiles with the registration
  # call sites disabled and the extensions never self-register (DuckDB then tries
  # to autoload them, which fails on iOS). Enabling the defines globally makes
  # core register the statically linked extensions at startup. The header gate
  # pulls in <build>/codegen/include/generated_extension_headers.hpp, which
  # includes each extension's entry header, so core also needs those include
  # dirs. No force_load or runtime install needed.
  local ext_root="$WORK_DIR/duckdb/extension"
  local linked_defines="-DGENERATED_EXTENSION_HEADERS=1"
  linked_defines+=" -DDUCKDB_EXTENSION_CORE_FUNCTIONS_LINKED=1"
  linked_defines+=" -DDUCKDB_EXTENSION_JSON_LINKED=1"
  linked_defines+=" -DDUCKDB_EXTENSION_PARQUET_LINKED=1"
  linked_defines+=" -DDUCKDB_EXTENSION_ICU_LINKED=1"
  linked_defines+=" -DDUCKDB_EXTENSION_AUTOCOMPLETE_LINKED=1"
  linked_defines+=" -DDUCKDB_EXTENSION_HTTPFS_LINKED=1"
  linked_defines+=" -DDUCKDB_EXTENSION_QUACK_LINKED=1"
  linked_defines+=" -I$build_dir/codegen/include"
  linked_defines+=" -I$ext_root/core_functions/include"
  linked_defines+=" -I$ext_root/json/include"
  linked_defines+=" -I$ext_root/parquet/include"
  linked_defines+=" -I$ext_root/icu/include"
  linked_defines+=" -I$ext_root/autocomplete/include"
  linked_defines+=" -I$openssl_include"

  echo "Building DuckDB for PLATFORM=$platform (archs: $archs)..."
  cmake -S "$WORK_DIR/duckdb" -B "$build_dir" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DPLATFORM="$platform" \
    -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DENABLE_BITCODE=OFF \
    -DENABLE_ARC=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DDUCKDB_EXPLICIT_PLATFORM="$duckdb_platform" \
    -DCMAKE_C_FLAGS="$linked_defines" \
    -DCMAKE_CXX_FLAGS="$linked_defines" \
    -DBUILD_SHELL=0 \
    -DBUILD_UNITTESTS=0 \
    -DBUILD_BENCHMARKS=0 \
    -DENABLE_EXTENSION_AUTOLOADING=0 \
    -DENABLE_EXTENSION_AUTOINSTALL=0 \
    -DOPENSSL_ROOT_DIR="$OPENSSL_SSL_XCFRAMEWORK/$openssl_slice" \
    -DOPENSSL_INCLUDE_DIR="$openssl_include" \
    -DOPENSSL_SSL_LIBRARY="$openssl_ssl_lib" \
    -DOPENSSL_CRYPTO_LIBRARY="$openssl_crypto_lib" \
    -DEXTENSION_CONFIGS="$EXTENSION_CONFIG"

  cmake --build "$build_dir" --config Release -j "$(sysctl -n hw.ncpu)"

  # DuckDB emits libduckdb_static.a plus one .a per linked extension and
  # third-party dependency. Merge them all into a single archive.
  local archives
  archives=$(find "$build_dir" -name '*.a' -type f)
  if [[ -z "$archives" ]]; then
    echo "error: no static archives produced for $platform" >&2
    exit 1
  fi
  # shellcheck disable=SC2086
  libtool -static -o "$out_lib" $archives

  # DuckDB ships two definitions of ExtensionHelper::LoadAllExtensions: the real
  # generated_extension_loader (registers the statically linked extensions) and
  # dummy_static_extension_loader (a no-op fallback for builds without static
  # extensions). Merging every archive pulls in both, and the linker can resolve
  # the no-op one, leaving the extensions unregistered (DuckDB then tries to
  # autoload them, which fails on iOS). Drop the dummy so only the real loader
  # remains.
  if ar -t "$out_lib" | grep -q '^dummy_static_extension_loader.cpp.o$'; then
    ar -d "$out_lib" dummy_static_extension_loader.cpp.o
    ranlib "$out_lib"
    echo "Removed dummy_static_extension_loader from $out_lib"
  else
    echo "error: dummy_static_extension_loader not found in $out_lib; verify the loader merge" >&2
    exit 1
  fi
  echo "Merged $(echo "$archives" | wc -l | tr -d ' ') archives into $out_lib"
}

DEVICE_LIB="$WORK_DIR/libduckdb-device.a"
SIM_ARM64_LIB="$WORK_DIR/libduckdb-sim-arm64.a"
SIM_X86_LIB="$WORK_DIR/libduckdb-sim-x86_64.a"
SIM_LIB="$WORK_DIR/libduckdb-sim.a"

build_platform "OS64" "arm64" "$DEVICE_LIB" "ios_arm64" "ios-arm64"
build_platform "SIMULATORARM64" "arm64" "$SIM_ARM64_LIB" "iossimulator_arm64" "ios-arm64-simulator"

# The x86_64 simulator slice needs an x86_64-simulator OpenSSL, which the bundled
# OpenSSL xcframework does not ship. Build it opt-in once that OpenSSL slice
# exists; otherwise the simulator slice is arm64 only (fine on Apple Silicon).
if [ "${BUILD_X86_SIMULATOR:-0}" = "1" ]; then
  build_platform "SIMULATOR64" "x86_64" "$SIM_X86_LIB" "iossimulator_amd64" "ios-x86_64-simulator"
  echo "Combining simulator slices..."
  lipo -create "$SIM_ARM64_LIB" "$SIM_X86_LIB" -output "$SIM_LIB"
else
  echo "Skipping x86_64 simulator slice (set BUILD_X86_SIMULATOR=1 with an x86_64 OpenSSL slice to include it)"
  cp "$SIM_ARM64_LIB" "$SIM_LIB"
fi

# The xcframework exposes the public C API header to consumers.
HEADERS_DIR="$WORK_DIR/include"
mkdir -p "$HEADERS_DIR"
cp "$WORK_DIR/duckdb/src/include/duckdb.h" "$HEADERS_DIR/duckdb.h"

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
echo "Next steps (these modify the libs-v1 release; run them yourself):"
echo "  tar czf /tmp/tablepro-libs-ios-v1.tar.gz -C \"$REPO_ROOT/Libs/ios\" ."
echo "  gh release upload libs-v1 /tmp/tablepro-libs-ios-v1.tar.gz --clobber --repo TableProApp/TablePro"
echo
echo "Then build TableProMobile in Xcode. Cleaning up $WORK_DIR"
rm -rf "$WORK_DIR"
