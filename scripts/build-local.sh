#!/usr/bin/env bash
set -euo pipefail

# Builds the app for this Mac and packages it as a DMG, with no Apple Developer account.
#
# scripts/build-release.sh cannot serve a fork. It signs with a Developer ID, embeds a
# provisioning profile and notarizes, and it signs the app against TablePro/TablePro.entitlements,
# which names team D7HJ5TFYCU and that team's iCloud container. An app cannot claim a team it
# holds no certificate for.
#
# So this signs ad-hoc against TablePro/TablePro.Local.entitlements, which claims nothing a
# provisioning profile has to grant. The Debug entitlements cannot serve either: their
# keychain-access-groups entry is `$(AppIdentifierPrefix)com.TablePro.shared`, an app group is
# granted by a profile, and the build fails outright with "requires a provisioning profile".
# KeychainHelper.resolveAccessGroup already returns nil when no team-prefixed group is present, so
# passwords save to the default group and nothing is lost but iCloud sync.
#
# Ad-hoc is enough for an app that never leaves the machine that built it: Gatekeeper checks
# quarantine, and a locally built bundle carries none.
#
# Usage: scripts/build-local.sh [arm64|x86_64]   (defaults to this Mac's own architecture)

# shellcheck source=lib/macos.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos.sh"

ARCH="${1:-$(uname -m)}"
PROJECT="TablePro.xcodeproj"
SCHEME="TablePro"
CONFIG="Release"
BUILD_DIR="build/Release"
APP_NAME="$(tablepro_app_name).app"
SIGN_IDENTITY="-"
ENTITLEMENTS="TablePro/TablePro.Local.entitlements"

cd "$REPO_ROOT"

# --- preflight ---------------------------------------------------------------

fail() {
    echo "ERROR: $1" >&2
    [ $# -gt 1 ] && echo "       $2" >&2
    exit 1
}

# `xcodebuild -version` answers before the licence is accepted, so it cannot be the check.
# Anything that actually compiles is refused until then, and the compiler is the cheapest of those.
if ! xcrun clang --version > /dev/null 2>&1; then
    fail "the Xcode tools refuse to run." \
        "Accept the licence once: sudo xcodebuild -license accept"
fi

command -v xcodegen > /dev/null || fail "xcodegen is not installed." "brew install xcodegen"

# Passed as TABLEPRO_ENTITLEMENTS rather than CODE_SIGN_ENTITLEMENTS. A setting given on the
# xcodebuild command line reaches every target in the build, and a Swift package resolves a
# relative path against its own checkout: CODE_SIGN_ENTITLEMENTS sent CodeEditSymbols looking for
# TablePro/TablePro.Local.entitlements inside ~/.spm-cache. Only the app target reads
# TABLEPRO_ENTITLEMENTS, the way only it reads TABLEPRO_PROVISIONING_PROFILE.

# A freshly installed Xcode has not unpacked CoreSimulator, and xcodebuild loads the simulator
# plug-in whatever it is building, so a macOS-only build fails on a framework it never uses.
if [ ! -d "/Library/Developer/PrivateFrameworks/CoreSimulator.framework" ]; then
    fail "Xcode has not finished its first-launch setup." "Run: xcodebuild -runFirstLaunch"
fi

[ -f "$LIBS_DIR/libpq.a" ] || fail "the static libraries are missing." \
    "Run scripts/download-libs.sh first."

case "$ARCH" in
    arm64 | x86_64) ;;
    *) fail "unknown architecture '$ARCH'. Pass arm64 or x86_64." ;;
esac

VERSION=$(sed -n 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*//p' Configs/Version.xcconfig | tr -d ' ')
[ -n "$VERSION" ] || fail "MARKETING_VERSION is missing from Configs/Version.xcconfig"

echo "Building $SCHEME $VERSION for $ARCH, signed ad-hoc."

# --- build -------------------------------------------------------------------

echo "==> Preparing static libraries"
prepare_arch_libs "$ARCH" libmariadb libpq libpgcommon libpgport libssl libcrypto \
    libmongoc libbson libhiredis libhiredis_ssl

echo "==> Creating OpenSSL dylibs"
scripts/create-openssl-dylibs.sh "$ARCH"

echo "==> Generating the Xcode project"
scripts/generate-project.sh macos

echo "==> Compiling"
SPM_CACHE_DIR="${HOME}/.spm-cache"
mkdir -p "$SPM_CACHE_DIR"
# The exit status is read from PIPESTATUS, not from the pipeline. `| grep ... || true` returns
# grep's status, so a failed compile would be swallowed and the stale app from the previous
# successful build in DerivedData would be copied, signed and shipped as if it were this one.
set +e
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -arch "$ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    TABLEPRO_ENTITLEMENTS="$ENTITLEMENTS" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    GCC_OPTIMIZATION_LEVEL=s \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    ENABLE_CODE_COVERAGE=NO \
    -skipPackagePluginValidation \
    -clonedSourcePackagesDirPath "$SPM_CACHE_DIR" \
    -derivedDataPath build/DerivedData \
    build 2>&1 | tee "build-local-${ARCH}.log" | grep -E "^(\*\*|error:)"
build_status=${PIPESTATUS[0]}
set -e
[ "$build_status" -eq 0 ] || fail "xcodebuild failed." "See build-local-${ARCH}.log"

APP_PATH="build/DerivedData/Build/Products/${CONFIG}/TablePro.app"
[ -d "$APP_PATH" ] || fail "the build produced no app at $APP_PATH" \
    "See build-local-${ARCH}.log"

# --- package -----------------------------------------------------------------

echo "==> Copying the bundle"
mkdir -p "$BUILD_DIR"
# Spotlight indexes the built bundle, and Launch Services then offers it beside the installed one
# and keeps the entry after the file is gone: the DMG staging copy lives for a few seconds and left
# a permanent second "DB VSF" that opened onto nothing. This marker keeps the whole build tree out
# of the index, which is where a build tree belongs.
touch build/.metadata_never_index
# Removed first: cp -R onto an existing bundle merges into it, so a rebuild would carry the
# previous build's files into the one being signed.
rm -rf "${BUILD_DIR:?}/$APP_NAME"
cp -R "$APP_PATH" "$BUILD_DIR/$APP_NAME"

TARGET="$BUILD_DIR/$APP_NAME"

# The menu bar reads CFBundleName, and Xcode synthesises that from PRODUCT_NAME whenever
# GENERATE_INFOPLIST_FILE is on, overriding whatever TablePro/Info.plist says. PRODUCT_NAME has to
# stay TablePro so the executable keeps the name MCPHandshakeFile.verifyHostExecutable and the
# build scripts expect, so the shipped name is written here instead, on the copy, before signing
# seals the plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleName $(tablepro_app_name)" "$TARGET/Contents/Info.plist"

FRAMEWORKS_DIR="$TARGET/Contents/Frameworks"
PLUGINS_DIR="$TARGET/Contents/PlugIns"

sign() {
    codesign -fs "$SIGN_IDENTITY" --force --options runtime "$@" > /dev/null 2>&1
}

echo "==> Signing, inside out"
if [ -d "$FRAMEWORKS_DIR" ]; then
    while IFS= read -r -d '' nested; do
        sign "$nested"
    done < <(find "$FRAMEWORKS_DIR" -name "*.xpc" -type d -print0 2> /dev/null)

    while IFS= read -r -d '' nested; do
        sign "$nested"
    done < <(find "$FRAMEWORKS_DIR" -name "*.app" -type d -print0 2> /dev/null)

    for item in "$FRAMEWORKS_DIR"/*.framework "$FRAMEWORKS_DIR"/*.dylib; do
        [ -e "$item" ] || continue
        sign "$item"
    done
fi

if [ -d "$PLUGINS_DIR" ]; then
    for plugin in "$PLUGINS_DIR"/*.tableplugin; do
        [ -d "$plugin" ] || continue
        name=$(basename "$plugin" .tableplugin)
        binary="$plugin/Contents/MacOS/$name"
        # The binary inside the bundle first, then the bundle: a bundle signed before its own
        # executable seals a hash that the next write invalidates.
        [ -f "$binary" ] && strip -x "$binary" && sign "$binary"
        sign "$plugin"
    done
fi

for helper in "$TARGET/Contents/MacOS"/*; do
    [ -f "$helper" ] || continue
    [ "$(basename "$helper")" = "TablePro" ] && continue
    sign "$helper"
done

codesign -fs "$SIGN_IDENTITY" --force --options runtime --entitlements "$ENTITLEMENTS" "$TARGET"

echo "==> Verifying the signature"
codesign --verify --deep --strict "$TARGET" || fail "the signature did not verify"

echo "==> Building the DMG"
SIGN_IDENTITY="$SIGN_IDENTITY" scripts/create-dmg.sh "$VERSION" "$ARCH" "$TARGET"

echo
echo "Done."
echo "  App: $TARGET"
echo "  DMG: $BUILD_DIR/$(tablepro_app_name)-${VERSION}-${ARCH}.dmg"
