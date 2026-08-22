#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:?Usage: package-artifacts.sh <arch> [staging_dir]}"
STAGING="${2:-}"

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "❌ ERROR: Invalid architecture: $ARCH (expected arm64 or x86_64)"
  exit 1
fi

# Read from the bundle being packaged rather than inferred from git. `git describe --tags` picks
# up whatever tag is nearest, which on a release commit that also carries a plugin tag is the
# wrong one, and its "dev" fallback shipped that name to a public release rather than failing.
# Taken from the artifact, the DMG name cannot disagree with the app inside it.
APP_BUNDLE="build/Release/TablePro-${ARCH}.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP_BUNDLE/Contents/Info.plist")

# --- Create DMG ---
echo "Creating DMG installer..."

# create-dmg is pre-installed in CI dependencies step
if ! command -v create-dmg &>/dev/null; then
  echo "📦 Installing create-dmg tool..."
  brew install create-dmg
fi

chmod +x scripts/create-dmg.sh

echo "📌 Using version: $VERSION"
NOTARIZE="${NOTARIZE:-false}" scripts/create-dmg.sh "$VERSION" "$ARCH" "$APP_BUNDLE"

# Verify DMG was created. A DMG under any other name is not the one the release will upload, so
# accepting it here only moved the failure to somewhere it was harder to read.
DMG_FILE="build/Release/TablePro-${VERSION}-${ARCH}.dmg"
if [ ! -f "$DMG_FILE" ]; then
  echo "❌ ERROR: expected DMG not found at: $DMG_FILE" >&2
  ls -la build/Release/*.dmg 2>/dev/null || true
  exit 1
fi
echo "✅ DMG installer created successfully: $DMG_FILE"

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
