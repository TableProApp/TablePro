#!/usr/bin/env bash
# Registry drivers have no test target, so this probe runs their own sources against local databases.
# Usage: lockf -k -t 540 /tmp/tablepro-heavy.lock apple/scripts/probes/check-nul-text-drivers.sh <libsql|beancount|duckdb>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="${1:-}"
C_MODULE=""
LINK=""
case "$ENGINE" in
    libsql)
        FOLDER=LibSQLDriverPlugin
        PRODUCTS="TableProSQLiteCore CSQLite"
        LINK="\"$ROOT/Libs/libsqlite3_vendored.a\""
        ;;
    beancount)
        FOLDER=BeancountDriverPlugin
        PRODUCTS="TableProNumberFormatting TableProProcess"
        ;;
    duckdb)
        FOLDER=DuckDBDriverPlugin
        PRODUCTS=TableProSQLVocabulary
        C_MODULE=CDuckDB
        LINK="\"-Xlinker\", \"-force_load\", \"-Xlinker\", \"$ROOT/Libs/libduckdb.a\", \"-lc++\""
        ;;
    *) echo "usage: $0 <libsql|beancount|duckdb>" >&2; exit 3 ;;
esac

WORK="$ROOT/../.analysis/fix-sqlite-nul-text/nul-probe-$ENGINE"
SOURCES="$WORK/Sources/Probe"
mkdir -p "$SOURCES"
for source in "$ROOT/Plugins/$FOLDER/"*.swift; do
    ln -sf "$source" "$SOURCES/$(basename "$source")"
done
for shared in PluginConnectTimeout PluginQueryTimeout PluginURLSessionTaskBox PluginRedirectRefusingDelegate; do
    ln -sf "$ROOT/Plugins/Shared/$shared.swift" "$SOURCES/$shared.swift"
done
ln -sf "$ROOT/scripts/probes/nul-text-drivers.swift" "$SOURCES/Probe.swift"

DEPENDENCIES='.product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProSQLGrammar", package: "TableProCore"),
                .product(name: "TableProSQLQuoting", package: "TableProCore"),'
for product in $PRODUCTS; do
    DEPENDENCIES="$DEPENDENCIES .product(name: \"$product\", package: \"TableProCore\"),"
done
SYSTEM_TARGET=""
SWIFT_FLAGS=""
if [ -n "$C_MODULE" ]; then
    ln -sfn "$ROOT/Plugins/$FOLDER/$C_MODULE" "$WORK/CModule"
    SYSTEM_TARGET=".systemLibrary(name: \"$C_MODULE\", path: \"CModule\"),"
    DEPENDENCIES="$DEPENDENCIES \"$C_MODULE\","
    SWIFT_FLAGS=", .unsafeFlags([\"-Xcc\", \"-I$ROOT/Plugins/$FOLDER/$C_MODULE/include\"])"
fi
DEFINE="$(printf '%s' "$ENGINE" | tr '[:lower:]' '[:upper:]')"
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NulTextProbe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        $SYSTEM_TARGET
        .executableTarget(
            name: "Probe",
            dependencies: [$DEPENDENCIES],
            swiftSettings: [.swiftLanguageMode(.v6), .define("$DEFINE"),
                            .enableUpcomingFeature("MemberImportVisibility")$SWIFT_FLAGS],
            linkerSettings: [.unsafeFlags([$LINK])]
        )
    ]
)
MANIFEST
swift run --package-path "$WORK" Probe "$WORK"
