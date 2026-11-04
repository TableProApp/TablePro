#!/usr/bin/env bash
# SQL Server must read text keys and nested statement text without dropping backslash line endings.
# Usage: MSSQL_SA_PASSWORD=... check-mssql-string-literals.sh [host] [port] [user]
# Uses only connection-local temporary tables on an existing server. Starts no service.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-string-literals.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD for the test server}"
mkdir -p "$WORK/Sources/Check"
ln -s "$ROOT/Plugins/MSSQLDriverPlugin/CFreeTDS" "$WORK/CFreeTDS"
for source in "$ROOT"/Plugins/MSSQLDriverPlugin/*.swift "$ROOT"/Plugins/Shared/*.swift; do
    ln -s "$source" "$WORK/Sources/Check/$(basename "$source")"
done
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MSSQLStringCheck", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .systemLibrary(name: "CFreeTDS", path: "CFreeTDS"),
        .executableTarget(name: "Check", dependencies: [
            "CFreeTDS",
            .product(name: "TableProPluginKit", package: "TableProCore"),
            .product(name: "TableProCoreTypes", package: "TableProCore"),
            .product(name: "TableProMSSQLCore", package: "TableProCore"),
            .product(name: "TableProKerberos", package: "TableProCore"),
            .product(name: "TableProLogRedaction", package: "TableProCore"),
            .product(name: "TableProSQLQuoting", package: "TableProCore"),
            .product(name: "TableProSQLVocabulary", package: "TableProCore"),
        ], path: "Sources/Check", swiftSettings: [.swiftLanguageMode(.v6)],
        linkerSettings: [.unsafeFlags([
            "-L$ROOT/Libs", "-L$ROOT/Libs/dylibs", "-lsybdb", "-lssl.3", "-lcrypto.3", "-liconv",
            "-framework", "GSS", "-lcom_err", "-Xlinker", "-rpath", "-Xlinker", "$ROOT/Libs/dylibs"
        ])])
    ]
)
MANIFEST
cat > "$WORK/Sources/Check/Check.swift" <<'SWIFT'
import Foundation
import TableProMSSQLCore
import TableProPluginKit
import TableProSQLQuoting

@main
struct Check {
    static func hex(_ text: String) -> String {
        text.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }.map { String(format: "%02X", $0) }.joined()
    }

    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let driver = MSSQLPluginDriver(config: DriverConnectionConfig(
            host: env["TP_CHECK_HOST"] ?? "127.0.0.1",
            port: Int(env["TP_CHECK_PORT"] ?? "1433") ?? 1433,
            username: env["TP_CHECK_USER"] ?? "sa", password: env["MSSQL_SA_PASSWORD"] ?? "", database: "tempdb"
        ))
        try await driver.connect()
        defer { driver.disconnect() }
        var checks = 0
        func expect(_ sql: String, _ expected: String) async throws {
            let actual = try await driver.execute(query: sql).rows.first?.first?.asText
            guard actual == expected else {
                throw NSError(domain: "MSSQLStringCheck", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Expected \(expected), got \(String(describing: actual)); SQL \(sql.debugDescription)"
                ])
            }
            checks += 1
        }
        for newline in ["\n", "\r\n", "\r", "\r\r\n", "\r\\\n", "\n\r"] {
            // A binary seed avoids using the formatter under test to construct expected values.
            let key = "admin\\" + newline
            let expected = hex(key)
            let seed = "CONVERT(nvarchar(max), 0x" + expected + ")"
            let escaped = "N'" + driver.escapeStringLiteral(key) + "'"
            try await expect("SELECT CONVERT(varchar(max), CONVERT(varbinary(max), \(escaped)), 2)", expected)
            let bound = MSSQLParameterBatch.spExecuteSql(query: "SELECT CONVERT(varchar(max), CONVERT(varbinary(max), ?), 2)", parameters: [.text(key)])
            try await expect(bound.executeSqlText, expected)
            if let batch = MSSQLParameterBatch.boundBatch(query: "SELECT CONVERT(varchar(max), CONVERT(varbinary(max), ?), 2)", parameters: [.text(key)]) {
                try await expect(batch.text, expected)
            }
            _ = try await driver.execute(query: "CREATE TABLE #keys (k nvarchar(100) PRIMARY KEY, v int); INSERT #keys VALUES (N'admin', 0), (\(seed), 0)")
            _ = try await driver.executeParameterized(query: "UPDATE #keys SET v = 1 WHERE k = ?", parameters: [.text(key)])
            try await expect("SELECT CONVERT(varchar(10), v) FROM #keys WHERE k = N'admin'", "0")
            try await expect("SELECT CONVERT(varchar(10), v) FROM #keys WHERE k = \(seed)", "1")
            _ = try await driver.executeParameterized(query: "DELETE FROM #keys WHERE k = ?", parameters: [.text(key)])
            try await expect("SELECT CONVERT(varchar(10), COUNT(*)) FROM #keys WHERE k = N'admin'", "1")
            _ = try await driver.execute(query: "DROP TABLE #keys")
            let name = "[#name\\" + newline + "]"
            _ = try await driver.execute(query: "CREATE TABLE \(name) (v int); INSERT \(name) VALUES (7)")
            let nested = MSSQLParameterBatch.spExecuteSql(query: "SELECT CONVERT(varchar(10), v) FROM \(name) WHERE v = ?", parameters: [.text("7")])
            try await expect(nested.executeSqlText, "7")
            _ = try await driver.execute(query: "DROP TABLE \(name)")
            for slashes in 1...3 {
                let value = "日本'\u{301};--" + String(repeating: "\\", count: slashes) + newline + "tail"
                let literal = MSSQLStringLiteral.quoted(value)
                try await expect("SELECT CONVERT(varchar(max), CONVERT(varbinary(max), \(literal)), 2)", hex(value))
                let pattern = MSSQLStringLiteral.likePattern(value, prefixWildcard: false, suffixWildcard: false)
                try await expect("SELECT CASE WHEN CONVERT(nvarchar(max), 0x\(hex(value))) LIKE \(pattern) THEN 'yes' ELSE 'no' END", "yes")
            }
            print("PASS: \(newline.debugDescription) values, row targeting, nested names and LIKE")
        }
        // Under a SQL collation a varchar key holds both spellings, which compare equal against nvarchar text.
        for keyed in [true, false] {
            _ = try await driver.execute(query: "CREATE TABLE #narrow (k varchar(20) COLLATE SQL_Latin1_General_CP1_CI_AS"
                + (keyed ? " PRIMARY KEY" : "") + ", v int); INSERT #narrow VALUES (N'Wessels', 0), (N'Weßels', 0)")
            var context = PluginRowWriteContext()
            context.columnTypeNames = ["k": "varchar", "v": "int"]
            let row: [PluginCellValue] = [.text("Weßels"), .text("0")]
            let changes = [
                PluginRowChange(rowIndex: 0, type: .update, cellChanges: [
                    (columnIndex: 1, columnName: "v", oldValue: .text("0"), newValue: .text("1"))
                ], originalRow: row),
                PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text("Weßels"), .text("1")]),
            ]
            for change in changes {
                let writes = try driver.generateRowWrites(
                    table: "#narrow", schema: nil, columns: ["k", "v"], primaryKeyColumns: keyed ? ["k"] : [],
                    changes: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: [],
                    context: context
                ) ?? []
                for write in writes {
                    _ = try await driver.executeParameterized(query: write.statement, parameters: write.parameters)
                }
                try await expect("SELECT CONVERT(varchar(10), v) FROM #narrow WHERE k = 'Wessels'", "0")
            }
            try await expect("SELECT CONVERT(varchar(10), COUNT(*)) FROM #narrow", "1")
            _ = try await driver.execute(query: "DROP TABLE #narrow")
        }
        print("PASS: varchar keys edit only the row with the exact stored text")
        print("PASS: \(checks) SQL Server checks through the shipped driver")
    }
}
SWIFT
swift build --package-path "$WORK" --scratch-path "${TP_CHECK_SCRATCH:-$WORK/.build}" > "$WORK/build.log" 2>&1 || {
    tail -60 "$WORK/build.log" >&2
    exit 3
}
TP_CHECK_HOST="${1:-127.0.0.1}" TP_CHECK_PORT="${2:-1433}" TP_CHECK_USER="${3:-sa}" \
    "${TP_CHECK_SCRATCH:-$WORK/.build}/debug/Check"
