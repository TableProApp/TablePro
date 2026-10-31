#!/usr/bin/env bash
# Build the actual registry driver and probe an existing, disposable Neo4j server, for example
# `docker run -p 7687:7687 -e NEO4J_AUTH=neo4j/password neo4j:5`. No server is started.
# TP_NEO4J_{HOST,PORT,USER,PASSWORD} select the server. TP_NEO4J_SSL_MODE takes an SSLMode raw
# value ("Required", "Verify Identity") and TP_NEO4J_CA a PEM file to trust.
# The probe writes nodes under a random label and deletes them before it exits.
# TP_NEO4J_BUILD_DIR preserves build artifacts; otherwise they are removed on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${TP_NEO4J_BUILD_DIR:-}"
if [ -z "$WORK" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK/Sources/Probe"
SOURCES="$WORK/Sources/Probe"
rm -f "$SOURCES"/*.swift
for source in "$ROOT/Plugins/Neo4jDriverPlugin"/*.swift; do
    ln -s "$source" "$SOURCES/$(basename "$source")"
done
ln -s "$ROOT/Plugins/Shared/PluginConnectTimeout.swift" "$SOURCES/PluginConnectTimeout.swift"
ln -s "$ROOT/Plugins/SharedNIO/PluginNIOChannel.swift" "$SOURCES/PluginNIOChannel.swift"
ln -s "$ROOT/scripts/probes/neo4j-probe.swift" "$SOURCES/main.swift"
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Neo4jProbe", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$ROOT/Packages/TableProCore"),
        .package(url: "https://github.com/apple/swift-nio", "2.81.0" ..< "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", "2.29.0" ..< "3.0.0")
    ],
    targets: [
        .executableTarget(name: "Probe", dependencies: [
            .product(name: "TableProPluginKit", package: "TableProCore"),
            .product(name: "TableProNeo4jCore", package: "TableProCore"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")
        ], swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("MemberImportVisibility")])
    ])
MANIFEST
if ! (cd "$WORK" && swift build --jobs 2 > "$WORK/build.log" 2>&1); then
    tail -60 "$WORK/build.log" >&2
    exit 3
fi
"$WORK/.build/debug/Probe"
