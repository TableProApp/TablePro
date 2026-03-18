#!/bin/bash
set -euo pipefail

# Build script for creating architecture-specific releases
# Usage: ./build-release.sh [arm64|x86_64|both]

ARCH="${1:-both}"
PROJECT="TablePro.xcodeproj"
SCHEME="TablePro"
CONFIG="Release"
BUILD_DIR="build/Release"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Dat Ngo Quoc (D7HJ5TFYCU)}"
TEAM_ID="D7HJ5TFYCU"
NOTARIZE="${NOTARIZE:-false}"
APPLE_ID="${APPLE_ID:-datngoquoc@icloud.com}"

echo "🏗️  Building TablePro for: $ARCH"

# Ensure libmariadb.a has correct architecture
prepare_mariadb() {
    local target_arch=$1
    echo "📦 Preparing libmariadb.a for $target_arch..."

    # If libmariadb.a already exists with the correct architecture, skip preparation.
    # CI pre-copies the architecture-specific library from Homebrew.
    if [ -f "Libs/libmariadb.a" ] && lipo -info "Libs/libmariadb.a" 2>/dev/null | grep -q "$target_arch"; then
        local size
        size=$(ls -lh Libs/libmariadb.a 2>/dev/null | awk '{print $5}')
        echo "✅ libmariadb.a already present for $target_arch ($size), skipping"
        return 0
    fi

    # Change to Libs directory
    cd Libs || {
        echo "❌ FATAL: Cannot access Libs directory"
        exit 1
    }

    # Check if universal library exists
    if [ ! -f "libmariadb_universal.a" ]; then
        echo "❌ ERROR: libmariadb_universal.a not found!"
        echo "Run this first to create universal library:"
        echo "  lipo -create libmariadb_arm64.a libmariadb_x86_64.a -output libmariadb_universal.a"
        cd - > /dev/null
        exit 1
    fi

    # Extract thin slice for target architecture
    if ! lipo libmariadb_universal.a -thin "$target_arch" -output libmariadb.a; then
        echo "❌ FATAL: Failed to extract $target_arch slice from universal library"
        echo "Ensure the universal library contains $target_arch architecture"
        cd - > /dev/null
        exit 1
    fi

    # Verify the output file was created
    if [ ! -f "libmariadb.a" ]; then
        echo "❌ FATAL: libmariadb.a was not created successfully"
        cd - > /dev/null
        exit 1
    fi

    # Get and display size
    local size
    size=$(ls -lh libmariadb.a 2>/dev/null | awk '{print $5}')
    if [ -z "$size" ]; then
        size="unknown"
    fi

    echo "✅ libmariadb.a is now $target_arch-only ($size)"

    cd - > /dev/null || exit 1
}

# Ensure libpq + OpenSSL static libraries have correct architecture
prepare_libpq() {
    local target_arch=$1
    echo "📦 Preparing libpq + OpenSSL static libraries for $target_arch..."

    local all_ok=1
    for lib in libpq libpgcommon libpgport libssl libcrypto; do
        # If already present with the correct architecture, skip
        if [ -f "Libs/${lib}.a" ] && lipo -info "Libs/${lib}.a" 2>/dev/null | grep -q "$target_arch"; then
            continue
        fi

        if [ ! -f "Libs/${lib}_universal.a" ]; then
            echo "❌ ERROR: Libs/${lib}_universal.a not found!"
            echo "Run this first: ./scripts/build-libpq.sh both"
            all_ok=0
            continue
        fi

        if ! lipo "Libs/${lib}_universal.a" -thin "$target_arch" -output "Libs/${lib}.a"; then
            echo "❌ FATAL: Failed to extract $target_arch slice from ${lib}_universal.a"
            exit 1
        fi
    done

    if [ "$all_ok" -eq 0 ]; then
        exit 1
    fi

    echo "✅ libpq + OpenSSL libraries ready for $target_arch"
}

prepare_libmongoc() {
    local target_arch=$1
    echo "📦 Preparing libmongoc + libbson static libraries for $target_arch..."

    local all_ok=1
    for lib in libmongoc libbson; do
        # If already present with the correct architecture, skip
        if [ -f "Libs/${lib}.a" ] && lipo -info "Libs/${lib}.a" 2>/dev/null | grep -q "$target_arch"; then
            continue
        fi

        # Try arch-specific file first (libmongoc_arm64.a)
        if [ -f "Libs/${lib}_${target_arch}.a" ]; then
            cp "Libs/${lib}_${target_arch}.a" "Libs/${lib}.a"
            continue
        fi

        # Fall back to universal
        if [ ! -f "Libs/${lib}_universal.a" ]; then
            echo "❌ ERROR: Libs/${lib}_${target_arch}.a and Libs/${lib}_universal.a not found!"
            echo "Run this first: ./scripts/build-libmongoc.sh both"
            all_ok=0
            continue
        fi

        if ! lipo "Libs/${lib}_universal.a" -thin "$target_arch" -output "Libs/${lib}.a"; then
            echo "❌ FATAL: Failed to extract $target_arch slice from ${lib}_universal.a"
            exit 1
        fi
    done

    if [ "$all_ok" -eq 0 ]; then
        exit 1
    fi

    echo "✅ libmongoc + libbson libraries ready for $target_arch"
}

prepare_hiredis() {
    local target_arch=$1
    echo "📦 Preparing hiredis static libraries for $target_arch..."

    local all_ok=1
    for lib in libhiredis libhiredis_ssl; do
        # If already present with the correct architecture, skip
        if [ -f "Libs/${lib}.a" ] && lipo -info "Libs/${lib}.a" 2>/dev/null | grep -q "$target_arch"; then
            continue
        fi

        # Try arch-specific file first
        if [ -f "Libs/${lib}_${target_arch}.a" ]; then
            cp "Libs/${lib}_${target_arch}.a" "Libs/${lib}.a"
            continue
        fi

        # Fall back to universal
        if [ ! -f "Libs/${lib}_universal.a" ]; then
            echo "❌ ERROR: Libs/${lib}_${target_arch}.a and Libs/${lib}_universal.a not found!"
            echo "Run this first: ./scripts/build-hiredis.sh both"
            all_ok=0
            continue
        fi

        if ! lipo "Libs/${lib}_universal.a" -thin "$target_arch" -output "Libs/${lib}.a"; then
            echo "❌ FATAL: Failed to extract $target_arch slice from ${lib}_universal.a"
            exit 1
        fi
    done

    if [ "$all_ok" -eq 0 ]; then
        exit 1
    fi

    echo "✅ hiredis libraries ready for $target_arch"
}

# Bundle non-system dynamic libraries into the app bundle
# so the app runs without Homebrew on end-user machines.
bundle_dylibs() {
    local app_path=$1
    local binary="$app_path/Contents/MacOS/TablePro"
    local frameworks_dir="$app_path/Contents/Frameworks"

    echo "📦 Bundling dynamic libraries into app bundle..."
    mkdir -p "$frameworks_dir"

    # Iteratively discover and copy all non-system dylibs.
    # Each pass scans the main binary + already-copied dylibs;
    # repeat until no new dylibs are found (handles transitive deps).
    local changed=1
    while [ "$changed" -eq 1 ]; do
        changed=0
        for target in "$binary" "$frameworks_dir"/*.dylib; do
            [ -f "$target" ] || continue

            while IFS= read -r dep; do
                # Keep only non-system, non-rewritten absolute paths
                case "$dep" in
                    /usr/lib/*|/System/*|@*|"") continue ;;
                esac

                local name
                name=$(basename "$dep")

                # Already bundled
                [ -f "$frameworks_dir/$name" ] && continue

                if [ -f "$dep" ]; then
                    echo "   Copying $name"
                    cp "$dep" "$frameworks_dir/$name"
                    chmod 644 "$frameworks_dir/$name"
                    changed=1
                else
                    echo "   ⚠️  WARNING: $dep not found on disk, skipping"
                fi
            done < <(otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
        done
    done

    # Count bundled dylibs
    local count
    count=$(find "$frameworks_dir" -name '*.dylib' 2>/dev/null | wc -l | tr -d ' ')

    if [ "$count" -eq 0 ]; then
        echo "   No non-system dylibs to bundle"
        return 0
    fi

    # Rewrite each dylib's own install name
    for fw in "$frameworks_dir"/*.dylib; do
        [ -f "$fw" ] || continue
        local name
        name=$(basename "$fw")
        install_name_tool -id "@executable_path/../Frameworks/$name" "$fw"
    done

    # Rewrite all references in the main binary and every bundled dylib
    for target in "$binary" "$frameworks_dir"/*.dylib; do
        [ -f "$target" ] || continue

        while IFS= read -r dep; do
            case "$dep" in
                /usr/lib/*|/System/*|@*|"") continue ;;
            esac

            local name
            name=$(basename "$dep")

            if [ -f "$frameworks_dir/$name" ]; then
                install_name_tool -change "$dep" "@executable_path/../Frameworks/$name" "$target"
            fi
        done < <(otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
    done

    # Verify bundled dylibs are compatible with the deployment target.
    # Homebrew builds libraries targeting the *host* macOS version, so if
    # the build machine runs macOS 26.0, libpq will require 26.0 symbols
    # (e.g. strchrnul) that don't exist on earlier OS versions → launch crash.
    echo "   Verifying deployment target compatibility..."
    local deploy_target
    deploy_target=$(echo "$build_settings" | grep -m 1 '^\s*MACOSX_DEPLOYMENT_TARGET = ' | awk '{print $3}')
    if [ -n "$deploy_target" ]; then
        local deploy_major
        deploy_major=$(echo "$deploy_target" | cut -d. -f1)
        local failed=0
        for fw in "$frameworks_dir"/*.dylib; do
            [ -f "$fw" ] || continue
            local name min_ver min_major
            name=$(basename "$fw")
            # otool -l prints LC_BUILD_VERSION with minos field, or LC_VERSION_MIN_MACOSX with version field
            min_ver=$(otool -l "$fw" 2>/dev/null | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')
            if [ -z "$min_ver" ]; then
                min_ver=$(otool -l "$fw" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{found=1} found && /version/{print $2; exit}')
            fi
            if [ -n "$min_ver" ]; then
                min_major=$(echo "$min_ver" | cut -d. -f1)
                if [ "$min_major" -gt "$deploy_major" ]; then
                    echo "   ❌ FATAL: $name requires macOS $min_ver but deployment target is $deploy_target"
                    echo "      This library was built on a newer macOS. Rebuild libpq with:"
                    echo "        MACOSX_DEPLOYMENT_TARGET=$deploy_target brew reinstall libpq --build-from-source"
                    echo "      Or use a CI runner on macOS $deploy_target+"
                    failed=1
                fi
            fi
        done
        if [ "$failed" -eq 1 ]; then
            echo ""
            echo "   Bundled dylibs target a newer macOS than the app's deployment target."
            echo "   The app will crash at launch on macOS $deploy_target with 'Symbol not found'."
            exit 1
        fi
        echo "   ✅ All dylibs compatible with macOS $deploy_target"
    else
        echo "   ⚠️  WARNING: Could not determine deployment target, skipping dylib version check"
    fi

    echo "✅ Bundled $count dynamic libraries into Frameworks/"
    ls -lh "$frameworks_dir"/*.dylib 2>/dev/null
}

build_for_arch() {
    local arch=$1
    echo ""
    echo "🔨 Building for $arch..."

    # Fetch build settings once for this arch (used by build_for_arch and bundle_dylibs)
    echo "Fetching build settings..."
    if ! build_settings=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" -arch "$arch" -skipPackagePluginValidation -showBuildSettings 2>&1); then
        echo "❌ FATAL: xcodebuild -showBuildSettings failed"
        echo "$build_settings"
        exit 1
    fi

    # Prepare architecture-specific libraries
    prepare_mariadb "$arch"
    prepare_libpq "$arch"
    prepare_libmongoc "$arch"
    prepare_hiredis "$arch"

    # Remove AppIcon.icon if present — Xcode 26's automatic icon format
    # uses SVG rendering with GPU effects (shadows, translucency) that
    # crashes actool/ibtoold in headless CI environments.
    # The traditional AppIcon.appiconset in Assets.xcassets is used instead.
    if [ -d "TablePro/AppIcon.icon" ]; then
        echo "🎨 Removing AppIcon.icon (not supported in headless CI)..."
        rm -rf "TablePro/AppIcon.icon"
    fi

    # Persistent SPM package cache (speeds up CI on self-hosted runners)
    SPM_CACHE_DIR="${HOME}/.spm-cache"
    mkdir -p "$SPM_CACHE_DIR"

    # Inject provisioning profile UUID into pbxproj for the main app target only.
    # Command-line PROVISIONING_PROFILE_SPECIFIER applies to ALL targets (plugins,
    # SPM packages) which breaks them. Instead, replace the empty specifier in
    # the main app target's build settings directly.
    PROFILE_PATH=$(find ~/Library/MobileDevice/Provisioning\ Profiles -name "*.provisionprofile" -print -quit 2>/dev/null)
    if [ -n "${PROFILE_PATH:-}" ]; then
        PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" /dev/stdin <<< "$(security cms -D -i "$PROFILE_PATH" 2>/dev/null)" || true)
        if [ -n "${PROFILE_UUID:-}" ]; then
            echo "📋 Injecting provisioning profile into pbxproj: $PROFILE_UUID"
            # The main app target has PROVISIONING_PROFILE_SPECIFIER = "";
            # Other targets don't have this key at all, so this is safe.
            sed -i '' "s/PROVISIONING_PROFILE_SPECIFIER = \"\";/PROVISIONING_PROFILE_SPECIFIER = \"$PROFILE_UUID\";/g" "$PROJECT/project.pbxproj"
        fi
    fi

    # Build with xcodebuild
    echo "Running xcodebuild..."
    if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -arch "$arch" \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        ${ANALYTICS_HMAC_SECRET:+ANALYTICS_HMAC_SECRET="$ANALYTICS_HMAC_SECRET"} \
        -skipPackagePluginValidation \
        -clonedSourcePackagesDirPath "$SPM_CACHE_DIR" \
        build 2>&1 | tee "build-${arch}.log"; then
        echo "❌ FATAL: xcodebuild failed for $arch"
        echo "Check build-${arch}.log for details"
        exit 1
    fi
    echo "✅ Build succeeded for $arch"

    # Get binary path with validation
    DERIVED_DATA=$(echo "$build_settings" | grep -m 1 "BUILD_DIR" | awk '{print $3}')

    if [ -z "$DERIVED_DATA" ]; then
        echo "❌ FATAL: Failed to determine build directory from xcodebuild settings"
        echo "This usually indicates:"
        echo "  1. The Xcode project is corrupted"
        echo "  2. The scheme '$SCHEME' doesn't exist"
        echo "  3. Xcode changed its output format"
        echo ""
        echo "Run this command to debug:"
        echo "  xcodebuild -project '$PROJECT' -scheme '$SCHEME' -showBuildSettings | grep BUILD_DIR"
        exit 1
    fi

    APP_PATH="${DERIVED_DATA}/${CONFIG}/TablePro.app"
    echo "📂 Expected app path: $APP_PATH"

    # Verify app bundle exists
    if [ ! -d "$APP_PATH" ]; then
        echo "❌ ERROR: Built app not found at expected path: $APP_PATH"
        echo "Build may have failed silently"
        exit 1
    fi

    # Create release directory
    mkdir -p "$BUILD_DIR" || {
        echo "❌ FATAL: Failed to create release directory: $BUILD_DIR"
        exit 1
    }

    # Copy and rename app
    OUTPUT_NAME="TablePro-${arch}.app"
    echo "Copying app bundle to release directory..."
    if ! cp -R "$APP_PATH" "$BUILD_DIR/$OUTPUT_NAME"; then
        echo "❌ FATAL: Failed to copy app bundle"
        echo "Source: $APP_PATH"
        echo "Destination: $BUILD_DIR/$OUTPUT_NAME"
        exit 1
    fi

    # Verify the copy succeeded
    if [ ! -d "$BUILD_DIR/$OUTPUT_NAME" ]; then
        echo "❌ FATAL: App bundle was not copied successfully"
        exit 1
    fi

    # Remove any stale nested .app bundles in the bundle root (breaks codesign)
    for nested in "$BUILD_DIR/$OUTPUT_NAME"/*.app; do
        [ -d "$nested" ] && rm -rf "$nested"
    done

    # Strip plugin binaries — removes debug symbols, code coverage (__LLVM_COV),
    # and dead LINKEDIT metadata that bloat the bundle (e.g., OracleDriver 43MB → ~15MB)
    echo "🔪 Stripping plugin binaries..."
    PLUGINS_DIR="$BUILD_DIR/$OUTPUT_NAME/Contents/PlugIns"
    if [ -d "$PLUGINS_DIR" ]; then
        for plugin in "$PLUGINS_DIR"/*.tableplugin; do
            [ -d "$plugin" ] || continue
            local plugin_name
            plugin_name=$(basename "$plugin" .tableplugin)
            local plugin_binary="$plugin/Contents/MacOS/$plugin_name"
            if [ -f "$plugin_binary" ]; then
                local before
                before=$(ls -lh "$plugin_binary" | awk '{print $5}')
                strip -x "$plugin_binary"
                local after
                after=$(ls -lh "$plugin_binary" | awk '{print $5}')
                echo "   $plugin_name: $before → $after"
            fi
        done
        echo "✅ Plugin binaries stripped"
    fi

    # Strip main binary
    local main_binary="$BUILD_DIR/$OUTPUT_NAME/Contents/MacOS/TablePro"
    if [ -f "$main_binary" ]; then
        local before
        before=$(ls -lh "$main_binary" | awk '{print $5}')
        strip -x "$main_binary"
        local after
        after=$(ls -lh "$main_binary" | awk '{print $5}')
        echo "🔪 Main binary: $before → $after"
    fi

    # Strip PluginKit framework
    local pluginkit_binary="$BUILD_DIR/$OUTPUT_NAME/Contents/Frameworks/TableProPluginKit.framework/Versions/A/TableProPluginKit"
    if [ -f "$pluginkit_binary" ]; then
        strip -x "$pluginkit_binary"
        echo "   TableProPluginKit framework stripped"
    fi

    # Bundle non-system dynamic libraries (libpq, OpenSSL, etc.)
    bundle_dylibs "$BUILD_DIR/$OUTPUT_NAME"

    # Sign the entire app bundle with Developer ID.
    # Must deep-sign all nested executables (Sparkle has XPC services, helper apps).
    # Sign from inside out: nested binaries → frameworks → dylibs → app.
    echo "🔏 Signing app bundle with: $SIGN_IDENTITY"
    FRAMEWORKS_DIR="$BUILD_DIR/$OUTPUT_NAME/Contents/Frameworks"

    # Sign all nested XPC services, helper apps, and executables inside frameworks
    while IFS= read -r -d '' binary; do
        codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$binary"
    done < <(find "$FRAMEWORKS_DIR" -type f \( -name "*.xpc" -o -perm +111 \) -not -name "*.dylib" -not -name "*.plist" -not -name "*.h" -not -name "*.strings" -not -name "*.nib" -not -name "*.png" -not -name "*.icns" -not -name "*.car" -not -name "CodeResources" -not -name "Info.plist" -print0 2>/dev/null)

    # Sign XPC service bundles
    while IFS= read -r -d '' xpc; do
        codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$xpc"
    done < <(find "$FRAMEWORKS_DIR" -name "*.xpc" -type d -print0 2>/dev/null)

    # Sign nested .app bundles (e.g., Sparkle's Updater.app)
    while IFS= read -r -d '' app; do
        codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$app"
    done < <(find "$FRAMEWORKS_DIR" -name "*.app" -type d -print0 2>/dev/null)

    # Sign top-level frameworks
    for fw in "$FRAMEWORKS_DIR"/*.framework; do
        [ -d "$fw" ] || continue
        codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$fw"
    done

    # Sign top-level dylibs
    for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
        [ -f "$dylib" ] || continue
        codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$dylib"
    done

    # Sign plugin bundles (stripped binaries need re-signing)
    # Sign binary first, then bundle — inside-out order required for valid signatures
    if [ -d "$PLUGINS_DIR" ]; then
        for plugin in "$PLUGINS_DIR"/*.tableplugin; do
            [ -d "$plugin" ] || continue
            local plugin_name
            plugin_name=$(basename "$plugin" .tableplugin)
            local plugin_binary="$plugin/Contents/MacOS/$plugin_name"
            # Sign the binary inside the bundle first
            if [ -f "$plugin_binary" ]; then
                codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$plugin_binary"
            fi
            # Then sign the bundle
            codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$plugin"
        done
    fi

    # Embed provisioning profile (required for iCloud entitlements)
    PROFILE=$(find ~/Library/MobileDevice/Provisioning\ Profiles -name "*.provisionprofile" -print -quit 2>/dev/null)
    if [ -n "$PROFILE" ]; then
        echo "📋 Embedding provisioning profile: $(basename "$PROFILE")"
        cp "$PROFILE" "$BUILD_DIR/$OUTPUT_NAME/Contents/embedded.provisionprofile"
    fi

    # Sign the app bundle last
    codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp --entitlements "TablePro/TablePro.entitlements" "$BUILD_DIR/$OUTPUT_NAME"
    echo "✅ Code signing complete"

    # Verify signature
    if ! codesign --verify --deep --strict "$BUILD_DIR/$OUTPUT_NAME" 2>&1; then
        echo "❌ FATAL: Code signature verification failed"
        exit 1
    fi
    echo "✅ Signature verified"

    # Verify binary exists inside the copied bundle
    BINARY_PATH="$BUILD_DIR/$OUTPUT_NAME/Contents/MacOS/TablePro"
    if [ ! -f "$BINARY_PATH" ]; then
        echo "❌ FATAL: Binary not found in copied app bundle: $BINARY_PATH"
        exit 1
    fi

    # Verify binary is not empty
    if [ ! -s "$BINARY_PATH" ]; then
        echo "❌ FATAL: Binary file is empty"
        exit 1
    fi

    # Verify binary is executable
    if [ ! -x "$BINARY_PATH" ]; then
        echo "❌ FATAL: Binary is not executable"
        exit 1
    fi

    # Get size
    SIZE=$(ls -lh "$BINARY_PATH" 2>/dev/null | awk '{print $5}')
    if [ -z "$SIZE" ]; then
        echo "⚠️  WARNING: Could not determine binary size"
        SIZE="unknown"
    fi

    echo "✅ Built: $OUTPUT_NAME ($SIZE)"

    # Verify and display architecture
    if ! lipo -info "$BINARY_PATH"; then
        echo "⚠️  WARNING: Could not verify binary architecture"
    fi
}

# Main
case "$ARCH" in
    arm64)
        build_for_arch arm64
        ;;
    x86_64)
        build_for_arch x86_64
        ;;
    both)
        build_for_arch arm64
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        build_for_arch x86_64
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|both]"
        exit 1
        ;;
esac

echo ""
echo "🎉 Build complete!"
echo "📁 Output: $BUILD_DIR/"

if ! ls -lh "$BUILD_DIR" 2>/dev/null; then
    echo "⚠️  WARNING: Could not list build directory contents"
    echo "Directory may be empty or inaccessible"
fi

# Notarization (opt-in via NOTARIZE=true)
if [ "$NOTARIZE" = "true" ]; then
    echo ""
    echo "📮 Notarizing..."

    # Requires: xcrun notarytool store-credentials "TablePro" --apple-id ... --team-id ... --password ...
    for app in "$BUILD_DIR"/TablePro-*.app; do
        [ -d "$app" ] || continue
        name=$(basename "$app")
        zip_path="$BUILD_DIR/${name%.app}.zip"
        echo "   Zipping $name..."
        ditto -c -k --keepParent "$app" "$zip_path"

        echo "   Submitting $name for notarization..."
        if xcrun notarytool submit "$zip_path" --keychain-profile "TablePro" --wait; then
            echo "   Stapling $name..."
            xcrun stapler staple "$app"
            echo "   ✅ $name notarized and stapled"
        else
            echo "   ❌ Notarization failed for $name"
            exit 1
        fi
        rm -f "$zip_path"
    done
    echo "✅ Notarization complete"
fi
