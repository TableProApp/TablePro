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
# A private directory with a cleanup trap. This was a fixed /tmp path, which is world-writable and
# therefore something another local user can own first, and it collided between two concurrent
# runs. The four mktemp dirs below were also never removed, so a run leaked all five.
BUILD_DIR="$(mktemp -d)"
TEMP_DIRS=("$BUILD_DIR")
cleanup_freetds() { rm -rf "${TEMP_DIRS[@]}"; }
trap cleanup_freetds EXIT

# Keeps the downloaded tarballs across runs, which the fixed build root used to provide for free.
CACHE_DIR="${TMPDIR:-/tmp}/tablepro-freetds-cache"
mkdir -p "$CACHE_DIR"
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

# Cached outside the per-run build directory, so moving off a fixed /tmp build root does not turn
# every run into a fresh download. Verified on every run, not only after a download.
TARBALL="$CACHE_DIR/freetds-${FREETDS_VERSION}.tar.gz"
echo "==> Downloading FreeTDS ${FREETDS_VERSION}..."
if [ ! -f "$TARBALL" ]; then
    curl -fSL "$FREETDS_URL" -o "$TARBALL"
fi
echo "$FREETDS_SHA256  $TARBALL" | shasum -a 256 -c -

rm -rf "$SOURCE_DIR"
tar xz -C "$BUILD_DIR" -f "$TARBALL"

# FreeTDS has never implemented the TDS FEDAUTH login extension, so Microsoft Entra ID
# authentication rides as a patch on the pinned release tarball. Upstream tracks the gap in
# issues #360 and #509. Drop the patch once a release carries it.
#
# Patches live in scripts/patches/<library>/ so each build applies only its own. Every slice
# builds from this one source tree, so patching once here covers macOS and iOS.
apply_patches() {
    local source_dir=$1
    local library=$2
    local patch_dir="$SCRIPT_DIR/patches/$library"
    local patch

    [ -d "$patch_dir" ] || return 0

    for patch in "$patch_dir"/*.patch; do
        [ -e "$patch" ] || continue
        echo "==> Applying $(basename "$patch") to $library"
        patch -p1 -d "$source_dir" -i "$patch"
    done
}

apply_patches "$SOURCE_DIR" freetds

build_slice() {
    local SLICE_LABEL="$1"
    local SDK="$2"
    local ARCH="$3"
    local HOST_TRIPLE="$4"
    local VERSION_FLAG="$5"
    local OPENSSL_PREFIX="$6"
    local KRB5_FLAG="${7:-}"

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
            ${KRB5_FLAG} \
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
MACOS_OPENSSL_ARM64_ROOT="$(mktemp -d)"
TEMP_DIRS+=("$MACOS_OPENSSL_ARM64_ROOT")
MACOS_OPENSSL_ARM64="${MACOS_OPENSSL_ARM64_ROOT}/openssl-macos-arm64"
MACOS_OPENSSL_X86_64_ROOT="$(mktemp -d)"
TEMP_DIRS+=("$MACOS_OPENSSL_X86_64_ROOT")
MACOS_OPENSSL_X86_64="${MACOS_OPENSSL_X86_64_ROOT}/openssl-macos-x86_64"
mkdir -p "$MACOS_OPENSSL_ARM64/include/openssl" "$MACOS_OPENSSL_ARM64/lib"
mkdir -p "$MACOS_OPENSSL_X86_64/include/openssl" "$MACOS_OPENSSL_X86_64/lib"
cp -R "$MACOS_OPENSSL_PREFIX/include/openssl/." "$MACOS_OPENSSL_ARM64/include/openssl/"
cp -R "$MACOS_OPENSSL_PREFIX/include/openssl/." "$MACOS_OPENSSL_X86_64/include/openssl/"
cp "$LIBS_DIR/libssl_arm64.a"    "$MACOS_OPENSSL_ARM64/lib/libssl.a"
cp "$LIBS_DIR/libcrypto_arm64.a" "$MACOS_OPENSSL_ARM64/lib/libcrypto.a"
cp "$LIBS_DIR/libssl_x86_64.a"    "$MACOS_OPENSSL_X86_64/lib/libssl.a"
cp "$LIBS_DIR/libcrypto_x86_64.a" "$MACOS_OPENSSL_X86_64/lib/libcrypto.a"

# macOS slices enable Kerberos/GSS (Windows Authentication). The explicit --enable-krb5=gssapi_krb5
# form makes FreeTDS define ENABLE_KRB5 unconditionally; plain --enable-krb5 only defines it when an
# auto link probe succeeds and skips it silently otherwise, which shipped an empty gssapi.o once.
# The symbols resolve against the SDK's libgssapi_krb5 stub (Kerberos.framework); the plugin adds
# -framework GSS at link time. iOS slices stay krb5-free (Windows auth is macOS only).
build_slice "macos-arm64"  "macosx" "arm64"  "aarch64-apple-darwin" "-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}" "$MACOS_OPENSSL_ARM64"  "--enable-krb5=gssapi_krb5"
build_slice "macos-x86_64" "macosx" "x86_64" "x86_64-apple-darwin"  "-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}" "$MACOS_OPENSSL_X86_64" "--enable-krb5=gssapi_krb5"

# grep without -q so it drains nm's full output. Under `set -o pipefail`, -q would close the pipe
# on the first match, nm would die with SIGPIPE, and the pipeline would report failure for a valid
# library. gssapi.o must define tds_gss_get_auth; an empty stub means Kerberos was not compiled in.
for slice in macos-arm64 macos-x86_64; do
    if ! nm "$LIBS_DIR/libsybdb_${slice}.a" 2>/dev/null | grep 'T _tds_gss_get_auth' > /dev/null; then
        echo "ERROR: libsybdb_${slice}.a has no tds_gss_get_auth; Kerberos/GSS was not compiled in." >&2
        echo "       configure did not define ENABLE_KRB5. Check --enable-krb5=gssapi_krb5 and the SDK gssapi headers." >&2
        exit 1
    fi
done

# Write the macOS committed archives now, before the iOS slices. The macOS plugin library and the
# iOS xcframework are independent products; an iOS build failure must not discard a good macOS build.
echo "==> Creating macOS universal slice..."
lipo -create \
    "$LIBS_DIR/libsybdb_macos-arm64.a" \
    "$LIBS_DIR/libsybdb_macos-x86_64.a" \
    -output "$LIBS_DIR/libsybdb_macos_universal.a"

# The flat committed archives the macOS plugin links directly (TablePro.xcodeproj force_loads
# Libs/libsybdb.a). The universal slice is kept until the xcframework is assembled, then cleaned up.
# Publish with scripts/publish-libs.sh libsybdb_arm64.a libsybdb_x86_64.a libsybdb_universal.a libsybdb.a
echo "==> Writing committed macOS archives (libsybdb.a, libsybdb_arm64.a, libsybdb_x86_64.a, libsybdb_universal.a)..."
cp "$LIBS_DIR/libsybdb_macos-arm64.a"     "$LIBS_DIR/libsybdb_arm64.a"
cp "$LIBS_DIR/libsybdb_macos-x86_64.a"    "$LIBS_DIR/libsybdb_x86_64.a"
cp "$LIBS_DIR/libsybdb_macos_universal.a" "$LIBS_DIR/libsybdb_universal.a"
cp "$LIBS_DIR/libsybdb_macos_universal.a" "$LIBS_DIR/libsybdb.a"

# iOS slices link OpenSSL statically from the existing xcframeworks; reconstruct a unix-style prefix
# for FreeTDS's --with-openssl which expects include/ and lib/ siblings.
IOS_OPENSSL_DEVICE_ROOT="$(mktemp -d)"
TEMP_DIRS+=("$IOS_OPENSSL_DEVICE_ROOT")
IOS_OPENSSL_DEVICE="${IOS_OPENSSL_DEVICE_ROOT}/openssl-ios-arm64"
IOS_OPENSSL_SIM_ROOT="$(mktemp -d)"
TEMP_DIRS+=("$IOS_OPENSSL_SIM_ROOT")
IOS_OPENSSL_SIM="${IOS_OPENSSL_SIM_ROOT}/openssl-ios-arm64-simulator"
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

# The xcframework ships the hand-curated stubs, not upstream's headers. TableProMobile's
# CBridges/CFreeTDS umbrella includes <sybdb.h> and <sybfront.h>, which resolve to these, and
# upstream sybdb.h transitively requires generated headers (tds_sysdep_public.h and friends) that
# are not shipped, so staging upstream's copy fails the iOS build with "file not found". The real
# symbols come from libsybdb.a at link time, so a stub is all a consumer needs.
#
# For the same reason, never copy upstream headers into Plugins/MSSQLDriverPlugin/CFreeTDS/include/.
STUB_HEADERS="$PROJECT_DIR/Plugins/MSSQLDriverPlugin/CFreeTDS/include"
HEADERS_STAGE="$BUILD_DIR/headers-stage"
rm -rf "$HEADERS_STAGE"
mkdir -p "$HEADERS_STAGE"
cp "$STUB_HEADERS/sybdb.h" "$HEADERS_STAGE/"
cp "$STUB_HEADERS/sybfront.h" "$HEADERS_STAGE/"

# A stub that has drifted from the built library is the failure this guards against: the symbol
# links on macOS, where the plugin uses the stub directly, and goes missing only on iOS.
if ! grep -q 'dbsetlfedauthtoken' "$HEADERS_STAGE/sybdb.h"; then
    echo "ERROR: $STUB_HEADERS/sybdb.h does not declare dbsetlfedauthtoken." >&2
    echo "       The FEDAUTH patch is applied to the library but the stub header is stale." >&2
    exit 1
fi

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
find "$XCFRAMEWORK_OUT" -mindepth 1 -maxdepth 1 ! -name Info.plist -exec basename {} \; | sed 's/^/  - /'
echo ""
echo "NEXT STEPS:"
echo "  1. Inspect: xcodebuild -checkFirstLaunchStatus; file ${XCFRAMEWORK_OUT}/*/libsybdb.a"
echo "  2. Publish the iOS libs and refresh their integrity baseline:"
echo "       scripts/publish-ios-libs.sh"
echo "       git add Libs/ios/checksums.sha256 && git commit -m 'build: update iOS xcframework checksums'"
