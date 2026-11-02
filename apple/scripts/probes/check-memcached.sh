#!/usr/bin/env bash
#
# Run the Memcached driver against a live server: connect, the auth file login, key listing through
# lru_crawler metadump and through the stats cachedump fallback, browse pages with values and TTLs,
# key filters, grid writes (set, touch, delete), console commands and stats. The probe writes keys
# under tablepro_probe: and deletes them after.
#
# Usage:
#   scripts/probes/check-memcached.sh [host] [port]
#
# MEMCACHED_USER and MEMCACHED_PASSWORD log in to a server started with -Y <auth file>. Start one with:
#   docker run -d --name tablepro-memcached-probe -p 11211:11211 memcached:1.6
#
# Exits 3 when no server answers.

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-11211}"
HERE="$(cd "$(dirname "$0")" && pwd)"
APPLE="$(cd "$HERE/../.." && pwd)"

if ! nc -z -w 3 "$HOST" "$PORT" 2>/dev/null; then
    echo "No Memcached server answers at $HOST:$PORT." >&2
    exit 3
fi

WORK="${TMPDIR:-/tmp}/tablepro-memcached-probe"
rm -rf "$WORK/Sources"
mkdir -p "$WORK/Sources/probe"
cp "$HERE/memcached-probe.swift" "$WORK/Sources/probe/main.swift"
for file in "$APPLE"/Plugins/MemcachedDriverPlugin/*.swift; do
    ln -s "$file" "$WORK/Sources/probe/$(basename "$file")"
done
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "probe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$APPLE/Packages/TableProCore"),
        .package(url: "https://github.com/apple/swift-nio", "2.81.0" ..< "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", "2.29.0" ..< "3.0.0"),
    ],
    targets: [.executableTarget(name: "probe", dependencies: [
        .product(name: "TableProPluginKit", package: "TableProCore"),
        .product(name: "TableProMemcachedCore", package: "TableProCore"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
    ], swiftSettings: [.swiftLanguageMode(.v5)])]
)
MANIFEST

MEMCACHED_HOST="$HOST" MEMCACHED_PORT="$PORT" swift run --package-path "$WORK" probe
