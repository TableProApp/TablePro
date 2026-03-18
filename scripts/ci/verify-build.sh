#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:?Usage: verify-build.sh <arch>}"

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  echo "❌ ERROR: Invalid architecture: $ARCH (expected arm64 or x86_64)"
  exit 1
fi

if [[ "$ARCH" == "arm64" ]]; then
  OPPOSITE_ARCH="x86_64"
else
  OPPOSITE_ARCH="arm64"
fi

echo "Verifying build output..."

BINARY_PATH="build/Release/TablePro-${ARCH}.app/Contents/MacOS/TablePro"

# Check binary exists
if [ ! -f "$BINARY_PATH" ]; then
  echo "❌ ERROR: Built binary not found at: $BINARY_PATH"
  echo "Build may have failed silently"
  exit 1
fi

# Check it's not empty
if [ ! -s "$BINARY_PATH" ]; then
  echo "❌ ERROR: Binary file is empty"
  exit 1
fi

# Check architecture
ARCH_INFO=$(lipo -info "$BINARY_PATH")
echo "Architecture: $ARCH_INFO"

if ! echo "$ARCH_INFO" | grep -q "$ARCH"; then
  echo "❌ ERROR: Binary does not contain $ARCH architecture"
  echo "Expected: $ARCH only"
  echo "Got: $ARCH_INFO"
  exit 1
fi

if echo "$ARCH_INFO" | grep -q "$OPPOSITE_ARCH"; then
  echo "❌ ERROR: Binary contains $OPPOSITE_ARCH but should be $ARCH only"
  exit 1
fi

# Check it's executable
if [ ! -x "$BINARY_PATH" ]; then
  echo "❌ ERROR: Binary is not executable"
  exit 1
fi

# Verify bundled dylibs
FRAMEWORKS_DIR="build/Release/TablePro-${ARCH}.app/Contents/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ]; then
  echo "Bundled dynamic libraries:"
  ls -lh "$FRAMEWORKS_DIR"/*.dylib 2>/dev/null || echo "  (none)"

  # Verify no Homebrew paths remain in the binary
  if otool -L "$BINARY_PATH" | grep -q '/opt/homebrew/\|/usr/local/opt/'; then
    echo "❌ ERROR: Binary still references Homebrew paths:"
    otool -L "$BINARY_PATH" | grep '/opt/homebrew/\|/usr/local/opt/'
    exit 1
  fi
  echo "✅ No Homebrew path references in binary"
else
  echo "⚠️  WARNING: No Frameworks directory found — dylibs may not be bundled"
fi

# Verify plugins
APP_BUNDLE="build/Release/TablePro-${ARCH}.app"
PLUGINS_DIR="$APP_BUNDLE/Contents/PlugIns"

echo "Verifying plugins..."

if [ ! -d "$PLUGINS_DIR" ]; then
  echo "❌ ERROR: PlugIns directory not found at: $PLUGINS_DIR"
  exit 1
fi
echo "✅ PlugIns directory exists"

REQUIRED_PLUGINS=(
  "MySQLDriver.tableplugin"
  "PostgreSQLDriver.tableplugin"
  "SQLiteDriver.tableplugin"
)

MISSING_PLUGINS=0
for PLUGIN in "${REQUIRED_PLUGINS[@]}"; do
  if [ ! -d "$PLUGINS_DIR/$PLUGIN" ]; then
    echo "❌ ERROR: Missing plugin bundle: $PLUGIN"
    MISSING_PLUGINS=1
  else
    echo "  ✅ $PLUGIN"
  fi
done

if [ "$MISSING_PLUGINS" -eq 1 ]; then
  echo "❌ ERROR: One or more plugin bundles are missing"
  exit 1
fi
echo "✅ All bundled plugin bundles present"

# Verify each plugin has a valid binary
MISSING_BINARIES=0
for PLUGIN in "${REQUIRED_PLUGINS[@]}"; do
  PLUGIN_NAME="${PLUGIN%.tableplugin}"
  PLUGIN_BINARY="$PLUGINS_DIR/$PLUGIN/Contents/MacOS/$PLUGIN_NAME"
  if [ ! -f "$PLUGIN_BINARY" ]; then
    echo "❌ ERROR: Missing binary for plugin: $PLUGIN (expected $PLUGIN_BINARY)"
    MISSING_BINARIES=1
  fi
done

if [ "$MISSING_BINARIES" -eq 1 ]; then
  echo "❌ ERROR: One or more plugin binaries are missing"
  exit 1
fi
echo "✅ All plugin binaries present"

# Verify TableProPluginKit framework
PLUGINKIT_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/TableProPluginKit.framework"
if [ ! -d "$PLUGINKIT_FRAMEWORK" ]; then
  echo "❌ ERROR: TableProPluginKit.framework not found at: $PLUGINKIT_FRAMEWORK"
  exit 1
fi
echo "✅ TableProPluginKit.framework present"

# Verify code signature
echo "Verifying code signature..."
if codesign --verify --deep --strict "$APP_BUNDLE" 2>&1; then
  SIGN_INFO=$(codesign -dvv "$APP_BUNDLE" 2>&1 | grep "Authority=" | head -1)
  echo "✅ Code signature valid: $SIGN_INFO"
else
  echo "❌ ERROR: Code signature verification failed"
  codesign -dvv "$APP_BUNDLE" 2>&1 || true
  exit 1
fi

# Verify notarization staple (if notarized)
if xcrun stapler validate "$APP_BUNDLE" 2>&1 | grep -q "The validate action worked"; then
  echo "✅ Notarization ticket stapled"
else
  echo "⚠️  No notarization ticket stapled (may not have been notarized yet)"
fi

# Display info
echo "✅ Build verified successfully"
echo "Binary size: $(ls -lh "$BINARY_PATH" | awk '{print $5}')"
echo "App bundle size: $(du -sh "$APP_BUNDLE" | awk '{print $1}')"
