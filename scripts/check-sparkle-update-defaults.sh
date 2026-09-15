#!/usr/bin/env bash
set -euo pipefail

# Asks the Sparkle we actually link what TablePro/Info.plist resolves to on a machine that has never
# run the app, and fails when the answer is not "checks on, installs on".
#
# Sparkle resolves every update preference as user defaults first and Info.plist second
# (SUHost.boolNumberForKey:), and the three settings are chained: an undeclared
# SUEnableAutomaticChecks makes allowsAutomaticUpdates false, which makes
# setAutomaticallyDownloadsUpdates return without writing. So SUAutomaticallyUpdate read true in
# Info.plist and false everywhere it mattered, every update control in Settings read off on a fresh
# install, and Sparkle asked for permission on the second launch instead. Nothing caught it, because
# every developer machine already had the keys written into its own defaults.
#
# SparkleUpdatePreferencesTests covers the half that is ours: the keys are declared. This covers the
# half that is Sparkle's: that declaring them still produces the values we expect. A framework bump
# is what would change that answer, which is why this is a script and not a transcription.
#
# Usage: scripts/check-sparkle-update-defaults.sh [path/to/built/TablePro.app]
# With no argument it looks for the Debug build. Needs Xcode; macOS only.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

APP="${1:-}"
if [ -z "$APP" ]; then
  DERIVED=$(xcodebuild -project TablePro.xcodeproj -scheme TablePro -configuration Debug \
      -showBuildSettings -skipPackagePluginValidation 2>/dev/null \
      | awk '/ BUILT_PRODUCTS_DIR = /{print $3; exit}')
  APP="$DERIVED/TablePro.app"
fi

FRAMEWORK_DIR="$(dirname "$APP")"
if [ ! -d "$FRAMEWORK_DIR/Sparkle.framework" ] && [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  FRAMEWORK_DIR="$APP/Contents/Frameworks"
fi

if [ ! -d "$FRAMEWORK_DIR/Sparkle.framework" ]; then
  echo "::error::no Sparkle.framework beside $APP; build the app first" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The probe builds a throwaway host bundle from the repo's own Info.plist under an identifier no
# defaults domain has ever seen, which is the fresh-install condition the bug hid behind.
cat > "$WORK/probe.swift" <<'SWIFT'
import Foundation
import Sparkle

let sourcePlist = CommandLine.arguments[1]
guard let declared = NSDictionary(contentsOfFile: sourcePlist) as? [String: Any] else {
    FileHandle.standardError.write(Data("cannot read \(sourcePlist)\n".utf8))
    exit(2)
}

let contents = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("sparkle-default-probe-\(ProcessInfo.processInfo.processIdentifier).app/Contents", isDirectory: true)
try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

var plist: [String: Any] = [
    "CFBundleIdentifier": "com.tablepro.sparkledefaultprobe.\(ProcessInfo.processInfo.processIdentifier)",
    "CFBundleName": "Probe",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
]
for key in declared.keys where key.hasPrefix("SU") {
    plist[key] = declared[key]
}
(plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)

guard let host = Bundle(url: contents.deletingLastPathComponent()) else {
    FileHandle.standardError.write(Data("cannot open the probe bundle\n".utf8))
    exit(2)
}

let settings = SPUUpdaterSettings(hostBundle: host)
let sparkleVersion = Bundle(for: SPUUpdaterSettings.self)
    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"

print("Sparkle \(sparkleVersion), fresh defaults domain:")
print("  automaticallyChecksForUpdates  \(settings.automaticallyChecksForUpdates)")
print("  allowsAutomaticUpdates         \(settings.allowsAutomaticUpdates)")
print("  automaticallyDownloadsUpdates  \(settings.automaticallyDownloadsUpdates)")
print("  updateCheckInterval            \(Int(settings.updateCheckInterval))")
print("  impatientUpdateCheckInterval   \(Int(settings.impatientUpdateCheckInterval))")

var failures: [String] = []
if !settings.automaticallyChecksForUpdates {
    failures.append("automaticallyChecksForUpdates is false; declare SUEnableAutomaticChecks in Info.plist")
}
if !settings.allowsAutomaticUpdates {
    failures.append("allowsAutomaticUpdates is false, so the install toggle is inert rather than merely dimmed")
}
if !settings.automaticallyDownloadsUpdates {
    failures.append("automaticallyDownloadsUpdates is false despite SUAutomaticallyUpdate")
}
if settings.updateCheckInterval >= settings.impatientUpdateCheckInterval {
    failures.append("updateCheckInterval is not below impatientUpdateCheckInterval")
}

guard failures.isEmpty else {
    for failure in failures {
        FileHandle.standardError.write(Data("::error::\(failure)\n".utf8))
    }
    exit(1)
}
print("\n✅ A fresh install checks for updates and installs them.")
SWIFT

xcrun swiftc -O -o "$WORK/probe" "$WORK/probe.swift" \
  -F "$FRAMEWORK_DIR" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR"

"$WORK/probe" "$REPO_ROOT/TablePro/Info.plist"
