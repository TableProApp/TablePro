#!/usr/bin/env bash
#
# Check SQL Server's Estimated Plan and Actual Plan against a real server, through the plugin's own explainPlan and
# the app's SQLServerShowplanParser.
#
# The driver turns SHOWPLAN_XML or STATISTICS XML on, runs the statement and turns the setting off again in one queue
# turn, and picks the plan out of what came back. Which column name the server gives the plan, whether it suggests an
# index, and whether the OFF still runs after a Stop interrupted the statement are the server's answers, so this asks a
# real one.
#
# Usage:
#   scripts/probes/check-mssql-explain-plans.sh [host] [port] [user] [database]
#
# The password comes from MSSQL_SA_PASSWORD. The user needs to create a database, a login and tables: the database
# defaults to tablepro_explain_check and is created when missing, and the login tp_xp_noplan is dropped again. Set
# TP_CHECK_SCRATCH to a directory to reuse the build between runs. Exits 1 when a check fails, 3 when it cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1433}"
USER_NAME="${3:-sa}"
DATABASE="${4:-tablepro_explain_check}"
PASSWORD="${MSSQL_SA_PASSWORD:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRATCH="${TP_CHECK_SCRATCH:-$WORK/.build}"

[ -n "$PASSWORD" ] || {
    echo "no password: set MSSQL_SA_PASSWORD for the server at $HOST:$PORT" >&2
    exit 3
}
[ -f "$ROOT/Libs/libsybdb.a" ] || {
    echo "not found: Libs/libsybdb.a (run scripts/download-libs.sh)" >&2
    exit 3
}

mkdir -p "$WORK/Sources/Check"
ln -s "$ROOT/Plugins/MSSQLDriverPlugin/CFreeTDS" "$WORK/CFreeTDS"
for source in "$ROOT"/Plugins/MSSQLDriverPlugin/*.swift "$ROOT"/Plugins/Shared/*.swift \
    "$ROOT/TablePro/Models/Query/QueryPlan.swift" \
    "$ROOT/TablePro/Core/Services/Query/QueryPlanTreeBuilder.swift" \
    "$ROOT/TablePro/Core/Services/Query/SQLServerShowplanParser.swift" \
    "$ROOT/TablePro/Core/Services/Query/ExplainPlanTextFlattener.swift"; do
    [ -f "$source" ] || {
        echo "not found: $source" >&2
        exit 3
    }
    ln -s "$source" "$WORK/Sources/Check/$(basename "$source")"
done

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSSQLExplainCheck",
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
import TableProMSSQLCore
import TableProPluginKit

// The app declares this beside every other parser; only the two files this check needs are compiled in.
protocol QueryPlanParser {
    func parse(rawText: String) -> QueryPlan?
}

@main
enum Check {
    nonisolated(unsafe) static var failures = 0
    static let environment = ProcessInfo.processInfo.environment
    static let database = environment["TP_CHECK_DATABASE"] ?? "tablepro_explain_check"
    static let plainLogin = "tp_xp_noplan"
    static let plainPassword = "TpXp#" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)

    static func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS: \(label)")
        } else {
            failures += 1
            print("FAIL: \(label) \(detail())")
        }
    }

    static func connect(_ database: String, user: String? = nil, password: String? = nil) async throws -> MSSQLPluginDriver {
        let config = DriverConnectionConfig(
            host: environment["TP_CHECK_HOST"] ?? "127.0.0.1",
            port: Int(environment["TP_CHECK_PORT"] ?? "") ?? 1_433,
            username: user ?? environment["TP_CHECK_USER"] ?? "sa",
            password: password ?? environment["TP_CHECK_PASSWORD"] ?? "",
            database: database
        )
        let deadline = Date().addingTimeInterval(user == nil ? 180 : 10)
        while true {
            let driver = MSSQLPluginDriver(config: config)
            do {
                try await driver.connect()
                return driver
            } catch where Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    static func scalar(_ driver: MSSQLPluginDriver, _ sql: String) async -> String? {
        try? await driver.execute(query: sql).rows.first?.first?.asText
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    static func explain(_ driver: MSSQLPluginDriver, _ statement: String, _ showplan: MSSQLShowplan) async throws -> QueryPlan? {
        let result = try await driver.explainPlan(statement: statement, variantId: showplan.variantId)
        return SQLServerShowplanParser().parse(rawText: ExplainPlanTextFlattener.flatten(rows: result.rows))
    }

    static func nodes(_ node: QueryPlanNode) -> [QueryPlanNode] {
        [node] + node.children.flatMap(nodes)
    }

    static func relations(_ plan: QueryPlan?) -> Set<String> {
        guard let plan else { return [] }
        return Set(nodes(plan.rootNode).compactMap(\.relation))
    }

    static let joinedTables: Set<String> = ["tp_xp_customers", "tp_xp_orders", "tp_xp_items"]

    static func join(region: String) -> String {
        """
        SELECT c.name, o.id, i.sku, i.qty
        FROM dbo.tp_xp_customers c
        JOIN dbo.tp_xp_orders o ON o.customer_id = c.id
        JOIN dbo.tp_xp_items i ON i.order_id = o.id
        WHERE c.region = N'\(region)';
        """
    }

    // A query on one table with no index to choose gets a trivial plan, which never carries a missing index; the join
    // makes the optimizer cost its choices.
    static let unindexedFilter = """
        SELECT o.id, o.placed, c.name FROM dbo.tp_xp_orders o JOIN dbo.tp_xp_customers c ON c.id = o.customer_id
        WHERE o.note = N'held 17'
        """

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            try await run()
        } catch {
            failures += 1
            print("FAIL: unexpected error \(message(error))")
        }
        print(failures == 0 ? "OK: every check passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func run() async throws {
        let admin = try await connect("master")
        print("server: \(await scalar(admin, "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(40)) + N' ' + CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(40))") ?? "unknown")")
        _ = try await admin.execute(query: "IF DB_ID(N'\(database)') IS NULL CREATE DATABASE [\(database)]")
        admin.disconnect()

        let driver = try await connect(database)
        _ = try await driver.executeBatch(query: """
            DROP TABLE IF EXISTS dbo.tp_xp_items, dbo.tp_xp_orders, dbo.tp_xp_customers, dbo.tp_xp_log;
            CREATE TABLE dbo.tp_xp_customers (id INT PRIMARY KEY, name NVARCHAR(40), region NVARCHAR(10));
            CREATE TABLE dbo.tp_xp_orders (id INT PRIMARY KEY, customer_id INT, placed DATETIME2, note NVARCHAR(40));
            CREATE TABLE dbo.tp_xp_items (id INT PRIMARY KEY, order_id INT, sku NVARCHAR(20), qty INT);
            CREATE TABLE dbo.tp_xp_log (x INT);
            WITH n AS (SELECT TOP (60000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS v FROM sys.all_columns a CROSS JOIN sys.all_columns b)
            INSERT INTO dbo.tp_xp_items SELECT v, v % 20000 + 1, N'SKU-' + CAST(v % 97 AS NVARCHAR(10)), v % 7 + 1 FROM n;
            WITH n AS (SELECT TOP (20000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS v FROM sys.all_columns a CROSS JOIN sys.all_columns b)
            INSERT INTO dbo.tp_xp_orders SELECT v, v % 2000 + 1, DATEADD(day, -v, SYSDATETIME()), N'held ' + CAST(v % 5000 AS NVARCHAR(10)) FROM n;
            WITH n AS (SELECT TOP (2000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS v FROM sys.all_columns)
            INSERT INTO dbo.tp_xp_customers SELECT v, N'customer ' + CAST(v AS NVARCHAR(10)),
                CASE v % 4 WHEN 0 THEN N'north' WHEN 1 THEN N'south' WHEN 2 THEN N'east' ELSE N'west' END FROM n;
            """, rowCap: nil, parameters: nil)

        try await planColumnNames(driver)
        try await estimatedAndActual(driver)
        try await missingIndex(driver)
        await stopDuringActualPlan(driver)
        try await withoutShowplanPermission(driver)

        _ = try? await driver.executeBatch(query: """
            DROP TABLE IF EXISTS dbo.tp_xp_items, dbo.tp_xp_orders, dbo.tp_xp_customers, dbo.tp_xp_log;
            """, rowCap: nil, parameters: nil)
        driver.disconnect()
    }

    static func planColumnNames(_ driver: MSSQLPluginDriver) async throws {
        guard let connection = driver.freeTDSConn else { throw MSSQLCoreError.notConnected }
        for showplan in MSSQLShowplan.allCases {
            let readout = try await connection.executeShowplan(join(region: "north"), showplan: showplan)
            let planColumns = readout.resultSets
                .filter { $0.rows.first?.first?.stringValue?.hasPrefix("<ShowPlanXML") == true }
                .map { $0.columns.map(\.name) }
            print("info \(showplan.variantId) plan result sets: \(planColumns), result sets in all: \(readout.resultSets.count)")
            expect(planColumns == [[MSSQLShowplan.planColumnName]],
                   "the \(showplan.variantId) plan comes back in one column named \"\(MSSQLShowplan.planColumnName)\"",
                   "\(planColumns)")
        }
    }

    static func estimatedAndActual(_ driver: MSSQLPluginDriver) async throws {
        let north = await scalar(driver, "SELECT COUNT(*) FROM (\(join(region: "north").dropLast())) AS j").flatMap { Int($0) }
        let logBefore = await scalar(driver, "SELECT COUNT(*) FROM dbo.tp_xp_log")

        let estimated = try await explain(driver, join(region: "north"), .estimated)
        expect(estimated != nil, "the estimated plan of a three-table join parses into a tree")
        expect(relations(estimated) == joinedTables, "the estimated plan reads all three tables", "\(relations(estimated))")
        let estimatedNodes = estimated.map { nodes($0.rootNode) } ?? []
        expect(estimatedNodes.count >= 5, "the estimated tree has the join and scan steps", "\(estimatedNodes.map(\.operation))")
        expect(estimatedNodes.allSatisfy { $0.actualLoops == nil }, "an estimated plan reports no run-time figures")
        expect(estimated?.rootNode.estimatedTotalCost != nil, "the estimated plan carries subtree costs")

        _ = try? await explain(driver, "INSERT INTO dbo.tp_xp_log VALUES (1)", .estimated)
        expect(await scalar(driver, "SELECT COUNT(*) FROM dbo.tp_xp_log") == logBefore, "an estimated plan of an INSERT inserts nothing")

        let actual = try await explain(driver, join(region: "north"), .actual)
        expect(actual != nil, "the actual plan of a three-table join parses into a tree")
        expect(relations(actual) == joinedTables, "the actual plan reads all three tables", "\(relations(actual))")
        let actualNodes = actual.map { nodes($0.rootNode) } ?? []
        expect(actualNodes.filter { $0.relation != nil }.allSatisfy { ($0.actualLoops ?? 0) >= 1 },
               "every table step reports its executions")
        let shownRows = actual?.rootNode.reportedTotalActualRows
        expect(shownRows != nil && shownRows == north, "the root's actual rows are the statement's own row count",
               "\(shownRows.map(String.init) ?? "nil") vs \(north.map(String.init) ?? "nil")")
        expect(actual?.executionTime != nil, "the actual plan reports the elapsed time")

        _ = try? await explain(driver, "INSERT INTO dbo.tp_xp_log VALUES (1)", .actual)
        let logAfter = await scalar(driver, "SELECT COUNT(*) FROM dbo.tp_xp_log")
        expect(logAfter == (Int(logBefore ?? "") ?? -2).advanced(by: 1).description, "an actual plan of an INSERT inserts the row")
        expect(await scalar(driver, "SELECT 42 AS answer") == "42", "the session runs statements normally after both plans")
    }

    static func missingIndex(_ driver: MSSQLPluginDriver) async throws {
        for showplan in MSSQLShowplan.allCases {
            let plan = try await explain(driver, unindexedFilter, showplan)
            let suggestions = plan.map { nodes($0.rootNode).flatMap(\.missingIndexes) } ?? []
            print("info \(showplan.variantId) missing index: \(suggestions.map(\.createStatement))")
            expect(suggestions.contains { $0.createStatement.contains("[tp_xp_orders]") && $0.createStatement.contains("[note]") },
                   "the \(showplan.variantId) plan of a filter on an unindexed column suggests an index on it")
        }
    }

    final class Settled<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?

        func record(_ result: Result<Value, Error>) { lock.withLock { self.result = result } }
        var value: Result<Value, Error>? { lock.withLock { result } }
    }

    static func settle<Value: Sendable>(_ task: Task<Value, Error>, within seconds: Double) async -> Result<Value, Error>? {
        let settled = Settled<Value>()
        Task.detached { settled.record(await task.result) }
        let deadline = Date().addingTimeInterval(seconds)
        while settled.value == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return settled.value
    }

    static func stopDuringActualPlan(_ driver: MSSQLPluginDriver) async {
        let slow = """
            SELECT COUNT_BIG(*) FROM sys.all_columns a CROSS JOIN sys.all_columns b CROSS JOIN sys.all_columns c
            WHERE a.column_id + b.column_id + c.column_id > 0
            """
        for (label, stop) in [
            ("a Stop", { (task: Task<QueryPlan?, Error>) in Thread.detachNewThread { try? driver.cancelQuery() } }),
            ("a cancelled task", { (task: Task<QueryPlan?, Error>) in task.cancel() }),
        ] {
            let started = Date()
            let task = Task { try await explain(driver, slow, .actual) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            stop(task)
            let outcome = await settle(task, within: 30)
            switch outcome {
            case .failure?:
                expect(true, "\(label) ends an Actual Plan mid-run (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
            case .success?:
                expect(false, "\(label) ends an Actual Plan mid-run", "the statement finished first")
            case nil:
                expect(false, "\(label) ends an Actual Plan mid-run", "still running after 30 s")
                continue
            }
            guard let connection = driver.freeTDSConn else {
                expect(false, "the connection stays open after \(label)")
                continue
            }
            do {
                let readout = try await connection.executeBatch("SELECT 42 AS answer", rowCap: nil)
                let shape = readout.resultSets.map { "\($0.columns.map(\.name)) \($0.rows.map { $0.map { $0.stringValue ?? "NULL" } })" }
                expect(shape == ["[\"answer\"] [[\"42\"]]"], "after \(label) the session executes normally, with no plan beside the result",
                       "\(shape)")
            } catch {
                expect(false, "after \(label) the session executes normally", message(error))
            }
        }
    }

    static func withoutShowplanPermission(_ driver: MSSQLPluginDriver) async throws {
        _ = try await driver.executeBatch(query: """
            IF USER_ID(N'\(plainLogin)') IS NOT NULL DROP USER [\(plainLogin)];
            IF SUSER_ID(N'\(plainLogin)') IS NOT NULL DROP LOGIN [\(plainLogin)];
            CREATE LOGIN [\(plainLogin)] WITH PASSWORD = N'\(plainPassword)', CHECK_POLICY = OFF;
            CREATE USER [\(plainLogin)] FOR LOGIN [\(plainLogin)];
            GRANT SELECT, INSERT ON dbo.tp_xp_log TO [\(plainLogin)];
            GRANT SELECT ON dbo.tp_xp_customers TO [\(plainLogin)];
            """, rowCap: nil, parameters: nil)
        let logBefore = await scalar(driver, "SELECT COUNT(*) FROM dbo.tp_xp_log")
        let plain = try await connect(database, user: plainLogin, password: plainPassword)
        for showplan in MSSQLShowplan.allCases {
            do {
                _ = try await explain(plain, "INSERT INTO dbo.tp_xp_log VALUES (2)", showplan)
                expect(false, "a login without SHOWPLAN gets the server's reason on the \(showplan.variantId) plan", "a plan came back")
            } catch {
                expect(message(error).contains("SHOWPLAN permission denied"),
                       "a login without SHOWPLAN gets the server's reason on the \(showplan.variantId) plan", message(error))
            }
            expect(await scalar(plain, "SELECT 42 AS answer") == "42",
                   "that login's session runs statements normally after the refused \(showplan.variantId) plan")
        }
        expect(await scalar(driver, "SELECT COUNT(*) FROM dbo.tp_xp_log") == logBefore,
               "without SHOWPLAN, neither plan runs the INSERT")
        plain.disconnect()
        _ = try? await driver.executeBatch(query: """
            DROP USER [\(plainLogin)];
            DROP LOGIN [\(plainLogin)];
            """, rowCap: nil, parameters: nil)
    }
}
SWIFT

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
echo "Building the check from Plugins/MSSQLDriverPlugin and the app's plan parser (the first build takes a few minutes)"
swift build --package-path "$WORK" --scratch-path "$SCRATCH" > "$WORK/build.log" 2>&1 || {
    echo "the check failed to build" >&2
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}

TP_CHECK_HOST="$HOST" TP_CHECK_PORT="$PORT" TP_CHECK_USER="$USER_NAME" TP_CHECK_PASSWORD="$PASSWORD" \
    TP_CHECK_DATABASE="$DATABASE" "$SCRATCH/debug/Check"
