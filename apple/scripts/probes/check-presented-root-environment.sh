#!/usr/bin/env bash
#
# Whether SwiftUI on this Mac still builds a presented root once without the presenter's environment.
# On macOS 27.0.1 an iPad app on a Mac (and a Catalyst app) evaluates a sheet's or cover's root while
# it sets the presentation up, and when that root has a sheet or alert outside a NavigationStack the
# evaluation sees an empty environment: a non-optional @Environment(T.self) read traps with
# "No Observable object of type T found". The iOS app passes its scene objects to presented content
# (TableProMobile/Views/SceneObjects.swift) for that reason. Run this on a new macOS to see whether
# that is still needed.
#
# Builds presented-root-environment-probe.swift as a Catalyst app with the iPad idiom and runs it
# twice: once relying on inheritance, once with .environment on the cover's content.
#
# Exit 0: inheritance misses the first evaluation and injection fixes it (the app's assumption).
# Exit 2: inheritance already covers the first evaluation (the workaround can go).
# Exit 1: injection does not help, or the probe did not run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

APP="$WORK/PresentedRootProbe.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PresentedRootProbe</string>
    <key>CFBundleIdentifier</key><string>com.TablePro.probes.presented-root-environment</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><true/></dict>
    <key>UIDeviceFamily</key><array><integer>2</integer></array>
</dict>
</plist>
PLIST

SDK="$(xcrun --sdk macosx --show-sdk-path)"
if ! xcrun swiftc -sdk "$SDK" -parse-as-library -swift-version 5 -target arm64-apple-ios26.0-macabi -O \
    -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -L "$SDK/System/iOSSupport/usr/lib" -L "$SDK/System/iOSSupport/usr/lib/swift" \
    "$ROOT/scripts/probes/presented-root-environment-probe.swift" \
    -o "$APP/Contents/MacOS/PresentedRootProbe" > "$WORK/build.log" 2>&1; then
    tail -40 "$WORK/build.log" >&2
    exit 1
fi
codesign --force --sign - "$APP" > /dev/null 2>&1

run() {
    PROBE_INJECT="$1" perl -e 'alarm 30; exec @ARGV' "$APP/Contents/MacOS/PresentedRootProbe" 2> /dev/null
}

sw_vers -productVersion | sed 's/^/macOS /'
echo "inherited:"
run 0
inherited=$?
echo "injected on the content:"
run 1
injected=$?

if [ "$injected" -ne 0 ]; then
    echo "FAIL: injection on the content did not reach the first evaluation" >&2
    exit 1
fi
if [ "$inherited" -eq 0 ]; then
    echo "The first evaluation inherits the presenter's environment on this macOS."
    exit 2
fi
echo "The first evaluation misses the presenter's environment; content needs its objects passed in."
exit 0
