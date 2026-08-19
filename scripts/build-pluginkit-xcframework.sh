#!/usr/bin/env bash
set -euo pipefail

# Builds TableProPluginKit as a distributable XCFramework.
#
# A plugin has to link TableProPluginKit, and until now the only way to get it was to check out this
# repository and build the whole app project. That is why every driver lives under Plugins/ here: not
# because the plugin system requires it, but because the framework was not obtainable any other way.
# An XCFramework is the artifact that lets a driver live in its own repository.
#
# The framework is built with BUILD_LIBRARY_FOR_DISTRIBUTION=YES (declared on the target in
# project.yml), so it emits a .swiftinterface and its ABI is resilient. That is the same setting the
# app ships with, which is what lets a plugin built against an older PluginKit keep loading under a
# newer app. Do not build this with that flag off: the result would look fine and then break every
# consumer on the next release.
#
# Usage:
#   scripts/build-pluginkit-xcframework.sh [version]
#
# Produces build/TableProPluginKit.xcframework, a zip beside it, and prints the SHA-256 a consumer
# needs to pin. Publish with:
#   gh release upload pluginkit-v<version> build/TableProPluginKit-<version>.xcframework.zip

FRAMEWORK="TableProPluginKit"
PROJECT="TablePro.xcodeproj"
CONFIG="Release"
BUILD_DIR="build/pluginkit"
# Outside BUILD_DIR on purpose: that directory is wiped on every run, and a DerivedData inside it
# would force a full SwiftPM re-resolve of every dependency each time, which is minutes per build.
DERIVED_DATA="build/pluginkit-derived"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(grep -E 'static let currentPluginKitVersion[[:space:]]*=[[:space:]]*[0-9]+' \
        TablePro/Core/Plugins/PluginManager.swift | grep -oE '[0-9]+$' | head -1)
fi
if [ -z "$VERSION" ]; then
    echo "FATAL: could not resolve a version. Pass one, or check currentPluginKitVersion in PluginManager.swift." >&2
    exit 1
fi

if [ ! -d "$PROJECT" ]; then
    echo "FATAL: $PROJECT not found. Run scripts/generate-project.sh first." >&2
    exit 1
fi

# A Command Line Tools install has an xcodebuild that refuses every invocation. Point at a real
# Xcode only when the active one cannot build, so an explicit DEVELOPER_DIR is never overridden.
if [ ! -x "${DEVELOPER_DIR:-$(xcode-select -p 2> /dev/null)}/usr/bin/xcodebuild" ]; then
    if [ -x /Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild ]; then
        export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    elif [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    else
        echo "FATAL: no full Xcode found. Set DEVELOPER_DIR, or run xcode-select -s." >&2
        exit 1
    fi
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# One build covering both architectures, not two builds merged afterwards. An XCFramework separates
# slices by PLATFORM, so `-create-xcframework` rejects a macOS arm64 framework and a macOS x86_64
# framework as "two equivalent library definitions". Several architectures for one platform belong in
# a single universal binary, which is what ARCHS plus ONLY_ACTIVE_ARCH=NO produces.
OUT="$BUILD_DIR/universal"
mkdir -p "$OUT"

echo "Building $FRAMEWORK for arm64 and x86_64"
if ! xcodebuild \
    -project "$PROJECT" \
    -scheme "$FRAMEWORK" \
    -configuration "$CONFIG" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    SKIP_INSTALL=NO \
    CODE_SIGNING_ALLOWED=NO \
    CONFIGURATION_BUILD_DIR="$(pwd)/$OUT" \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation \
    build > "$BUILD_DIR/build.log" 2>&1; then
    echo "FATAL: xcodebuild failed" >&2
    grep -nE "error:|cannot find|undefined symbol" "$BUILD_DIR/build.log" | head -40 >&2 || true
    echo "Full log: $BUILD_DIR/build.log" >&2
    exit 1
fi

BUILT="$OUT/$FRAMEWORK.framework"
if [ ! -d "$BUILT" ]; then
    echo "FATAL: $BUILT was not produced" >&2
    exit 1
fi

# A framework with no .swiftinterface is one built without Library Evolution. It links today and
# breaks every consumer the next time an ABI-resilient change ships, so fail here instead.
if ! find "$BUILT" -name "*.swiftinterface" | grep -q .; then
    echo "FATAL: no .swiftinterface in the build. BUILD_LIBRARY_FOR_DISTRIBUTION did not take." >&2
    exit 1
fi

for arch in arm64 x86_64; do
    if ! lipo -archs "$BUILT/$FRAMEWORK" | tr ' ' '\n' | grep -qx "$arch"; then
        echo "FATAL: $arch missing from the framework binary. Got: $(lipo -archs "$BUILT/$FRAMEWORK")" >&2
        exit 1
    fi
done

XCFRAMEWORK="$BUILD_DIR/$FRAMEWORK.xcframework"
echo "Creating $XCFRAMEWORK"
if ! xcodebuild -create-xcframework \
    -framework "$BUILT" \
    -output "$XCFRAMEWORK" > "$BUILD_DIR/create-xcframework.log" 2>&1; then
    echo "FATAL: create-xcframework failed" >&2
    cat "$BUILD_DIR/create-xcframework.log" >&2
    exit 1
fi

# The zip is not reproducible: ditto records timestamps, so two builds of identical sources give
# different checksums. Pin the checksum of the artifact you actually publish, not of a local rebuild.
ARCHIVE="$BUILD_DIR/$FRAMEWORK-$VERSION.xcframework.zip"
ditto -c -k --keepParent "$XCFRAMEWORK" "$ARCHIVE"
CHECKSUM=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')

echo
echo "PluginKit version: $VERSION"
echo "XCFramework:       $XCFRAMEWORK"
echo "Archive:           $ARCHIVE"
echo "SHA-256:           $CHECKSUM"
echo
echo "Publish:"
echo "  gh release create pluginkit-v$VERSION \"$ARCHIVE\" --title \"TableProPluginKit $VERSION\" --repo TableProApp/TablePro"
