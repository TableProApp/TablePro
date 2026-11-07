#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$ROOT/../.analysis/hydradb-native"
SOURCES="$WORK/Sources/Probe"
mkdir -p "$SOURCES"
mkdir -p "$WORK/Tests"
ln -sfn "$ROOT/Packages/TableProCore/Tests/TableProNeo4jCoreTests" "$WORK/Tests/TableProNeo4jCoreTests"

for source in "$ROOT/Plugins/Neo4jDriverPlugin"/*.swift; do
    ln -sf "$source" "$SOURCES/$(basename "$source")"
done
for source in "$ROOT/Plugins/HydraDBDriverPlugin"/*.swift; do
    ln -sf "$source" "$SOURCES/$(basename "$source")"
done
ln -sf "$ROOT/Plugins/Shared/PluginConnectTimeout.swift" "$SOURCES/PluginConnectTimeout.swift"
ln -sf "$ROOT/Plugins/SharedNIO/PluginNIOChannel.swift" "$SOURCES/PluginNIOChannel.swift"
ln -sf "$ROOT/scripts/probes/hydradb-compatibility/tablepro-probe.swift" "$SOURCES/main.swift"

cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "HydraDBProbe", platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$ROOT/Packages/TableProCore"),
        .package(url: "https://github.com/apple/swift-nio", "2.81.0" ..< "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", "2.29.0" ..< "3.0.0")
    ],
    targets: [.executableTarget(name: "Probe", dependencies: [
        .product(name: "TableProPluginKit", package: "TableProCore"),
        .product(name: "TableProNeo4jCore", package: "TableProCore"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl")
    ], swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("MemberImportVisibility")]),
    .testTarget(name: "TableProNeo4jCoreTests", dependencies: [
        .product(name: "TableProNeo4jCore", package: "TableProCore")
    ])]
)
MANIFEST

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! swift build --package-path "$WORK" --jobs 2 > "$WORK/build.log" 2>&1; then
    tail -60 "$WORK/build.log" >&2
    exit 3
fi
if [ "${HYDRADB_PROBE_BUILD_ONLY:-0}" != 1 ]; then
    "$WORK/.build/debug/Probe"
fi
