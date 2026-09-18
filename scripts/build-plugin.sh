#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/notarize.sh"

# Build script for creating standalone plugin bundles
# Usage: ./scripts/build-plugin.sh <PluginTarget> [arm64|x86_64|both] [version]
# Example: ./scripts/build-plugin.sh OracleDriverPlugin arm64 1.0.0
#
# Version (3rd arg or PLUGIN_VERSION env) is injected as MARKETING_VERSION so
# CFBundleShortVersionString in the built bundle matches the registry version.
# Required for bundled drivers that also ship via registry. Without it, the
# user copy ties with built-in v1.0 and PluginManager prunes it on load.

PLUGIN_TARGET="${1:?Usage: $0 <PluginTarget> [arm64|x86_64|both] [version]}"
ARCH="${2:-both}"
PLUGIN_VERSION="${3:-${PLUGIN_VERSION:-}}"
PROJECT="TablePro.xcodeproj"
CONFIG="Release"
BUILD_DIR="build/Plugins"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
NOTARIZE="${NOTARIZE:-false}"

if [ -z "$TEAM_ID" ]; then
    echo "ERROR: TEAM_ID is not set. Pass via env or set in your shell profile." >&2
    echo "       Example: TEAM_ID=ABCDEFGHIJ ./scripts/build-plugin.sh $PLUGIN_TARGET" >&2
    exit 1
fi

if [ -z "$SIGN_IDENTITY" ]; then
    # Try the canonical "Developer ID Application: <Name> (<TEAMID>)" pattern.
    # If your keychain stores the identity differently, set SIGN_IDENTITY explicitly.
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' -v team="$TEAM_ID" '$2 ~ /Developer ID Application/ && $2 ~ team {print $2; exit}')
    if [ -z "$SIGN_IDENTITY" ]; then
        echo "ERROR: No Developer ID Application identity found in keychain for team $TEAM_ID." >&2
        echo "       Either install the cert or set SIGN_IDENTITY explicitly." >&2
        exit 1
    fi
fi

if [ -n "$PLUGIN_VERSION" ]; then
    echo "Building plugin: $PLUGIN_TARGET v$PLUGIN_VERSION for $ARCH"
else
    echo "Building plugin: $PLUGIN_TARGET for $ARCH (no version override)"
fi

build_plugin() {
    local arch=$1
    local build_dir="$BUILD_DIR/$arch"

    echo "Building $PLUGIN_TARGET ($arch)..." >&2

    # Use -scheme (not -target) with -derivedDataPath to ensure proper
    # transitive SPM dependency resolution in explicit module builds.
    # project.yml declares one shared scheme per plugin target, named after the target.
    DERIVED_DATA_DIR="build/DerivedData"

    local marketing_version_arg=""
    if [ -n "$PLUGIN_VERSION" ]; then
        marketing_version_arg="MARKETING_VERSION=$PLUGIN_VERSION"
    fi

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
        ${marketing_version_arg:+"$marketing_version_arg"} \
        -skipPackagePluginValidation \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        build > "build-plugin-${arch}.log" 2>&1; then
        echo "FATAL: xcodebuild failed for $PLUGIN_TARGET ($arch)" >&2
        echo "=== Swift errors (grep error:) ===" >&2
        grep -nE "error:|cannot|undefined symbol" "build-plugin-${arch}.log" | head -40 >&2 || true
        echo "=== Last 80 lines of build log ===" >&2
        tail -80 "build-plugin-${arch}.log" >&2
        exit 1
    fi

    # Find the built plugin bundle by target name
    local plugin_bundle="$build_dir/${PLUGIN_TARGET}.tableplugin"

    if [ ! -d "$plugin_bundle" ]; then
        echo "FATAL: Plugin bundle not found at $plugin_bundle" >&2
        exit 1
    fi

    echo "Built: $plugin_bundle" >&2

    if [ -n "$PLUGIN_VERSION" ]; then
        actual_version=$(plutil -extract CFBundleShortVersionString raw -o - "$plugin_bundle/Contents/Info.plist" 2>/dev/null || echo "")
        if [ "$actual_version" != "$PLUGIN_VERSION" ]; then
            echo "FATAL: Built bundle CFBundleShortVersionString='$actual_version' but expected '$PLUGIN_VERSION'" >&2
            echo "       MARKETING_VERSION injection failed. Users would see 'Update to v$PLUGIN_VERSION' loops." >&2
            exit 1
        fi
        echo "Bundle version verified: CFBundleShortVersionString=$actual_version" >&2
    fi

    # Strip the plugin binary to reduce size
    local plugin_name
    plugin_name=$(basename "$plugin_bundle" .tableplugin)
    local plugin_binary="$plugin_bundle/Contents/MacOS/$plugin_name"
    if [ -f "$plugin_binary" ]; then
        local before after
        before=$(ls -lh "$plugin_binary" | awk '{print $5}')
        strip -x "$plugin_binary"
        after=$(ls -lh "$plugin_binary" | awk '{print $5}')
        echo "Stripped binary: $before -> $after" >&2
    fi

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

# Notarization has to happen BEFORE create_zip, and it has to staple.
#
# Gatekeeper refuses to load an unnotarized bundle into TablePro, and
# com.apple.security.cs.disable-library-validation does not exempt it: a quarantined
# unnotarized plugin fails with "library load disallowed by system policy", and the user
# gets a "could not verify it is free of malware" panel instead of a driver. Every plugin
# published before this ran was unnotarized, because the workflow gated the step on an
# environment variable nothing ever set.
#
# Stapling rewrites the bundle, so the distribution zip and its SHA-256 must both be produced
# after it: the registry manifest pins that checksum and PluginInstaller rejects a mismatch.
notarize_plugin() {
    if [ "$NOTARIZE" != "true" ]; then
        echo "Skipping notarization (set NOTARIZE=true to enable)"
        return
    fi
    # "open", not "exec": a plugin bundle is opened by the app, not launched.
    notarize_and_staple "$1" open
}

# TablePro.xcodeproj is generated and not in git, so a fresh checkout has none.
# Generation also declares the per-plugin scheme this script builds with.
scripts/generate-project.sh

# Clean DerivedData for fresh builds; preserve BUILD_DIR across arch invocations
rm -rf build/DerivedData
mkdir -p "$BUILD_DIR"

case "$ARCH" in
    arm64|x86_64)
        plugin_path=$(build_plugin "$ARCH")
        notarize_plugin "$plugin_path"
        create_zip "$plugin_path" "$ARCH"
        ;;
    both)
        arm64_path=$(build_plugin "arm64")
        x86_path=$(build_plugin "x86_64")

        notarize_plugin "$arm64_path"
        notarize_plugin "$x86_path"

        create_zip "$arm64_path" "arm64"
        create_zip "$x86_path" "x86_64"
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
