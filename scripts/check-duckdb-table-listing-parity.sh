#!/usr/bin/env bash
#
# Check that DuckDB's all-schema table listing lists exactly what the per-schema listing does.
#
# Open Quickly and the sidebar filter find tables in schemas nobody has opened through one call,
# DuckDBPluginDriver.fetchTablesInAllSchemas(). Without it the host asks fetchTables(schema:) for
# every schema fetchSchemas() returns. The two have to agree row for row: a table the one-schema
# listing shows and the search cannot find is the bug the listing exists to fix, and one the search
# finds that the sidebar hides is a result that opens nothing.
#
# This compiles the real plugin driver against the shipped static libduckdb, opens a throwaway
# file holding every shape the listing treats specially (views, an empty schema, mixed-case and
# dotted schema and table names, a same-named schema in a second attached catalog, a temporary
# table), and compares the two listings in each catalog, reading every row's schema the way the
# host does. Then it times both listings over a catalog of 300 small schemas.
#
# Usage:
#   scripts/check-duckdb-table-listing-parity.sh
#
# Needs Libs/libduckdb.a (scripts/download-libs.sh) and a Debug build of TableProPluginKit in
# DerivedData (run verify.sh build first). Exits non-zero on a disagreement, 3 when a prerequisite
# is missing.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/Plugins/DuckDBDriverPlugin"
LIB="$ROOT/Libs/libduckdb.a"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$LIB" ] || {
    echo "$LIB is missing; run scripts/download-libs.sh" >&2
    exit 3
}

if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p)"
    case "$DEVELOPER_DIR" in
        *CommandLineTools*) DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
    esac
fi
export DEVELOPER_DIR

# The framework this checkout built, so the harness compiles against the PluginKit its sources
# expect; the newest one anywhere is the fallback.
FRAMEWORK_DIR=""
for info in "$HOME"/Library/Developer/Xcode/DerivedData/TablePro-*/info.plist; do
    [ -f "$info" ] || continue
    workspace="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$info" 2> /dev/null)"
    products="$(dirname "$info")/Build/Products/Debug"
    if [ "$workspace" = "$ROOT/TablePro.xcodeproj" ] && [ -d "$products/TableProPluginKit.framework" ]; then
        FRAMEWORK_DIR="$products"
    fi
done
if [ -z "$FRAMEWORK_DIR" ]; then
    FRAMEWORK_DIR="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path '*/Build/Products/Debug/TableProPluginKit.framework' -print 2> /dev/null \
        | while read -r path; do echo "$(stat -f %m "$path") $(dirname "$path")"; done \
        | sort -rn | head -1 | cut -d' ' -f2-)"
fi
[ -n "$FRAMEWORK_DIR" ] || {
    echo "no Debug TableProPluginKit.framework in DerivedData; build the app first" >&2
    exit 3
}

cat > "$WORK/main.swift" << 'SWIFT'
import Foundation
import TableProPluginKit

@main
enum ListingParity {
    static func main() async {
        let arguments = CommandLine.arguments
        let driver = DuckDBPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: arguments[1]
        ))
        do {
            try await driver.connect()
            for statement in arguments[3].components(separatedBy: ";\n") where !statement.isEmpty {
                _ = try await driver.execute(query: statement)
            }
            var failures = 0
            for catalog in [arguments[2], "other"] {
                try await driver.switchDatabase(to: catalog)
                failures += try await compare(driver, catalog: catalog)
            }
            try await time(driver, schemaCount: 300)
            driver.disconnect()
            print(failures == 0 ? "PASS" : "FAIL")
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("error: \(error)")
            exit(3)
        }
    }

    /// Both listings over one catalog of many small schemas, each timed at its best of three.
    static func time(_ driver: DuckDBPluginDriver, schemaCount: Int) async throws {
        _ = try await driver.execute(query: "ATTACH ':memory:' AS timing")
        try await driver.switchDatabase(to: "timing")
        for index in 0..<schemaCount {
            _ = try await driver.execute(query: "CREATE SCHEMA s\(index)")
            _ = try await driver.execute(query: "CREATE TABLE s\(index).a (id INTEGER)")
            _ = try await driver.execute(query: "CREATE TABLE s\(index).b (id INTEGER)")
        }
        let clock = ContinuousClock()
        var perSchema = Duration.seconds(3_600)
        var allSchemas = Duration.seconds(3_600)
        for _ in 0..<3 {
            perSchema = min(perSchema, try await clock.measure {
                for schema in try await driver.fetchSchemas() {
                    _ = try await driver.fetchTables(schema: schema)
                }
            })
            allSchemas = min(allSchemas, try await clock.measure {
                _ = try await driver.fetchTablesInAllSchemas()
            })
        }
        func milliseconds(_ duration: Duration) -> Int64 {
            duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
        }
        print("\(schemaCount + 1) schemas: per-schema \(milliseconds(perSchema)) ms, all-schema \(milliseconds(allSchemas)) ms")
    }

    /// Each per-schema row reads its schema as the host does: the row's own, else the schema asked.
    static func compare(_ driver: DuckDBPluginDriver, catalog: String) async throws -> Int {
        var perSchema: [String] = []
        for schema in try await driver.fetchSchemas() {
            for table in try await driver.fetchTables(schema: schema) {
                perSchema.append("\(table.schema ?? schema)|\(table.name)|\(table.type)")
            }
        }
        guard let listed = try await driver.fetchTablesInAllSchemas() else {
            print("FAIL \(catalog): fetchTablesInAllSchemas() returned nil")
            return 1
        }
        let allSchemas = listed.map { "\($0.schema ?? "<no schema>")|\($0.name)|\($0.type)" }
        let missing = Set(perSchema).subtracting(allSchemas).sorted()
        let extra = Set(allSchemas).subtracting(perSchema).sorted()
        var failures = 0
        if perSchema.count != allSchemas.count || !missing.isEmpty || !extra.isEmpty {
            print("FAIL \(catalog): per-schema \(perSchema.count) rows, all-schema \(allSchemas.count) rows")
            missing.forEach { print("  only per-schema: \($0)") }
            extra.forEach { print("  only all-schema: \($0)") }
            failures += 1
        } else {
            print("\(catalog): \(allSchemas.count) objects, listings agree")
        }
        let expected = catalog == "other"
            ? ["sales|elsewhere|TABLE"]
            : ["Mixed Case|Orders|TABLE", "dot.ted|a.b|TABLE", "main|v_people|VIEW", "sales|orders|TABLE"]
        for row in expected where !allSchemas.contains(row) {
            print("FAIL \(catalog): the all-schema listing is missing \(row)")
            failures += 1
        }
        let forbidden = catalog == "other" ? ["sales|orders|TABLE"] : ["sales|elsewhere|TABLE", "main|scratch|TABLE"]
        for row in forbidden where allSchemas.contains(row) {
            print("FAIL \(catalog): the all-schema listing shows \(row), which belongs to another catalog")
            failures += 1
        }
        return failures
    }
}
SWIFT

SOURCES=()
while IFS= read -r source; do
    SOURCES+=("$source")
done < <(find "$PLUGIN" -maxdepth 1 -name '*.swift' | sort)

xcrun swiftc -swift-version 6 -parse-as-library -module-name ListingParity -Onone \
    -F "$FRAMEWORK_DIR" -framework TableProPluginKit -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
    -I "$PLUGIN/CDuckDB" -Xcc -I"$PLUGIN/CDuckDB/include" \
    -Xlinker -force_load -Xlinker "$LIB" -lc++ \
    "${SOURCES[@]}" "$WORK/main.swift" -o "$WORK/listing-parity" > "$WORK/compile.log" 2>&1 || {
    echo "harness failed to compile:" >&2
    grep -E 'error:' "$WORK/compile.log" | sort -u | head -20 >&2
    exit 3
}

FIXTURE="$WORK/fixture.duckdb"
OTHER="$WORK/other.duckdb"
SETUP="CREATE SCHEMA sales;
CREATE SCHEMA \"Mixed Case\";
CREATE SCHEMA \"dot.ted\";
CREATE SCHEMA empty_schema;
CREATE TABLE main.people (id INTEGER);
CREATE VIEW main.v_people AS SELECT id FROM main.people;
CREATE TABLE sales.orders (id INTEGER);
CREATE VIEW sales.v_orders AS SELECT id FROM sales.orders;
CREATE TABLE \"Mixed Case\".\"Orders\" (id INTEGER);
CREATE TABLE \"dot.ted\".\"a.b\" (id INTEGER);
CREATE TEMP TABLE scratch (id INTEGER);
ATTACH '$OTHER' AS other;
CREATE SCHEMA other.sales;
CREATE TABLE other.sales.elsewhere (id INTEGER);
CREATE TABLE other.main.lonely (id INTEGER)"

echo "Checking the all-schema table listing against $(basename "$LIB")"
"$WORK/listing-parity" "$FIXTURE" fixture "$SETUP"
