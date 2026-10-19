#!/usr/bin/env bash
set -euo pipefail

# Where URLCache puts its database for a directory whose path has a space.
#
# RegistryClient keeps the plugin manifest cache under "Application Support". On macOS 15 and
# earlier URLCache(memoryCapacity:diskCapacity:directory:) opens it at the percent-encoded path,
# a sibling "Application%20Support" folder (FB9117600, #3676), so the client uses the diskPath:
# initializer. This opens a cache with each initializer and reports where Cache.db landed. Run it
# on each macOS the app supports; it fails when the initializer RegistryClient uses misplaces it.
#
# Usage: scripts/probes/check-urlcache-directory-path.sh

cd "$(dirname "$0")/../.."

SOURCE="TablePro/Core/Plugins/Registry/RegistryClient.swift"
grep -q 'diskPath: directory.path' "$SOURCE" || { echo "FAIL: $SOURCE no longer uses the diskPath: initializer" >&2; exit 1; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

cat > "$workdir/probe.swift" <<'SWIFT'
import Foundation

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for initializer in ["directory", "diskPath"] {
    let root = base.appendingPathComponent(initializer, isDirectory: true)
    let directory = root.appendingPathComponent("Application Support/URLCache", isDirectory: true)
    let cache = initializer == "directory"
        ? URLCache(memoryCapacity: 2_000_000, diskCapacity: 20_000_000, directory: directory)
        : URLCache(memoryCapacity: 2_000_000, diskCapacity: 20_000_000, diskPath: directory.path)
    _ = cache.currentDiskUsage
    let real = FileManager.default.fileExists(atPath: directory.appendingPathComponent("Cache.db").path)
    let encoded = FileManager.default.fileExists(atPath: root.appendingPathComponent("Application%20Support").path)
    print("\(initializer) real=\(real) encoded=\(encoded)")
}
SWIFT

swiftc -O "$workdir/probe.swift" -o "$workdir/probe"
output=$("$workdir/probe" "$workdir")

echo "macOS $(sw_vers -productVersion)"
echo "$output"
if grep -qx 'diskPath real=true encoded=false' <<<"$output"; then
    echo "ok: diskPath: opens the cache at the file-system path"
else
    echo "FAIL: diskPath: does not open the cache at the file-system path" >&2
    exit 1
fi
