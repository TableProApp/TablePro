#!/usr/bin/env bash
#
# Check that the count SQL Server reports for a grid save's UPDATE and DELETE is the rows the statement matched.
#
# MSSQLStatementGenerator tells the host each update and delete matches one row (PluginRowWrite.expectedRowCount), and
# the host then fails a save whose count is higher, or lower for an UPDATE. That is only right while these hold, and
# no unit test can see them because each depends on what the server sends and how db-lib reads it:
#
#   - An UPDATE that writes the value a row already holds still counts the row.
#   - An UPDATE or DELETE that matches nothing counts 0.
#   - A session left at SET NOCOUNT ON still reports the count, through the SET NOCOUNT OFF the statement carries.
#   - Rows an AFTER trigger writes are not added, with or without SET NOCOUNT ON inside the trigger, and an
#     INSTEAD OF trigger leaves the statement's own count.
#
# So this builds a harness from the real Plugins/MSSQLDriverPlugin sources, the TableProCore package and the shipped
# Libs/libsybdb.a, writes each statement with MSSQLStatementGenerator, runs it through MSSQLPluginDriver, and fails
# when a count differs. Verified against SQL Server 2022 CU14 with FreeTDS 1.4.22.
#
# Usage:
#   MSSQL_SA_PASSWORD=secret scripts/probes/check-mssql-keyed-row-counts.sh [host] [port] [user] [database]
#
# The database defaults to tablepro_row_count_check and is created when missing. Exits 1 when a check fails, 3 when it
# cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1433}"
USER_NAME="${3:-sa}"
DATABASE="${4:-tablepro_row_count_check}"
PASSWORD="${MSSQL_SA_PASSWORD:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$ROOT/Libs/libsybdb.a" ] || {
    echo "not found: Libs/libsybdb.a (run scripts/download-libs.sh)" >&2
    exit 3
}
[ -n "$PASSWORD" ] || {
    echo "no password: set MSSQL_SA_PASSWORD for the server at $HOST:$PORT" >&2
    exit 3
}
nc -z "$HOST" "$PORT" > /dev/null 2>&1 || {
    echo "no SQL Server listening at $HOST:$PORT" >&2
    exit 3
}

mkdir -p "$WORK/Sources/Check"
ln -s "$ROOT/Plugins/MSSQLDriverPlugin/CFreeTDS" "$WORK/CFreeTDS"
# The plugin target's sources: its folder plus the shared files the DriverPlugin template in project.yml adds.
for source in "$ROOT"/Plugins/MSSQLDriverPlugin/*.swift "$ROOT"/Plugins/Shared/PluginConnectTimeout.swift \
    "$ROOT"/Plugins/Shared/PluginQueryTimeout.swift "$ROOT"/Plugins/Shared/PluginURLSessionTaskBox.swift \
    "$ROOT"/Plugins/Shared/PluginRedirectRefusingDelegate.swift; do
    ln -s "$source" "$WORK/Sources/Check/$(basename "$source")"
done

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSSQLRowCountCheck",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .systemLibrary(name: "CFreeTDS", path: "CFreeTDS"),
        .executableTarget(
            name: "Check",
            dependencies: [
                "CFreeTDS",
                .product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProCoreTypes", package: "TableProCore"),
                .product(name: "TableProMSSQLCore", package: "TableProCore"),
                .product(name: "TableProLogRedaction", package: "TableProCore"),
                .product(name: "TableProKerberos", package: "TableProCore"),
                .product(name: "TableProSQLQuoting", package: "TableProCore"),
                .product(name: "TableProSQLVocabulary", package: "TableProCore"),
            ],
            path: "Sources/Check",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags([
                "-L$ROOT/Libs", "-L$ROOT/Libs/dylibs", "-lsybdb", "-lssl.3", "-lcrypto.3", "-liconv",
                "-framework", "GSS", "-lcom_err", "-Xlinker", "-rpath", "-Xlinker", "$ROOT/Libs/dylibs",
            ])]
        ),
    ]
)
MANIFEST

cat > "$WORK/Sources/Check/Check.swift" << 'SWIFT'
import Foundation
import TableProPluginKit

@main
enum Check {
    nonisolated(unsafe) static var failures = 0

    static let database = ProcessInfo.processInfo.environment["TP_CHECK_DATABASE"] ?? "tablepro_row_count_check"
    static let columns = ["id", "a"]

    static func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS: \(label)")
        } else {
            failures += 1
            print("FAIL: \(label) \(detail())")
        }
    }

    static func connect(_ database: String) async throws -> MSSQLPluginDriver {
        let environment = ProcessInfo.processInfo.environment
        let config = DriverConnectionConfig(
            host: environment["TP_CHECK_HOST"] ?? "127.0.0.1",
            port: Int(environment["TP_CHECK_PORT"] ?? "") ?? 1433,
            username: environment["TP_CHECK_USER"] ?? "sa",
            password: environment["TP_CHECK_PASSWORD"] ?? "",
            database: database
        )
        let driver = MSSQLPluginDriver(config: config)
        try await driver.connect()
        return driver
    }

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let driver: MSSQLPluginDriver
        do {
            let admin = try await connect("master")
            _ = try await admin.execute(query: "IF DB_ID(N'\(database)') IS NULL CREATE DATABASE [\(database)]")
            admin.disconnect()
            driver = try await connect(database)
        } catch {
            print("cannot connect: \(error)")
            exit(3)
        }
        do {
            try await run(driver)
        } catch {
            failures += 1
            print("FAIL: unexpected error \(error)")
        }
        print(failures == 0 ? "OK: every check passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func update(id: String, to value: String) -> PluginRowChange {
        PluginRowChange(
            rowIndex: 0, type: .update,
            cellChanges: [(columnIndex: 1, columnName: "a", oldValue: .text(value), newValue: .text(value))],
            originalRow: [.text(id), .text(value)]
        )
    }

    static func delete(id: String) -> PluginRowChange {
        PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: [.text(id), .text("1")])
    }

    static func write(_ change: PluginRowChange, keyed: Bool) throws -> PluginRowWrite {
        let generator = MSSQLStatementGenerator(
            qualifiedTable: "[dbo].[rc_t]", columns: columns, primaryKeyColumns: keyed ? ["id"] : []
        )
        let writes = try generator.rowWrites(
            for: [change], insertedRowData: [:],
            deletedRowIndices: change.type == .delete ? [0] : [], insertedRowIndices: []
        )
        guard let write = writes.first else { throw CocoaError(.featureUnsupported) }
        return write
    }

    static func count(_ write: PluginRowWrite, on driver: MSSQLPluginDriver) async throws -> Int {
        try await driver.executeParameterized(query: write.statement, parameters: write.parameters).rowsAffected
    }

    static func reset(_ driver: MSSQLPluginDriver, trigger: String?) async throws {
        _ = try await driver.execute(query: "IF OBJECT_ID(N'dbo.rc_t') IS NOT NULL DROP TABLE dbo.rc_t")
        _ = try await driver.execute(query: "IF OBJECT_ID(N'dbo.rc_audit') IS NOT NULL DROP TABLE dbo.rc_audit")
        _ = try await driver.execute(query: "CREATE TABLE dbo.rc_t (id INT PRIMARY KEY, a INT)")
        _ = try await driver.execute(query: "CREATE TABLE dbo.rc_audit (n INT)")
        _ = try await driver.execute(query: "INSERT INTO dbo.rc_t VALUES (1, 1), (2, 1), (3, 1)")
        if let trigger { _ = try await driver.execute(query: trigger) }
    }

    static func checkCounts(_ driver: MSSQLPluginDriver, _ label: String) async throws {
        let same = try write(update(id: "1", to: "1"), keyed: true)
        expect(same.expectedRowCount == 1, "\(label): a keyed update says it matches one row")
        let sameCount = try await count(same, on: driver)
        expect(sameCount == 1, "\(label): a keyed update writing the value the row holds counts 1", "got \(sameCount)")
        let missCount = try await count(try write(update(id: "99", to: "1"), keyed: true), on: driver)
        expect(missCount == 0, "\(label): a keyed update that matches nothing counts 0", "got \(missCount)")
        let deleteCount = try await count(try write(delete(id: "2"), keyed: true), on: driver)
        expect(deleteCount == 1, "\(label): a keyed delete counts 1", "got \(deleteCount)")
        let goneCount = try await count(try write(delete(id: "2"), keyed: true), on: driver)
        expect(goneCount == 0, "\(label): a keyed delete of a row already gone counts 0", "got \(goneCount)")
        let keylessCount = try await count(try write(update(id: "3", to: "1"), keyed: false), on: driver)
        expect(keylessCount == 1, "\(label): a keyless update writing the value the row holds counts 1", "got \(keylessCount)")
    }

    static func run(_ driver: MSSQLPluginDriver) async throws {
        try await reset(driver, trigger: nil)
        try await checkCounts(driver, "no trigger")

        try await reset(driver, trigger: nil)
        _ = try await driver.execute(query: "SET NOCOUNT ON")
        try await checkCounts(driver, "session at SET NOCOUNT ON")
        let options = try await driver.execute(query: "SELECT @@OPTIONS & 512")
        expect(options.rows.first?.first?.asText == "512", "the session is still at SET NOCOUNT ON afterwards")
        _ = try await driver.execute(query: "SET NOCOUNT OFF")

        // A keyless row of NULLs set to DEFAULT binds nothing, so the statement runs in its own sp_executesql.
        _ = try await driver.execute(query: "IF OBJECT_ID(N'dbo.rc_k') IS NOT NULL DROP TABLE dbo.rc_k")
        _ = try await driver.execute(query: "CREATE TABLE dbo.rc_k (id INT NULL, a INT NULL)")
        _ = try await driver.execute(query: "INSERT INTO dbo.rc_k VALUES (NULL, NULL)")
        var toDefault = PluginRowChange(
            rowIndex: 0, type: .update,
            cellChanges: [(columnIndex: 1, columnName: "a", oldValue: .null, newValue: .null)],
            originalRow: [.null, .null]
        )
        toDefault.defaultColumns = [1]
        let unbound = try MSSQLStatementGenerator(qualifiedTable: "[dbo].[rc_k]", columns: columns, primaryKeyColumns: [])
            .rowWrites(for: [toDefault], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: [])
        guard let unboundWrite = unbound.first else { throw CocoaError(.featureUnsupported) }
        expect(unboundWrite.parameters.isEmpty && unboundWrite.statement.hasPrefix("EXEC sp_executesql"),
               "a statement binding nothing runs in its own sp_executesql", unboundWrite.statement)
        _ = try await driver.execute(query: "SET NOCOUNT ON")
        let unboundCount = try await count(unboundWrite, on: driver)
        expect(unboundCount == 1, "a statement binding nothing counts 1 under SET NOCOUNT ON", "got \(unboundCount)")
        _ = try await driver.execute(query: "SET NOCOUNT OFF")
        _ = try await driver.execute(query: "DROP TABLE dbo.rc_k")

        let audit = "INSERT INTO dbo.rc_audit SELECT id FROM inserted UNION ALL SELECT id FROM deleted"
        try await reset(driver, trigger: "CREATE TRIGGER dbo.rc_trg ON dbo.rc_t AFTER UPDATE, DELETE AS \(audit)")
        try await checkCounts(driver, "AFTER trigger")
        let audited = try await driver.execute(query: "SELECT COUNT(*) FROM dbo.rc_audit")
        expect(audited.rows.first?.first?.asText != "0", "AFTER trigger: the trigger wrote its rows")

        try await reset(
            driver,
            trigger: "CREATE TRIGGER dbo.rc_trg ON dbo.rc_t AFTER UPDATE, DELETE AS BEGIN SET NOCOUNT ON; \(audit) END"
        )
        try await checkCounts(driver, "AFTER trigger at SET NOCOUNT ON")

        try await reset(driver, trigger: """
            CREATE TRIGGER dbo.rc_trg ON dbo.rc_t INSTEAD OF UPDATE AS \
            UPDATE t SET a = i.a FROM dbo.rc_t t JOIN inserted i ON i.id = t.id
            """)
        let insteadCount = try await count(try write(update(id: "1", to: "1"), keyed: true), on: driver)
        expect(insteadCount == 1, "INSTEAD OF trigger: a keyed update counts 1", "got \(insteadCount)")

        _ = try await driver.execute(query: "DROP TABLE dbo.rc_t")
        _ = try await driver.execute(query: "DROP TABLE dbo.rc_audit")
        driver.disconnect()
    }
}
SWIFT

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
swift build --package-path "$WORK" --scratch-path "$WORK/.build" > "$WORK/build.log" 2>&1 || {
    echo "the check failed to build" >&2
    grep -E "error:" "$WORK/build.log" >&2
    exit 3
}

TP_CHECK_HOST="$HOST" TP_CHECK_PORT="$PORT" TP_CHECK_USER="$USER_NAME" TP_CHECK_PASSWORD="$PASSWORD" \
    TP_CHECK_DATABASE="$DATABASE" "$WORK/.build/debug/Check"
