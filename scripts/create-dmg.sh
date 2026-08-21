#!/usr/bin/env bash
# Create a DMG installer with drag-and-drop installation window
# Uses create-dmg tool for reliable CI builds

set -e

# Configuration
APP_NAME="TablePro"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    # Configs/Version.xcconfig is the single declaration of the app version. The literal that
    # used to sit here as a default was 0.1.13, 66 releases behind, so a run without an explicit
    # version produced a correctly built DMG under a badly wrong name.
    VERSION=$(sed -n 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*//p' \
        "$REPO_ROOT/Configs/Version.xcconfig" | tr -d ' ')
fi
if [ -z "$VERSION" ]; then
    # sed exits 0 when it matches nothing, so set -e does not cover this.
    echo "❌ ERROR: MARKETING_VERSION missing from Configs/Version.xcconfig" >&2
    exit 1
fi
ARCH="${2:-universal}"
SOURCE_APP="${3:-build/Release/${APP_NAME}.app}"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
VOLUME_NAME="${APP_NAME} ${VERSION}"
FINAL_DMG="build/Release/$DMG_NAME"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Dat Ngo Quoc (D7HJ5TFYCU)}"
NOTARIZE="${NOTARIZE:-false}"

echo "📦 Creating DMG installer for $APP_NAME..."
echo "   Version: $VERSION"
echo "   Architecture: $ARCH"
echo "   Source: $SOURCE_APP"

# Verify source app exists
if [ ! -d "$SOURCE_APP" ]; then
    echo "❌ ERROR: Source app not found: $SOURCE_APP"
    exit 1
fi

# Ensure output directory exists
mkdir -p "build/Release"

# Create a staging copy of the app with the correct name (TablePro.app)
# This ensures the DMG shows "TablePro.app" regardless of the source name
STAGING_APP="build/Release/${APP_NAME}.app"
if [ "$SOURCE_APP" != "$STAGING_APP" ]; then
    echo "📋 Preparing $APP_NAME.app for DMG..."
    rm -rf "$STAGING_APP"
    cp -R "$SOURCE_APP" "$STAGING_APP"
fi

# Get the app icon from the built app
APP_ICON=""
if [ -f "$STAGING_APP/Contents/Resources/AppIcon.icns" ]; then
    APP_ICON="$STAGING_APP/Contents/Resources/AppIcon.icns"
    echo "   Using app icon: $APP_ICON"
fi

# Create a temporary directory for DMG staging
DMG_STAGING="build/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy app to staging directory
cp -R "$STAGING_APP" "$DMG_STAGING/$APP_NAME.app"

# Create an Applications alias (not symlink) with proper icon
# Using osascript to create a proper Finder alias
echo "📁 Creating Applications alias..."
osascript <<EOF
tell application "Finder"
    set applicationsFolder to POSIX file "/Applications" as alias
    set stagingFolder to POSIX file "$(pwd)/$DMG_STAGING" as alias
    try
        make new alias file at stagingFolder to applicationsFolder with properties {name:"Applications"}
    on error
        -- If alias creation fails, we'll fall back to symlink
    end try
end tell
EOF

# Check if alias was created, otherwise fall back to symlink
if [ ! -e "$DMG_STAGING/Applications" ]; then
    echo "   ⚠️  Alias creation failed, using symlink instead"
    ln -s /Applications "$DMG_STAGING/Applications"
fi

# Copy Applications folder icon to the alias
APPS_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
if [ -f "$APPS_ICON" ] && [ -e "$DMG_STAGING/Applications" ]; then
    # Use Rez/SetFile to set custom icon on the alias (if available)
    if command -v SetFile &> /dev/null; then
        # Create an Icon\r file with the icon data
        cp "$APPS_ICON" "$DMG_STAGING/Applications/Icon"$'\r' 2>/dev/null || true
        # Set custom icon flag
        SetFile -a C "$DMG_STAGING/Applications" 2>/dev/null || true
    fi
fi

# Check if create-dmg tool is available (brew install create-dmg)
if command -v create-dmg &> /dev/null; then
    echo "🔨 Using create-dmg tool..."

    # Remove existing DMG if present
    rm -f "$FINAL_DMG"

    # Build create-dmg command with options
    CREATE_DMG_ARGS=(
        --volname "$VOLUME_NAME"
        --window-pos 200 120
        --window-size 600 400
        --icon-size 80
        --icon "$APP_NAME.app" 150 190
        --icon "Applications" 450 190
        --hide-extension "$APP_NAME.app"
        --no-internet-enable
    )

    # Add volume icon if available
    if [ -n "$APP_ICON" ] && [ -f "$APP_ICON" ]; then
        CREATE_DMG_ARGS+=(--volicon "$APP_ICON")
    fi

    # Add background if exists
    if [ -f ".dmg-assets/dmg-background.png" ]; then
        CREATE_DMG_ARGS+=(--background ".dmg-assets/dmg-background.png")
        echo "   Using custom background"
    fi

    # Create DMG from staging directory (which has both the app and Applications alias)
    if ! create-dmg "${CREATE_DMG_ARGS[@]}" "$FINAL_DMG" "$DMG_STAGING"; then
        echo "⚠️  create-dmg exited with non-zero (may be expected in CI due to AppleScript)"
        # Check if DMG was still created
        if [ -f "$FINAL_DMG" ]; then
            echo "   DMG was created despite exit code"
        else
            echo "❌ ERROR: DMG was not created"
            rm -rf "$DMG_STAGING"
            exit 1
        fi
    fi

else
    echo "⚠️  create-dmg tool not found, using basic hdiutil method..."
    echo "   Install with: brew install create-dmg"

    # Calculate size needed for DMG
    SIZE_MB=$(du -sm "$DMG_STAGING" | awk '{print $1}')
    SIZE_MB=$((SIZE_MB + 50))

    TEMP_DMG="build/Release/temp.dmg"

    echo "🔨 Creating temporary DMG ($SIZE_MB MB)..."

    # Create temporary DMG
    hdiutil create -srcfolder "$DMG_STAGING" \
        -volname "$VOLUME_NAME" \
        -fs HFS+ \
        -fsargs "-c c=64,a=16,e=16" \
        -format UDRW \
        -size ${SIZE_MB}m \
        "$TEMP_DMG"

    # Mount the temporary DMG for customization
    MOUNT_DIR="/Volumes/$VOLUME_NAME"
    hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen

    # Wait for mount
    sleep 2

    # Set volume icon if available
    if [ -n "$APP_ICON" ] && [ -f "$APP_ICON" ]; then
        cp "$APP_ICON" "$MOUNT_DIR/.VolumeIcon.icns"
        SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
    fi

    # Try AppleScript to set icon positions (may fail in CI, that's OK)
    osascript <<EOF 2>/dev/null || echo "  ⚠️  AppleScript layout skipped (headless environment)"
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 700, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 80
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to true

        -- Position icons
        delay 1
        set position of item "$APP_NAME.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}

        -- Force update
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

    # Sync and unmount
    sync
    sleep 1
    hdiutil detach "$MOUNT_DIR" -force

    # Convert to compressed read-only DMG
    hdiutil convert "$TEMP_DMG" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$FINAL_DMG"

    # Clean up temp DMG
    rm -f "$TEMP_DMG"
fi

# Clean up staging directories
rm -rf "$DMG_STAGING"
if [ "$SOURCE_APP" != "$STAGING_APP" ] && [ -d "$STAGING_APP" ]; then
    rm -rf "$STAGING_APP"
fi

# Verify final DMG
if [ ! -f "$FINAL_DMG" ]; then
    echo "❌ ERROR: Failed to create DMG"
    exit 1
fi

# Sign the DMG
echo "🔏 Signing DMG with: $SIGN_IDENTITY"
codesign -fs "$SIGN_IDENTITY" --timestamp "$FINAL_DMG"
if ! codesign --verify "$FINAL_DMG" 2>&1; then
    echo "❌ ERROR: DMG signature verification failed"
    exit 1
fi
echo "✅ DMG signed"

# Notarize the DMG (opt-in via NOTARIZE=true)
if [ "$NOTARIZE" = "true" ]; then
    echo "📮 Notarizing DMG..."
    if xcrun notarytool submit "$FINAL_DMG" --keychain-profile "TablePro" --wait; then
        xcrun stapler staple "$FINAL_DMG"
        # Stapling can report success and still leave no usable ticket, which is why
        # build-plugin.sh validates after stapling. The DMG had no such check.
        xcrun stapler validate "$FINAL_DMG"
        echo "✅ DMG notarized and stapled"
    else
        echo "❌ DMG notarization failed"
        exit 1
    fi
fi

# Get final size
FINAL_SIZE=$(du -h "$FINAL_DMG" | awk '{print $1}')

echo ""
echo "✅ DMG created successfully!"
echo "   📍 Location: $FINAL_DMG"
echo "   📊 Size: $FINAL_SIZE"
echo ""
echo "🧪 Test the DMG:"
echo "   open \"$FINAL_DMG\""
