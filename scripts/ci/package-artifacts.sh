#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:?Usage: package-artifacts.sh <arch> [staging_dir]}"
STAGING="${2:-}"

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "❌ ERROR: Invalid architecture: $ARCH (expected arm64 or x86_64)"
  exit 1
fi

VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//') || { echo "❌ ERROR: Cannot determine version from git tags"; exit 1; }

# --- Create DMG ---
echo "Creating DMG installer..."

echo "📦 Installing create-dmg tool..."
brew list create-dmg &>/dev/null || brew install create-dmg

chmod +x scripts/create-dmg.sh

echo "📌 Using version: $VERSION"
NOTARIZE="${NOTARIZE:-false}" scripts/create-dmg.sh "$VERSION" "$ARCH" "build/Release/TablePro-${ARCH}.app"

# Verify DMG was created
DMG_FILE="build/Release/TablePro-${VERSION}-${ARCH}.dmg"
if [ -f "$DMG_FILE" ]; then
  echo "✅ DMG installer created successfully: $DMG_FILE"
else
  echo "⚠️  Expected DMG not found at: $DMG_FILE"
  echo "📂 Checking for any DMG files in build/Release/:"
  ls -la build/Release/*.dmg 2>/dev/null || echo "   No DMG files found"

  if ls build/Release/*-${ARCH}.dmg 1>/dev/null 2>&1; then
    echo "✅ Found ${ARCH} DMG file(s):"
    ls -lh build/Release/*-${ARCH}.dmg
  else
    echo "❌ ERROR: No ${ARCH} DMG file was created"
    exit 1
  fi
fi

ls -lh build/Release/*.dmg

# --- Create ZIP ---
echo "Creating ZIP archive..."

cd build/Release

# Use ditto to preserve framework symlinks (zip -r resolves them,
# which breaks code signature validation and Sparkle updates)
if ! ditto -c -k --sequesterRsrc --keepParent "TablePro-${ARCH}.app" "TablePro-${ARCH}.zip"; then
  echo "❌ ERROR: Failed to create ZIP archive"
  exit 1
fi

echo "✅ ZIP archive created"
ls -lh "TablePro-${ARCH}.zip"

cd - > /dev/null

# --- Stage artifacts (optional, for local/self-hosted use) ---
if [ -n "$STAGING" ]; then
  mkdir -p "$STAGING"
  cp build/Release/*.dmg "$STAGING/" 2>/dev/null || true
  cp "build/Release/TablePro-${ARCH}.zip" "$STAGING/" 2>/dev/null || true
  echo "Artifacts staged to $STAGING"
  ls -lh "$STAGING"
fi
