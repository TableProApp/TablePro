#!/bin/bash
set -euo pipefail

# Build script for creating architecture-specific releases using Apple's
# standard archive + export flow.
#
# Usage: ./build-release.sh [arm64|x86_64|both]

ARCH="${1:-both}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="TablePro.xcodeproj"
SCHEME="TablePro"
CONFIG="Release"
BUILD_DIR="build/Release"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Dat Ngo Quoc (D7HJ5TFYCU)}"
TEAM_ID="D7HJ5TFYCU"
NOTARIZE="${NOTARIZE:-false}"
APPLE_ID="${APPLE_ID:-datngoquoc@icloud.com}"
ENTITLEMENTS="$REPO_ROOT/TablePro/TablePro.entitlements"

echo "🏗️  Building TablePro for: $ARCH"

# ──────────────────────────────────────────────────────────────────────
# Library Preparation (lipo slicing — keeps only the target architecture)
# ──────────────────────────────────────────────────────────────────────

prepare_mariadb() {
    local target_arch=$1
    echo "📦 Preparing libmariadb.a for $target_arch..."

    if [ -f "Libs/libmariadb.a" ] && lipo -info "Libs/libmariadb.a" 2>/dev/null | grep -q "$target_arch"; then
        local size
        size=$(ls -lh Libs/libmariadb.a 2>/dev/null | awk '{print $5}')
        echo "✅ libmariadb.a already present for $target_arch ($size), skipping"
        return 0
    fi

    cd Libs || { echo "❌ FATAL: Cannot access Libs directory"; exit 1; }

    if [ ! -f "libmariadb_universal.a" ]; then
        echo "❌ ERROR: libmariadb_universal.a not found!"
        echo "Run this first: lipo -create libmariadb_arm64.a libmariadb_x86_64.a -output libmariadb_universal.a"
        cd - > /dev/null; exit 1
    fi

    if ! lipo libmariadb_universal.a -thin "$target_arch" -output libmariadb.a; then
        echo "❌ FATAL: Failed to extract $target_arch slice"
        cd - > /dev/null; exit 1
    fi

    local size
    size=$(ls -lh libmariadb.a 2>/dev/null | awk '{print $5}')
    echo "✅ libmariadb.a is now $target_arch-only (${size:-unknown})"
    cd - > /dev/null || exit 1
}

prepare_libpq() {
    local target_arch=$1
    echo "📦 Preparing libpq + OpenSSL static libraries for $target_arch..."

    local all_ok=1
    for lib in libpq libpgcommon libpgport libssl libcrypto; do
        if [ -f "Libs/${lib}.a" ] && lipo -info "Libs/${lib}.a" 2>/dev/null | grep -q "$target_arch"; then
            continue
        fi
        if [ ! -f "Libs/${lib}_universal.a" ]; then
            echo "❌ ERROR: Libs/${lib}_universal.a not found!"
            all_ok=0; continue
        fi
        if ! lipo "Libs/${lib}_universal.a" -thin "$target_arch" -output "Libs/${lib}.a"; then
            echo "❌ FATAL: Failed to extract $target_arch slice from ${lib}_universal.a"; exit 1
        fi
    done
    [ "$all_ok" -eq 0 ] && exit 1
    echo "✅ libpq + OpenSSL libraries ready for $target_arch"
}

prepare_libmongoc() {
    local target_arch=$1
    echo "📦 Preparing libmongoc + libbson static libraries for $target_arch..."

    local all_ok=1
    for lib in libmongoc libbson; do
        if [ -f "Libs/${lib}.a" ] && lipo -info "Libs/${lib}.a" 2>/dev/null | grep -q "$target_arch"; then
            continue
        fi
        if [ -f "Libs/${lib}_${target_arch}.a" ]; then
            cp "Libs/${lib}_${target_arch}.a" "Libs/${lib}.a"; continue
        fi
        if [ ! -f "Libs/${lib}_universal.a" ]; then
            echo "❌ ERROR: Libs/${lib}_${target_arch}.a and Libs/${lib}_universal.a not found!"
            all_ok=0; continue
        fi
        if ! lipo "Libs/${lib}_universal.a" -thin "$target_arch" -output "Libs/${lib}.a"; then
            echo "❌ FATAL: Failed to extract $target_arch slice from ${lib}_universal.a"; exit 1
        fi
    done
    [ "$all_ok" -eq 0 ] && exit 1
    echo "✅ libmongoc + libbson libraries ready for $target_arch"
}

prepare_hiredis() {
    local target_arch=$1
    echo "📦 Preparing hiredis static libraries for $target_arch..."

    local all_ok=1
    for lib in libhiredis libhiredis_ssl; do
        if [ -f "Libs/${lib}.a" ] && lipo -info "Libs/${lib}.a" 2>/dev/null | grep -q "$target_arch"; then
            continue
        fi
        if [ -f "Libs/${lib}_${target_arch}.a" ]; then
            cp "Libs/${lib}_${target_arch}.a" "Libs/${lib}.a"; continue
        fi
        if [ ! -f "Libs/${lib}_universal.a" ]; then
            echo "❌ ERROR: Libs/${lib}_${target_arch}.a and Libs/${lib}_universal.a not found!"
            all_ok=0; continue
        fi
        if ! lipo "Libs/${lib}_universal.a" -thin "$target_arch" -output "Libs/${lib}.a"; then
            echo "❌ FATAL: Failed to extract $target_arch slice from ${lib}_universal.a"; exit 1
        fi
    done
    [ "$all_ok" -eq 0 ] && exit 1
    echo "✅ hiredis libraries ready for $target_arch"
}

# ──────────────────────────────────────────────────────────────────────
# ExportOptions.plist Generation
# ──────────────────────────────────────────────────────────────────────

generate_export_options() {
    local plist_path=$1

    # Resolve provisioning profile name from installed profiles
    local profile_path profile_name
    profile_path=$(find ~/Library/MobileDevice/Provisioning\ Profiles -name "*.provisionprofile" -print -quit 2>/dev/null || true)

    if [ -n "${profile_path:-}" ]; then
        profile_name=$(/usr/libexec/PlistBuddy -c "Print Name" /dev/stdin <<< "$(security cms -D -i "$profile_path" 2>/dev/null)" 2>/dev/null || true)
    fi

    if [ -z "${profile_name:-}" ]; then
        echo "⚠️  No provisioning profile found — exporting without profile"
        cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST
    else
        echo "📋 Using provisioning profile: $profile_name"
        cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>provisioningProfiles</key>
    <dict>
        <key>com.TablePro</key>
        <string>${profile_name}</string>
    </dict>
</dict>
</plist>
PLIST
    fi
}

# ──────────────────────────────────────────────────────────────────────
# Dylib Bundling (post-export — Homebrew dylibs vary by machine/arch)
# ──────────────────────────────────────────────────────────────────────

bundle_dylibs() {
    local app_path=$1
    local binary="$app_path/Contents/MacOS/TablePro"
    local frameworks_dir="$app_path/Contents/Frameworks"

    echo "📦 Bundling dynamic libraries into app bundle..."
    mkdir -p "$frameworks_dir"

    # Iteratively discover and copy all non-system dylibs (handles transitive deps)
    local changed=1
    while [ "$changed" -eq 1 ]; do
        changed=0
        for target in "$binary" "$frameworks_dir"/*.dylib; do
            [ -f "$target" ] || continue
            while IFS= read -r dep; do
                case "$dep" in
                    /usr/lib/*|/System/*|@*|"") continue ;;
                esac
                local name
                name=$(basename "$dep")
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

    local count
    count=$(find "$frameworks_dir" -name '*.dylib' 2>/dev/null | wc -l | tr -d ' ')

    if [ "$count" -eq 0 ]; then
        echo "   No non-system dylibs to bundle"
        return 0
    fi

    # Rewrite install names
    for fw in "$frameworks_dir"/*.dylib; do
        [ -f "$fw" ] || continue
        local name
        name=$(basename "$fw")
        install_name_tool -id "@executable_path/../Frameworks/$name" "$fw"
    done

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

    # Verify bundled dylibs are compatible with the deployment target
    echo "   Verifying deployment target compatibility..."
    local deploy_target
    deploy_target=$(grep -m 1 '^\s*MACOSX_DEPLOYMENT_TARGET = ' <<< "$build_settings" | awk '{print $3}')
    if [ -n "$deploy_target" ]; then
        local deploy_major
        deploy_major=$(echo "$deploy_target" | cut -d. -f1)
        local failed=0
        for fw in "$frameworks_dir"/*.dylib; do
            [ -f "$fw" ] || continue
            local name min_ver min_major
            name=$(basename "$fw")
            min_ver=$(otool -l "$fw" 2>/dev/null | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')
            if [ -z "$min_ver" ]; then
                min_ver=$(otool -l "$fw" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/{found=1} found && /version/{print $2; exit}')
            fi
            if [ -n "$min_ver" ]; then
                min_major=$(echo "$min_ver" | cut -d. -f1)
                if [ "$min_major" -gt "$deploy_major" ]; then
                    echo "   ❌ FATAL: $name requires macOS $min_ver but deployment target is $deploy_target"
                    echo "      Rebuild with: MACOSX_DEPLOYMENT_TARGET=$deploy_target brew reinstall libpq --build-from-source"
                    failed=1
                fi
            fi
        done
        if [ "$failed" -eq 1 ]; then
            echo "   Bundled dylibs target a newer macOS than the app's deployment target."
            exit 1
        fi
        echo "   ✅ All dylibs compatible with macOS $deploy_target"
    else
        echo "   ⚠️  WARNING: Could not determine deployment target, skipping dylib version check"
    fi

    echo "✅ Bundled $count dynamic libraries into Frameworks/"
    ls -lh "$frameworks_dir"/*.dylib 2>/dev/null
}

# Re-sign only the newly bundled dylibs and the outer app seal.
# Everything else (frameworks, plugins, XPC services) was already signed
# correctly by xcodebuild -exportArchive.
resign_after_dylib_bundle() {
    local app_path=$1
    local frameworks_dir="$app_path/Contents/Frameworks"

    echo "🔏 Re-signing after dylib bundling..."

    # Sign each bundled dylib
    for dylib in "$frameworks_dir"/*.dylib; do
        [ -f "$dylib" ] || continue
        codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp "$dylib"
    done

    # Re-seal the outer app bundle (entitlements already embedded by exportArchive)
    codesign -fs "$SIGN_IDENTITY" --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" "$app_path"

    if ! codesign --verify --deep --strict "$app_path" 2>&1; then
        echo "❌ FATAL: Code signature verification failed after re-sign"
        exit 1
    fi
    echo "✅ Code signature verified"
}

# ──────────────────────────────────────────────────────────────────────
# Main Build Function (archive + export)
# ──────────────────────────────────────────────────────────────────────

build_for_arch() {
    local arch=$1
    echo ""
    echo "🔨 Building for $arch..."

    # Fetch build settings (used by bundle_dylibs for deployment target check)
    echo "Fetching build settings..."
    if ! build_settings=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" -arch "$arch" -skipPackagePluginValidation -showBuildSettings 2>&1); then
        echo "❌ FATAL: xcodebuild -showBuildSettings failed"
        echo "$build_settings"
        exit 1
    fi

    # Prepare architecture-specific static libraries
    prepare_mariadb "$arch"
    prepare_libpq "$arch"
    prepare_libmongoc "$arch"
    prepare_hiredis "$arch"

    # Remove AppIcon.icon if present — Xcode 26's automatic icon format
    # crashes actool/ibtoold in headless CI environments.
    if [ -d "TablePro/AppIcon.icon" ]; then
        echo "🎨 Removing AppIcon.icon (not supported in headless CI)..."
        rm -rf "TablePro/AppIcon.icon"
    fi

    # Persistent SPM package cache
    SPM_CACHE_DIR="${HOME}/.spm-cache"
    mkdir -p "$SPM_CACHE_DIR"

    # Generate ExportOptions.plist
    local export_options="build/ExportOptions-${arch}.plist"
    mkdir -p build
    generate_export_options "$export_options"

    # ── Step 1: Archive ──
    local archive_path="build/TablePro-${arch}.xcarchive"
    echo "📦 Archiving..."
    if ! xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIG" \
        -arch "$arch" \
        -archivePath "$archive_path" \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        ${ANALYTICS_HMAC_SECRET:+ANALYTICS_HMAC_SECRET="$ANALYTICS_HMAC_SECRET"} \
        -skipPackagePluginValidation \
        -clonedSourcePackagesDirPath "$SPM_CACHE_DIR" \
        2>&1 | tee "build-${arch}.log"; then
        echo "❌ FATAL: xcodebuild archive failed for $arch"
        echo "Check build-${arch}.log for details"
        exit 1
    fi
    echo "✅ Archive succeeded for $arch"

    # Verify archive was created
    if [ ! -d "$archive_path" ]; then
        echo "❌ FATAL: Archive not found at $archive_path"
        exit 1
    fi

    # ── Step 2: Export ──
    local export_path="build/Export-${arch}"
    echo "📤 Exporting archive..."
    if ! xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportOptionsPlist "$export_options" \
        -exportPath "$export_path" \
        2>&1 | tee -a "build-${arch}.log"; then
        echo "❌ FATAL: xcodebuild -exportArchive failed for $arch"
        exit 1
    fi
    echo "✅ Export succeeded for $arch"

    # Locate exported app
    APP_PATH="$export_path/TablePro.app"
    if [ ! -d "$APP_PATH" ]; then
        echo "❌ FATAL: Exported app not found at $APP_PATH"
        exit 1
    fi

    # ── Step 3: Collect dSYMs ──
    local dsym_dir="build/dSYMs-${arch}"
    mkdir -p "$dsym_dir"
    if [ -d "$archive_path/dSYMs" ]; then
        echo "📋 Collecting dSYMs..."
        cp -R "$archive_path/dSYMs/"*.dSYM "$dsym_dir/" 2>/dev/null || true
        local dsym_count
        dsym_count=$(find "$dsym_dir" -name "*.dSYM" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
        echo "✅ Collected $dsym_count dSYM(s)"
    else
        echo "⚠️  No dSYMs found in archive"
    fi

    # ── Step 4: Bundle Homebrew dylibs (post-export) ──
    bundle_dylibs "$APP_PATH"

    # Re-sign only the newly added dylibs + outer app seal
    resign_after_dylib_bundle "$APP_PATH"

    # ── Step 5: Copy to release directory ──
    mkdir -p "$BUILD_DIR"
    OUTPUT_NAME="TablePro-${arch}.app"
    echo "Copying to release directory..."
    rm -rf "$BUILD_DIR/$OUTPUT_NAME"
    cp -R "$APP_PATH" "$BUILD_DIR/$OUTPUT_NAME"

    # Remove any stale nested .app bundles in the bundle root (breaks codesign)
    for nested in "$BUILD_DIR/$OUTPUT_NAME"/*.app; do
        [ -d "$nested" ] && rm -rf "$nested"
    done

    # Final verification
    BINARY_PATH="$BUILD_DIR/$OUTPUT_NAME/Contents/MacOS/TablePro"
    if [ ! -f "$BINARY_PATH" ] || [ ! -s "$BINARY_PATH" ] || [ ! -x "$BINARY_PATH" ]; then
        echo "❌ FATAL: Binary not found, empty, or not executable: $BINARY_PATH"
        exit 1
    fi

    SIZE=$(ls -lh "$BINARY_PATH" 2>/dev/null | awk '{print $5}')
    echo "✅ Built: $OUTPUT_NAME (${SIZE:-unknown})"
    lipo -info "$BINARY_PATH" || echo "⚠️  Could not verify binary architecture"

    # Copy dSYMs to release directory for artifact upload
    if [ -d "$dsym_dir" ] && [ "$(ls -A "$dsym_dir")" ]; then
        local dsym_archive="$BUILD_DIR/TablePro-${arch}-dSYMs.zip"
        echo "📋 Packaging dSYMs..."
        ditto -c -k --keepParent "$dsym_dir" "$dsym_archive"
        echo "✅ dSYMs packaged: $dsym_archive ($(ls -lh "$dsym_archive" | awk '{print $5}'))"
    fi
}

# ──────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────

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
ls -lh "$BUILD_DIR" 2>/dev/null || echo "⚠️  Could not list build directory"

# Notarization (opt-in via NOTARIZE=true)
if [ "$NOTARIZE" = "true" ]; then
    echo ""
    echo "📮 Notarizing..."

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
