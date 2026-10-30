#!/usr/bin/env bash
# Build the actual registry driver and probe an existing, disposable KingbaseES server.
# TP_KINGBASE_{HOST,PORT,USER,PASSWORD,DATABASE} select the server. No server is started.
# TP_KINGBASE_BUILD_DIR preserves build artifacts; otherwise they are removed on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${TP_KINGBASE_BUILD_DIR:-}"
if [ -z "$WORK" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK/Sources/Probe"
SOURCES="$WORK/Sources/Probe"
rm -f "$SOURCES"/*.swift "$WORK/CModule"
for folder in PostgreSQLDriverPlugin KingbaseESDriverPlugin; do
    for source in "$ROOT/Plugins/$folder"/*.swift; do
        ln -s "$source" "$SOURCES/${folder}_$(basename "$source")"
    done
done
for shared in PluginConnectTimeout PluginQueryTimeout; do
    ln -s "$ROOT/Plugins/Shared/$shared.swift" "$SOURCES/$shared.swift"
done
ln -s "$ROOT/scripts/probes/kingbasees-probe.swift" "$SOURCES/Probe.swift"
ln -s "$ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ" "$WORK/CModule"
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "KingbaseESProbe", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .systemLibrary(name: "CLibPQ", path: "CModule"),
        .executableTarget(name: "Probe", dependencies: [
            "CLibPQ",
            .product(name: "TableProPluginKit", package: "TableProCore"),
            .product(name: "TableProCoreTypes", package: "TableProCore"),
            .product(name: "TableProKerberos", package: "TableProCore"),
            .product(name: "TableProPostgreSQLCore", package: "TableProCore"),
            .product(name: "TableProSQLVocabulary", package: "TableProCore"),
            .product(name: "TableProSQLGrammar", package: "TableProCore"),
            .product(name: "TableProLogRedaction", package: "TableProCore")
        ], swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("MemberImportVisibility"),
            .unsafeFlags(["-Xcc", "-I$ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ/include"])],
        linkerSettings: [.unsafeFlags([
            "-L$ROOT/Libs", "-L$ROOT/Libs/dylibs", "-Xlinker", "-rpath", "-Xlinker", "$ROOT/Libs/dylibs",
            "$ROOT/Libs/libpq.a", "$ROOT/Libs/libpgcommon.a", "$ROOT/Libs/libpgport.a",
            "-lssl.3", "-lcrypto.3", "-lz", "-framework", "GSS", "-lcom_err"
        ])])
    ])
MANIFEST
if ! (cd "$WORK" && swift build --jobs 2 > "$WORK/build.log" 2>&1); then
    tail -60 "$WORK/build.log" >&2
    exit 3
fi
TZ=UTC "$WORK/.build/debug/Probe"
