#!/bin/bash
set -eo pipefail

# Build static OpenSSL for iOS (device + simulator) → xcframework
#
# Produces: Libs/ios/OpenSSL.xcframework/
#   - ios-arm64/ (device)
#   - ios-arm64-simulator/ (simulator on Apple Silicon)
#
# Usage:
#   ./scripts/ios/build-openssl-ios.sh
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - curl

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../openssl-version.sh"
IOS_DEPLOY_TARGET="17.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIBS_DIR="$PROJECT_DIR/Libs/ios"
BUILD_DIR="$(mktemp -d)"
NCPU=$(sysctl -n hw.ncpu)

run_quiet() {
    local logfile
    logfile=$(mktemp)
    if ! "$@" > "$logfile" 2>&1; then
        echo "FAILED: $*"
        tail -50 "$logfile"
        rm -f "$logfile"
        return 1
    fi
    rm -f "$logfile"
}

cleanup() {
    echo "   Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

echo "Building static OpenSSL $OPENSSL_VERSION for iOS"
echo "   iOS deployment target: $IOS_DEPLOY_TARGET"
echo "   Build dir: $BUILD_DIR"

mkdir -p "$LIBS_DIR"

# --- Download OpenSSL ---

OPENSSL_TARBALL="$BUILD_DIR/openssl-$OPENSSL_VERSION.tar.gz"
OPENSSL_SRC="$BUILD_DIR/openssl-$OPENSSL_VERSION"

echo "=> Downloading OpenSSL $OPENSSL_VERSION..."
curl -sL "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" -o "$OPENSSL_TARBALL"

echo "   Verifying checksum..."
echo "$OPENSSL_SHA256  $OPENSSL_TARBALL" | shasum -a 256 -c - > /dev/null

tar xzf "$OPENSSL_TARBALL" -C "$BUILD_DIR"

# --- Build function ---

build_openssl_slice() {
    local PLATFORM=$1    # iphoneos or iphonesimulator
    local ARCH=$2        # arm64
    local TARGET=$3      # OpenSSL configure target
    local INSTALL_DIR="$BUILD_DIR/install-$PLATFORM-$ARCH"

    echo "=> Building OpenSSL for $PLATFORM ($ARCH)..."

    local SRC_COPY="$BUILD_DIR/openssl-$PLATFORM-$ARCH"
    cp -R "$OPENSSL_SRC" "$SRC_COPY"
    cd "$SRC_COPY"

    local SDK_PATH
    SDK_PATH=$(xcrun --sdk "$PLATFORM" --show-sdk-path)

    export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOY_TARGET"

    run_quiet ./Configure "$TARGET" \
        no-shared no-tests no-apps no-docs no-engine no-async \
        no-comp no-dtls no-psk no-srp no-ssl3 no-dso \
        --prefix="$INSTALL_DIR" \
        --openssldir="$INSTALL_DIR/ssl"

    run_quiet make -j"$NCPU"
    run_quiet make install_sw

    echo "   Installed to $INSTALL_DIR"
}

# --- Build device (arm64) ---

build_openssl_slice "iphoneos" "arm64" "ios64-xcrun"

# --- Build simulator (arm64) ---

# OpenSSL doesn't have a direct simulator target.
# Use iossimulator-xcrun with explicit arch.
SIMULATOR_SRC="$BUILD_DIR/openssl-iphonesimulator-arm64"
cp -R "$OPENSSL_SRC" "$SIMULATOR_SRC"
cd "$SIMULATOR_SRC"

SIMULATOR_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
SIMULATOR_INSTALL="$BUILD_DIR/install-iphonesimulator-arm64"

export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOY_TARGET"

echo "=> Building OpenSSL for iphonesimulator (arm64)..."

run_quiet ./Configure iossimulator-xcrun \
    no-shared no-tests no-apps no-docs no-engine no-async \
    no-comp no-dtls no-psk no-srp no-ssl3 no-dso \
    --prefix="$SIMULATOR_INSTALL" \
    --openssldir="$SIMULATOR_INSTALL/ssl"

run_quiet make -j"$NCPU"
run_quiet make install_sw

echo "   Installed to $SIMULATOR_INSTALL"

# --- Create xcframework ---

DEVICE_DIR="$BUILD_DIR/install-iphoneos-arm64"
SIM_DIR="$SIMULATOR_INSTALL"

# Remove old xcframework if exists
rm -rf "$LIBS_DIR/OpenSSL.xcframework"

echo "=> Creating OpenSSL.xcframework..."

# xcframework needs a single library per platform variant.
# Merge libssl + libcrypto into one fat archive per slice for simplicity,
# OR create separate xcframeworks. We'll keep them separate in the xcframework
# by creating a temporary merged lib.

# Device: merge libssl + libcrypto
mkdir -p "$BUILD_DIR/merged-device"
cp "$DEVICE_DIR/lib/libssl.a" "$BUILD_DIR/merged-device/"
cp "$DEVICE_DIR/lib/libcrypto.a" "$BUILD_DIR/merged-device/"
cp -R "$DEVICE_DIR/include" "$BUILD_DIR/merged-device/"

# Simulator: merge
mkdir -p "$BUILD_DIR/merged-sim"
cp "$SIM_DIR/lib/libssl.a" "$BUILD_DIR/merged-sim/"
cp "$SIM_DIR/lib/libcrypto.a" "$BUILD_DIR/merged-sim/"
cp -R "$SIM_DIR/include" "$BUILD_DIR/merged-sim/"

# Create two xcframeworks (one per lib)
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/merged-device/libssl.a" \
    -headers "$BUILD_DIR/merged-device/include" \
    -library "$BUILD_DIR/merged-sim/libssl.a" \
    -headers "$BUILD_DIR/merged-sim/include" \
    -output "$LIBS_DIR/OpenSSL-SSL.xcframework"

xcodebuild -create-xcframework \
    -library "$BUILD_DIR/merged-device/libcrypto.a" \
    -library "$BUILD_DIR/merged-sim/libcrypto.a" \
    -output "$LIBS_DIR/OpenSSL-Crypto.xcframework"

echo ""
echo "OpenSSL $OPENSSL_VERSION for iOS built successfully!"
echo "   $LIBS_DIR/OpenSSL-SSL.xcframework"
echo "   $LIBS_DIR/OpenSSL-Crypto.xcframework"

# --- Verify ---

echo ""
echo "=> Verifying device slice..."
lipo -info "$BUILD_DIR/merged-device/libssl.a"
otool -l "$BUILD_DIR/merged-device/libssl.a" | grep -A4 "LC_BUILD_VERSION" | head -5

echo ""
echo "=> Verifying simulator slice..."
lipo -info "$BUILD_DIR/merged-sim/libssl.a"
otool -l "$BUILD_DIR/merged-sim/libssl.a" | grep -A4 "LC_BUILD_VERSION" | head -5

echo ""
echo "Done!"
