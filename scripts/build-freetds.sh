#!/usr/bin/env bash
# Build FreeTDS static libraries for macOS (arm64 + x86_64) and iOS (arm64 device + arm64 simulator),
# then package as a unified xcframework with bundled Swift module map.
#
# Output: Libs/ios/FreeTDS.xcframework, consumed by both the macOS MSSQL plugin and the iOS app
#         via the CFreeTDS Swift module.
#
# Prerequisites:
#   brew install autoconf automake libtool openssl@3
#   Xcode 15+ (for xcrun, xcodebuild -create-xcframework)
#   Libs/ios/OpenSSL-SSL.xcframework + OpenSSL-Crypto.xcframework already downloaded
#   (run scripts/download-libs.sh first if needed)
#
# Usage: bash scripts/build-freetds.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIBS_DIR="$PROJECT_DIR/Libs"
IOS_LIBS_DIR="$LIBS_DIR/ios"
FREETDS_VERSION="1.4.22"
FREETDS_SHA256="6acb9086350425f5178e544bbe2d54a001097e8e20277a2b766ad0799a2e7d87"
FREETDS_URL="https://www.freetds.org/files/stable/freetds-${FREETDS_VERSION}.tar.gz"
BUILD_DIR="/tmp/freetds-build"
SOURCE_DIR="$BUILD_DIR/freetds-${FREETDS_VERSION}"
MACOS_DEPLOYMENT_TARGET="14.0"
IOS_DEPLOYMENT_TARGET="17.0"

MACOS_OPENSSL_PREFIX="$(brew --prefix openssl@3)"
IOS_OPENSSL_SSL_XCFW="$IOS_LIBS_DIR/OpenSSL-SSL.xcframework"
IOS_OPENSSL_CRYPTO_XCFW="$IOS_LIBS_DIR/OpenSSL-Crypto.xcframework"

if [ ! -d "$IOS_OPENSSL_SSL_XCFW" ] || [ ! -d "$IOS_OPENSSL_CRYPTO_XCFW" ]; then
    echo "ERROR: iOS OpenSSL xcframeworks not found in $IOS_LIBS_DIR"
    echo "Run scripts/download-libs.sh first."
    exit 1
fi

mkdir -p "$BUILD_DIR" "$LIBS_DIR" "$IOS_LIBS_DIR"

echo "==> Downloading FreeTDS ${FREETDS_VERSION}..."
if [ ! -f "$BUILD_DIR/freetds-${FREETDS_VERSION}.tar.gz" ]; then
    curl -fSL "$FREETDS_URL" -o "$BUILD_DIR/freetds-${FREETDS_VERSION}.tar.gz"
fi
echo "$FREETDS_SHA256  $BUILD_DIR/freetds-${FREETDS_VERSION}.tar.gz" | shasum -a 256 -c -

rm -rf "$SOURCE_DIR"
tar xz -C "$BUILD_DIR" -f "$BUILD_DIR/freetds-${FREETDS_VERSION}.tar.gz"

build_slice() {
    local SLICE_LABEL="$1"
    local SDK="$2"
    local ARCH="$3"
    local HOST_TRIPLE="$4"
    local VERSION_FLAG="$5"
    local OPENSSL_PREFIX="$6"

    local PREFIX="/tmp/freetds-${SLICE_LABEL}"
    local SDKPATH
    SDKPATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
    local CC_BIN
    CC_BIN="$(xcrun -sdk "$SDK" -find clang)"

    echo "==> Building FreeTDS for ${SLICE_LABEL} (${ARCH}, ${SDK})..."
    rm -rf "$PREFIX"
    pushd "$SOURCE_DIR" > /dev/null
    make distclean 2>/dev/null || true
    rm -f config.cache

    # Pre-seed AC_RUN_IFELSE results via env vars (correct for all 64-bit Apple platforms).
    # Avoids --cache-file which autoconf rejects when host/CFLAGS change between slices.
    env \
        ac_cv_func_malloc_0_nonnull=yes \
        ac_cv_func_realloc_0_nonnull=yes \
        ac_cv_func_memcmp_working=yes \
        ac_cv_func_iconv_open=yes \
        ac_cv_sizeof_int=4 \
        ac_cv_sizeof_long=8 \
        ac_cv_sizeof_long_long=8 \
        ac_cv_sizeof_void_p=8 \
        ac_cv_c_bigendian=no \
        ./configure \
            --prefix="$PREFIX" \
            --host="$HOST_TRIPLE" \
            --disable-shared \
            --enable-static \
            --disable-odbc \
            --disable-libiconv \
            --with-tdsver=7.4 \
            --with-openssl="$OPENSSL_PREFIX" \
            CC="$CC_BIN" \
            CFLAGS="-arch ${ARCH} -isysroot ${SDKPATH} ${VERSION_FLAG} -I${OPENSSL_PREFIX}/include" \
            LDFLAGS="-arch ${ARCH} -isysroot ${SDKPATH} -L${OPENSSL_PREFIX}/lib"

    # Build only the libraries we need (skip src/apps which require readline + native exec).
    # SUBDIRS order matches src/Makefile: utils → replacements → tds → dblib.
    make -j"$(sysctl -n hw.logicalcpu)" -C include
    make -j"$(sysctl -n hw.logicalcpu)" -C src/utils
    make -j"$(sysctl -n hw.logicalcpu)" -C src/replacements
    make -j"$(sysctl -n hw.logicalcpu)" -C src/tds
    make -j"$(sysctl -n hw.logicalcpu)" -C src/dblib
    make -C src/dblib install
    popd > /dev/null

    cp "$PREFIX/lib/libsybdb.a" "$LIBS_DIR/libsybdb_${SLICE_LABEL}.a"
    echo "    built libsybdb_${SLICE_LABEL}.a"
}

# macOS slices use per-arch static OpenSSL from Libs/ to avoid brew's arm64-only dylib at the
# linker step. Brew supplies headers (arch-agnostic); the .a files come from Libs/.
MACOS_OPENSSL_ARM64="$(mktemp -d)/openssl-macos-arm64"
MACOS_OPENSSL_X86_64="$(mktemp -d)/openssl-macos-x86_64"
mkdir -p "$MACOS_OPENSSL_ARM64/include/openssl" "$MACOS_OPENSSL_ARM64/lib"
mkdir -p "$MACOS_OPENSSL_X86_64/include/openssl" "$MACOS_OPENSSL_X86_64/lib"
cp -R "$MACOS_OPENSSL_PREFIX/include/openssl/." "$MACOS_OPENSSL_ARM64/include/openssl/"
cp -R "$MACOS_OPENSSL_PREFIX/include/openssl/." "$MACOS_OPENSSL_X86_64/include/openssl/"
cp "$LIBS_DIR/libssl_arm64.a"    "$MACOS_OPENSSL_ARM64/lib/libssl.a"
cp "$LIBS_DIR/libcrypto_arm64.a" "$MACOS_OPENSSL_ARM64/lib/libcrypto.a"
cp "$LIBS_DIR/libssl_x86_64.a"    "$MACOS_OPENSSL_X86_64/lib/libssl.a"
cp "$LIBS_DIR/libcrypto_x86_64.a" "$MACOS_OPENSSL_X86_64/lib/libcrypto.a"

build_slice "macos-arm64"  "macosx" "arm64"  "aarch64-apple-darwin" "-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}" "$MACOS_OPENSSL_ARM64"
build_slice "macos-x86_64" "macosx" "x86_64" "x86_64-apple-darwin"  "-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}" "$MACOS_OPENSSL_X86_64"

# iOS slices link OpenSSL statically from the existing xcframeworks; reconstruct a unix-style prefix
# for FreeTDS's --with-openssl which expects include/ and lib/ siblings.
IOS_OPENSSL_DEVICE="$(mktemp -d)/openssl-ios-arm64"
IOS_OPENSSL_SIM="$(mktemp -d)/openssl-ios-arm64-simulator"
mkdir -p "$IOS_OPENSSL_DEVICE/include" "$IOS_OPENSSL_DEVICE/lib"
mkdir -p "$IOS_OPENSSL_SIM/include" "$IOS_OPENSSL_SIM/lib"
cp -R "$IOS_OPENSSL_SSL_XCFW/ios-arm64/Headers/." "$IOS_OPENSSL_DEVICE/include/"
cp "$IOS_OPENSSL_SSL_XCFW/ios-arm64/libssl.a" "$IOS_OPENSSL_DEVICE/lib/"
cp "$IOS_OPENSSL_CRYPTO_XCFW/ios-arm64/libcrypto.a" "$IOS_OPENSSL_DEVICE/lib/"
cp -R "$IOS_OPENSSL_SSL_XCFW/ios-arm64-simulator/Headers/." "$IOS_OPENSSL_SIM/include/"
cp "$IOS_OPENSSL_SSL_XCFW/ios-arm64-simulator/libssl.a" "$IOS_OPENSSL_SIM/lib/"
cp "$IOS_OPENSSL_CRYPTO_XCFW/ios-arm64-simulator/libcrypto.a" "$IOS_OPENSSL_SIM/lib/"

build_slice "ios-arm64"           "iphoneos"        "arm64" "aarch64-apple-darwin" "-mios-version-min=${IOS_DEPLOYMENT_TARGET}"           "$IOS_OPENSSL_DEVICE"
build_slice "ios-arm64-simulator" "iphonesimulator" "arm64" "aarch64-apple-darwin" "-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}" "$IOS_OPENSSL_SIM"

echo "==> Creating macOS universal slice..."
lipo -create \
    "$LIBS_DIR/libsybdb_macos-arm64.a" \
    "$LIBS_DIR/libsybdb_macos-x86_64.a" \
    -output "$LIBS_DIR/libsybdb_macos_universal.a"

HEADERS_STAGE="$BUILD_DIR/headers-stage"
rm -rf "$HEADERS_STAGE"
mkdir -p "$HEADERS_STAGE"
cp "$SOURCE_DIR/include/sybdb.h" "$HEADERS_STAGE/"
cp "$SOURCE_DIR/include/sybfront.h" "$HEADERS_STAGE/"

# Do NOT copy raw FreeTDS headers into Plugins/MSSQLDriverPlugin/CFreeTDS/include/. Those are
# hand-curated Swift-compatible stubs. Upstream sybdb.h transitively requires generated headers
# (tds_sysdep_public.h, etc.) that we don't ship. The xcframework's bundled headers are also stubs
# for consumers; the real symbols are exported by libsybdb.a at link time.

echo "==> Assembling FreeTDS.xcframework..."
XCFRAMEWORK_OUT="$IOS_LIBS_DIR/FreeTDS.xcframework"
rm -rf "$XCFRAMEWORK_OUT"
xcodebuild -create-xcframework \
    -library "$LIBS_DIR/libsybdb_macos_universal.a"     -headers "$HEADERS_STAGE" \
    -library "$LIBS_DIR/libsybdb_ios-arm64.a"           -headers "$HEADERS_STAGE" \
    -library "$LIBS_DIR/libsybdb_ios-arm64-simulator.a" -headers "$HEADERS_STAGE" \
    -output  "$XCFRAMEWORK_OUT"

echo "==> Cleaning intermediate per-slice archives..."
rm -f \
    "$LIBS_DIR/libsybdb_macos-arm64.a" \
    "$LIBS_DIR/libsybdb_macos-x86_64.a" \
    "$LIBS_DIR/libsybdb_macos_universal.a" \
    "$LIBS_DIR/libsybdb_ios-arm64.a" \
    "$LIBS_DIR/libsybdb_ios-arm64-simulator.a"

echo ""
echo "FreeTDS.xcframework built at: $XCFRAMEWORK_OUT"
echo "Slices:"
ls -1 "$XCFRAMEWORK_OUT" | grep -v Info.plist | sed 's/^/  - /'
echo ""
echo "NEXT STEPS:"
echo "  1. Inspect: xcodebuild -checkFirstLaunchStatus; file ${XCFRAMEWORK_OUT}/*/libsybdb.a"
echo "  2. Re-pack iOS libs archive and upload to libs-v1 release:"
echo "       tar czf /tmp/tablepro-libs-ios-v1.tar.gz -C ${IOS_LIBS_DIR} ."
echo "       gh release upload libs-v1 /tmp/tablepro-libs-ios-v1.tar.gz --clobber --repo TableProApp/TablePro"
