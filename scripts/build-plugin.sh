#!/bin/bash
set -euo pipefail

# Build script for creating standalone plugin bundles
# Usage: ./scripts/build-plugin.sh <PluginTarget> [arm64|x86_64|both]
# Example: ./scripts/build-plugin.sh OracleDriverPlugin arm64

PLUGIN_TARGET="${1:?Usage: $0 <PluginTarget> [arm64|x86_64|both]}"
ARCH="${2:-both}"
PROJECT="TablePro.xcodeproj"
CONFIG="Release"
BUILD_DIR="build/Plugins"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Dat Ngo Quoc (D7HJ5TFYCU)}"
TEAM_ID="D7HJ5TFYCU"
NOTARIZE="${NOTARIZE:-false}"
APPLE_ID="${APPLE_ID:-datngoquoc@icloud.com}"

echo "Building plugin: $PLUGIN_TARGET for $ARCH"

build_plugin() {
    local arch=$1
    local build_dir="$BUILD_DIR/$arch"

    echo "Building $PLUGIN_TARGET ($arch)..." >&2

    # Use -scheme (not -target) with -derivedDataPath to ensure proper
    # transitive SPM dependency resolution in explicit module builds
    DERIVED_DATA_DIR="build/DerivedData"

    if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$PLUGIN_TARGET" \
        -configuration "$CONFIG" \
        -arch "$arch" \
        ONLY_ACTIVE_ARCH=YES \
        CONFIGURATION_BUILD_DIR="$(pwd)/$build_dir" \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        DEPLOYMENT_POSTPROCESSING=YES \
        STRIP_STYLE=non-global \
        -skipPackagePluginValidation \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        build > "build-plugin-${arch}.log" 2>&1; then
        echo "FATAL: xcodebuild failed for $PLUGIN_TARGET ($arch)" >&2
        echo "Last 30 lines of build log:" >&2
        tail -30 "build-plugin-${arch}.log" >&2
        exit 1
    fi

    # Find the built plugin bundle by target name
    local plugin_bundle="$build_dir/${PLUGIN_TARGET}.tableplugin"

    if [ ! -d "$plugin_bundle" ]; then
        echo "FATAL: Plugin bundle not found at $plugin_bundle" >&2
        exit 1
    fi

    echo "Built: $plugin_bundle" >&2

    # Stripping is handled by Xcode build settings (COPY_PHASE_STRIP, DEPLOYMENT_POSTPROCESSING)
    local plugin_name
    plugin_name=$(basename "$plugin_bundle" .tableplugin)
    local plugin_binary="$plugin_bundle/Contents/MacOS/$plugin_name"

    # Code sign inside-out: nested frameworks/dylibs first, then binary, then bundle
    echo "Code signing with: $SIGN_IDENTITY" >&2

    # Sign nested frameworks
    if [ -d "$plugin_bundle/Contents/Frameworks" ]; then
        find "$plugin_bundle/Contents/Frameworks" -name "*.framework" -o -name "*.dylib" | sort | while read -r nested; do
            echo "  Signing nested: $(basename "$nested")" >&2
            codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$nested"
        done
    fi

    # Sign the main binary
    if [ -f "$plugin_binary" ]; then
        codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$plugin_binary"
    fi

    # Sign the outer bundle
    codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$plugin_bundle"

    if ! codesign --verify --deep --strict "$plugin_bundle" 2>&1; then
        echo "FATAL: Code signature verification failed" >&2
        exit 1
    fi
    echo "Code signature verified" >&2

    # Only the path goes to stdout (return value)
    echo "$plugin_bundle"
}

create_zip() {
    local plugin_path=$1
    local arch=$2
    local plugin_name
    plugin_name=$(basename "$plugin_path" .tableplugin)
    local zip_name="${plugin_name}-${arch}.zip"
    local zip_path="$BUILD_DIR/$zip_name"

    echo "Creating ZIP: $zip_name"
    ditto -c -k --keepParent "$plugin_path" "$zip_path"

    # Print SHA-256 for registry manifest
    local sha256
    sha256=$(shasum -a 256 "$zip_path" | awk '{print $1}')
    # Write SHA-256 to sidecar file for CI automation
    echo "$sha256" > "${zip_path}.sha256"

    echo "ZIP created: $zip_path"
    echo "   SHA-256: $sha256"
    echo "   Size: $(ls -lh "$zip_path" | awk '{print $5}')"
}

notarize_zip() {
    local zip_path=$1

    if [ "$NOTARIZE" != "true" ]; then
        echo "Skipping notarization (set NOTARIZE=true to enable)"
        return
    fi

    echo "Submitting for notarization..."
    if xcrun notarytool submit "$zip_path" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --keychain-profile "notarytool-profile" \
        --wait; then
        echo "Notarization complete"
    else
        echo "FATAL: Notarization failed for $zip_path"
        exit 1
    fi
}

# Clean DerivedData for fresh builds; preserve BUILD_DIR across arch invocations
rm -rf build/DerivedData
mkdir -p "$BUILD_DIR"

case "$ARCH" in
    arm64|x86_64)
        plugin_path=$(build_plugin "$ARCH")
        create_zip "$plugin_path" "$ARCH"
        notarize_zip "$BUILD_DIR/$(basename "$plugin_path" .tableplugin)-${ARCH}.zip"
        ;;
    both)
        arm64_path=$(build_plugin "arm64")
        x86_path=$(build_plugin "x86_64")

        create_zip "$arm64_path" "arm64"
        create_zip "$x86_path" "x86_64"

        notarize_zip "$BUILD_DIR/$(basename "$arm64_path" .tableplugin)-arm64.zip"
        notarize_zip "$BUILD_DIR/$(basename "$x86_path" .tableplugin)-x86_64.zip"
        ;;
    *)
        echo "Invalid architecture: $ARCH (use arm64, x86_64, or both)"
        exit 1
        ;;
esac

echo ""
echo "Plugin build complete!"
echo "Output: $BUILD_DIR/"
ls -lh "$BUILD_DIR/"*.zip 2>/dev/null || echo "No ZIP files found"
