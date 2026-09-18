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

# Derived from project.yml's copy phase, which is what decides what ends up in the bundle.
# This used to be a hardcoded list of three, so a release could ship missing eleven of the
# fourteen embedded plugins and still print "All bundled plugin bundles present".
REQUIRED_PLUGINS=()
while IFS= read -r plugin; do
  REQUIRED_PLUGINS+=("${plugin}.tableplugin")
done < <(python3 -c '
import re, sys

# Parsed without PyYAML on purpose: this runs on the release path and the module is not part of
# a stock runner image. The shape being read is fixed and small:
#
#       - target: MySQLDriver
#         copy:
#           destination: plugins
#
text = open("project.yml").read()
names = re.findall(
    r"-\s*target:\s*(\S+)[^\n]*\n(?:\s+\w+:[^\n]*\n)*?\s*copy:\s*\{\s*destination:\s*plugins\s*\}",
    text,
)
if not names:
    sys.exit("project.yml declares no plugins copied into the app bundle")
print("\n".join(names))
')

if [ "${#REQUIRED_PLUGINS[@]}" -eq 0 ]; then
  echo "❌ ERROR: could not read the bundled plugin list from project.yml"
  exit 1
fi
echo "project.yml embeds ${#REQUIRED_PLUGINS[@]} plugins"

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

# The release path always notarizes, so there is no legitimate "not yet" case: a warning here
# meant an unnotarized build passed verification and shipped. Checked by exit code rather than by
# grepping for a message, matching scripts/build-plugin.sh.
if ! xcrun stapler validate "$APP_BUNDLE"; then
  echo "❌ ERROR: No notarization ticket stapled to $APP_BUNDLE"
  exit 1
fi
echo "✅ Notarization ticket stapled"

# spctl is what a user's Mac runs. It accepts an unstapled but notarized bundle over the network,
# so it proves the app will launch but never that it will launch offline. The staple check above
# is what covers that, and both have to pass.
if ! spctl -a -vvv -t exec "$APP_BUNDLE" 2>&1 | grep -q "accepted"; then
  echo "❌ ERROR: Gatekeeper rejects $APP_BUNDLE"
  spctl -a -vvv -t exec "$APP_BUNDLE" 2>&1 || true
  exit 1
fi
echo "✅ Accepted by Gatekeeper"

# Display info
echo "✅ Build verified successfully"
echo "Binary size: $(ls -lh "$BINARY_PATH" | awk '{print $5}')"
echo "App bundle size: $(du -sh "$APP_BUNDLE" | awk '{print $1}')"
