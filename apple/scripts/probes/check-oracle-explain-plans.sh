#!/usr/bin/env bash
#
# Check Oracle's Estimated Plan and Actual Plan against a real server, through the plugin's own explainPlan and the
# app's OraclePlanParser.
#
# The actual plan runs the statement with STATISTICS_LEVEL = ALL and reads V$SQL_PLAN_STATISTICS_ALL by
# V$SESSION.PREV_SQL_ID in the same gate turn. That lookup names the session's previous statement only if nothing else
# ran on the session in between, which oracle-nio decides and no unit test can see. So this compares the plan the
# driver returns with the one V$SQL holds for a marker unique to the run, and checks the grants message an account
# without V$ access gets, and that the grants it names are enough.
#
# Usage:
#   scripts/probes/check-oracle-explain-plans.sh [host] [port] [service] [user] [password] [sys-password]
#
# Defaults suit a throwaway Oracle Free container:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# The user needs DBA rights (SYSTEM): it creates tables prefixed TP_XP_ in its own schema and a user TP_XP_PLAIN, and
# drops all of it again. Only SYS can grant the V$ views, so that check logs in AS SYSDBA with sys-password (default:
# the password) and is skipped when it cannot. Set TP_CHECK_SCRATCH to a directory to reuse the build between
# runs. Exits 1 when a check fails, 3 when it cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1521}"
SERVICE="${3:-FREEPDB1}"
USER_NAME="${4:-system}"
PASSWORD="${5:-probe_pw}"
SYS_PASSWORD="${6:-$PASSWORD}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRATCH="${TP_CHECK_SCRATCH:-$WORK/.build}"

if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
command -v swift > /dev/null || {
    echo "swift not found" >&2
    exit 3
}

mkdir -p "$WORK/Sources/Check"
for source in "$ROOT"/Plugins/OracleDriverPlugin/*.swift "$ROOT"/Plugins/Shared/*.swift \
    "$ROOT/TablePro/Models/Query/QueryPlan.swift" \
    "$ROOT/TablePro/Core/Services/Query/QueryPlanTreeBuilder.swift" \
    "$ROOT/TablePro/Core/Services/Query/OraclePlanParser.swift" \
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
    name: "OracleExplainCheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "$ROOT/Packages/TableProCore"),
        .package(path: "$ROOT/Packages/TableProOracle"),
    ],
    targets: [
        .executableTarget(
            name: "Check",
            dependencies: [
                .product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProLogRedaction", package: "TableProCore"),
                .product(name: "TableProSQLVocabulary", package: "TableProCore"),
                .product(name: "TableProOracleCore", package: "TableProOracle"),
            ],
            path: "Sources/Check",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
MANIFEST

cat > "$WORK/Sources/Check/Check.swift" << 'SWIFT'
import Foundation
import TableProOracleCore
import TableProPluginKit

// The app declares this beside every other parser; only the two files this check needs are compiled in.
protocol QueryPlanParser {
    func parse(rawText: String) -> QueryPlan?
}

@main
enum Check {
    nonisolated(unsafe) static var failures = 0
    static let environment = ProcessInfo.processInfo.environment
    static let owner = (environment["TP_CHECK_USER"] ?? "system").uppercased()
    static let plainUser = "TP_XP_PLAIN"
    static let plainPassword = "TpXp" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)

    static func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS: \(label)")
        } else {
            failures += 1
            print("FAIL: \(label) \(detail())")
        }
    }

    static func connect(
        user: String,
        password: String,
        role: OracleConnectionOptions.Role = .normal
    ) async throws -> OraclePluginDriver {
        let driver = OraclePluginDriver(config: DriverConnectionConfig(
            host: environment["TP_CHECK_HOST"] ?? "127.0.0.1",
            port: Int(environment["TP_CHECK_PORT"] ?? "") ?? 1_521,
            username: user,
            password: password,
            database: "",
            additionalFields: [
                OracleConnectionOptions.AdditionalFieldKey.serviceName: environment["TP_CHECK_SERVICE"] ?? "FREEPDB1",
                OracleConnectionOptions.AdditionalFieldKey.role: role.rawValue,
            ]
        ))
        try await driver.connect()
        return driver
    }

    @discardableResult
    static func run(_ driver: OraclePluginDriver, _ sql: String) async -> Error? {
        do {
            _ = try await driver.execute(query: sql)
            return nil
        } catch {
            return error
        }
    }

    static func values(_ driver: OraclePluginDriver, _ sql: String) async -> [[String]] {
        guard let result = try? await driver.execute(query: sql) else { return [] }
        return result.rows.map { row in row.map { $0.asText ?? "" } }
    }

    static func scalar(_ driver: OraclePluginDriver, _ sql: String) async -> String? {
        await values(driver, sql).first?.first
    }

    struct Explained {
        let plan: QueryPlan?
        let rows: [[String: Any]]
    }

    static func explain(_ driver: OraclePluginDriver, _ statement: String, _ variant: String) async throws -> Explained {
        let result = try await driver.explainPlan(statement: statement, variantId: variant)
        let text = ExplainPlanTextFlattener.flatten(rows: result.rows)
        let rows = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]]) ?? []
        return Explained(plan: OraclePlanParser().parse(rawText: text), rows: rows)
    }

    static func nodes(_ node: QueryPlanNode) -> [QueryPlanNode] {
        [node] + node.children.flatMap(nodes)
    }

    static func relations(_ plan: QueryPlan?) -> Set<String> {
        guard let plan else { return [] }
        return Set(nodes(plan.rootNode).compactMap(\.relation))
    }

    static let joinedTables: Set<String> = ["TP_XP_CUSTOMERS", "TP_XP_ORDERS", "TP_XP_ITEMS"]

    static func join(region: String, marker: String = "", terminator: String = "") -> String {
        """
        SELECT \(marker.isEmpty ? "" : "/* \(marker) */ ")c.NAME, o.ID, i.SKU, i.QTY
        FROM \(owner).TP_XP_CUSTOMERS c
        JOIN \(owner).TP_XP_ORDERS o ON o.CUSTOMER_ID = c.ID
        JOIN \(owner).TP_XP_ITEMS i ON i.ORDER_ID = o.ID
        WHERE c.REGION = '\(region)'\(terminator)
        """
    }

    static func joinCount(_ driver: OraclePluginDriver, region: String) async -> Int? {
        await scalar(driver, "SELECT TO_CHAR(COUNT(*)) FROM (\(join(region: region)))").flatMap { Int($0) }
    }

    // The top row source under SELECT STATEMENT, which carries the statement's output rows.
    static func outputRows(_ plan: QueryPlan?) -> Int? {
        guard let root = plan?.rootNode else { return nil }
        return root.reportedTotalActualRows ?? root.children.first?.reportedTotalActualRows
    }

    static func statisticsLevel(_ driver: OraclePluginDriver) async -> String? {
        await scalar(driver, "SELECT UPPER(VALUE) FROM V$PARAMETER WHERE NAME = 'statistics_level'")
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    static func main() async {
        let admin: OraclePluginDriver
        do {
            admin = try await connect(user: environment["TP_CHECK_USER"] ?? "system", password: environment["TP_CHECK_PASSWORD"] ?? "")
        } catch {
            print("cannot connect: \(message(error))")
            exit(3)
        }
        print("server: \(admin.serverVersion ?? "unknown")")

        await cleanUp(admin)
        for statement in [
            "CREATE TABLE TP_XP_CUSTOMERS (ID NUMBER PRIMARY KEY, NAME VARCHAR2(40), REGION VARCHAR2(10))",
            "CREATE TABLE TP_XP_ORDERS (ID NUMBER PRIMARY KEY, CUSTOMER_ID NUMBER, PLACED DATE)",
            "CREATE TABLE TP_XP_ITEMS (ID NUMBER PRIMARY KEY, ORDER_ID NUMBER, SKU VARCHAR2(20), QTY NUMBER)",
            "CREATE TABLE TP_XP_LOG (X NUMBER)",
            """
            INSERT INTO TP_XP_CUSTOMERS SELECT LEVEL, 'customer ' || LEVEL,
            CASE WHEN MOD(LEVEL, 10) = 0 THEN 'north' WHEN MOD(LEVEL, 10) < 4 THEN 'south' ELSE 'west' END
            FROM DUAL CONNECT BY LEVEL <= 400
            """,
            "INSERT INTO TP_XP_ORDERS SELECT LEVEL, MOD(LEVEL, 400) + 1, SYSDATE - LEVEL FROM DUAL CONNECT BY LEVEL <= 4000",
            "INSERT INTO TP_XP_ITEMS SELECT LEVEL, MOD(LEVEL, 4000) + 1, 'SKU-' || MOD(LEVEL, 97), MOD(LEVEL, 7) + 1 FROM DUAL CONNECT BY LEVEL <= 12000",
        ] {
            if let failure = await run(admin, statement) {
                print("cannot set up the tables: \(message(failure))")
                exit(3)
            }
        }

        await estimated(admin)
        await actual(admin)
        await withoutGrants(admin)

        await cleanUp(admin)
        admin.disconnect()
        print(failures == 0 ? "Oracle plans read as TablePro shows them on this server." : "\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }

    static func estimated(_ admin: OraclePluginDriver) async {
        let planRowsBefore = await scalar(admin, "SELECT TO_CHAR(COUNT(*)) FROM PLAN_TABLE")
        do {
            let explained = try await explain(admin, join(region: "north", terminator: ";"), OracleExplainPlan.estimatedVariantId)
            expect(explained.plan != nil, "the estimated plan of a three-table join parses into a tree")
            expect(explained.plan?.rootNode.operation == "SELECT STATEMENT", "its root is the SELECT STATEMENT step",
                   explained.plan?.rootNode.operation ?? "nil")
            expect(relations(explained.plan) == joinedTables, "it reads all three tables", "\(relations(explained.plan))")
            let all = explained.plan.map { nodes($0.rootNode) } ?? []
            expect(all.contains { $0.properties["Access Predicates"]?.contains("CUSTOMER_ID") == true },
                   "a join step carries its access predicate")
            expect(all.contains { $0.properties["Filter Predicates"]?.contains("REGION") == true },
                   "the customers step carries the REGION filter")
            expect(all.allSatisfy { $0.actualLoops == nil }, "an estimated plan reports no run-time figures")
        } catch {
            expect(false, "the estimated plan of a three-table join", message(error))
        }
        let planRowsAfter = await scalar(admin, "SELECT TO_CHAR(COUNT(*)) FROM PLAN_TABLE")
        expect(planRowsBefore != nil && planRowsBefore == planRowsAfter, "the estimated plan leaves no rows in PLAN_TABLE",
               "\(planRowsBefore ?? "nil") -> \(planRowsAfter ?? "nil")")

        _ = try? await admin.explainPlan(statement: "INSERT INTO TP_XP_LOG VALUES (1)", variantId: OracleExplainPlan.estimatedVariantId)
        expect(await scalar(admin, "SELECT TO_CHAR(COUNT(*)) FROM TP_XP_LOG") == "0", "an estimated plan of an INSERT inserts nothing")
    }

    static func actual(_ admin: OraclePluginDriver) async {
        let levelBefore = await statisticsLevel(admin)
        let marker = "tp_xp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        let north = await joinCount(admin, region: "north")
        let south = await joinCount(admin, region: "south")

        do {
            // A statement right before the plan, so a lookup that read the wrong cursor would show this one.
            _ = await run(admin, "SELECT COUNT(*) FROM TP_XP_LOG")
            let explained = try await explain(admin, join(region: "north", marker: marker, terminator: ";"), OracleExplainPlan.actualVariantId)
            expect(explained.plan != nil, "the actual plan of a three-table join parses into a tree")
            expect(relations(explained.plan) == joinedTables, "it reads all three tables", "\(relations(explained.plan))")
            let all = explained.plan.map { nodes($0.rootNode) } ?? []
            expect(all.filter { $0.relation != nil }.allSatisfy { ($0.actualLoops ?? 0) >= 1 },
                   "every table step reports how often it started")
            expect(outputRows(explained.plan) == north, "the top step's actual rows are the statement's own row count",
                   "\(outputRows(explained.plan).map(String.init) ?? "nil") vs \(north.map(String.init) ?? "nil")")
            expect(explained.plan?.executionTime != nil, "the plan reports an elapsed time")

            let cursorRows = await values(admin, """
                SELECT TO_CHAR(p.ID), p.OPERATION, NVL(p.OBJECT_NAME, '-'), NVL(TO_CHAR(p.LAST_OUTPUT_ROWS), '-')
                FROM V$SQL_PLAN_STATISTICS_ALL p
                JOIN V$SQL s ON s.SQL_ID = p.SQL_ID AND s.CHILD_NUMBER = p.CHILD_NUMBER
                WHERE s.SQL_TEXT LIKE '%\(marker)%' AND s.SQL_TEXT NOT LIKE '%V$SQL%' AND s.SQL_TEXT NOT LIKE 'EXPLAIN%'
                AND s.LAST_ACTIVE_TIME = (
                    SELECT MAX(LAST_ACTIVE_TIME) FROM V$SQL
                    WHERE SQL_TEXT LIKE '%\(marker)%' AND SQL_TEXT NOT LIKE '%V$SQL%' AND SQL_TEXT NOT LIKE 'EXPLAIN%'
                )
                ORDER BY p.ID
                """)
            let shown: [[String]] = explained.rows.map { row in
                [
                    "\(row["ID"] ?? "-")",
                    "\(row["OPERATION"] ?? "-")",
                    "\(row["OBJECT_NAME"] ?? "-")",
                    row["LAST_OUTPUT_ROWS"].map { "\($0)" } ?? "-",
                ]
            }
            expect(!cursorRows.isEmpty && cursorRows == shown,
                   "the rows shown are V$SQL_PLAN_STATISTICS_ALL's rows for the statement's own cursor",
                   "shown \(shown) cursor \(cursorRows)")
        } catch {
            expect(false, "the actual plan of a three-table join", message(error))
        }

        do {
            let southPlan = try await explain(admin, join(region: "south"), OracleExplainPlan.actualVariantId)
            expect(outputRows(southPlan.plan) == south && south != north,
                   "a second actual plan reports its own run, not the previous one",
                   "\(outputRows(southPlan.plan).map(String.init) ?? "nil") vs \(south.map(String.init) ?? "nil")")
            let single = try await explain(admin, "SELECT MAX(QTY) FROM \(owner).TP_XP_ITEMS", OracleExplainPlan.actualVariantId)
            expect(relations(single.plan) == ["TP_XP_ITEMS"], "an actual plan right after a join's shows only its own table",
                   "\(relations(single.plan))")
        } catch {
            expect(false, "repeated actual plans", message(error))
        }

        do {
            let update = try await explain(admin, "UPDATE TP_XP_LOG SET X = X + 1", OracleExplainPlan.actualVariantId)
            expect(update.plan?.rootNode.operation == "UPDATE STATEMENT", "an actual plan of an UPDATE reads the UPDATE's cursor",
                   update.plan?.rootNode.operation ?? "nil")
        } catch {
            expect(false, "the actual plan of an UPDATE", message(error))
        }

        let levelAfter = await statisticsLevel(admin)
        expect(levelBefore != nil && levelAfter == levelBefore, "the session's STATISTICS_LEVEL is put back",
               "\(levelBefore ?? "nil") -> \(levelAfter ?? "nil")")
    }

    static func withoutGrants(_ admin: OraclePluginDriver) async {
        for statement in [
            "CREATE USER \(plainUser) IDENTIFIED BY \"\(plainPassword)\"",
            "GRANT CREATE SESSION TO \(plainUser)",
            "CREATE TABLE \(plainUser).TP_XP_NOTE (X NUMBER)",
            "ALTER USER \(plainUser) QUOTA UNLIMITED ON USERS",
            "GRANT SELECT ON TP_XP_CUSTOMERS TO \(plainUser)",
            "GRANT SELECT ON TP_XP_ORDERS TO \(plainUser)",
            "GRANT SELECT ON TP_XP_ITEMS TO \(plainUser)",
        ] {
            if let failure = await run(admin, statement) {
                print("SKIP: the checks without V$ grants: \(message(failure))")
                return
            }
        }

        let plain: OraclePluginDriver
        do {
            plain = try await connect(user: plainUser, password: plainPassword)
        } catch {
            expect(false, "a login as \(plainUser)", message(error))
            return
        }
        defer { plain.disconnect() }

        do {
            _ = try await plain.explainPlan(statement: join(region: "north"), variantId: OracleExplainPlan.actualVariantId)
            expect(false, "an account without V$ grants gets the grants message on Actual Plan", "the plan ran")
        } catch {
            expect(message(error) == OracleExplainPlan.missingGrantsMessage,
                   "an account without V$ grants gets the grants message on Actual Plan", message(error))
        }
        _ = try? await plain.explainPlan(statement: "INSERT INTO TP_XP_NOTE VALUES (1)", variantId: OracleExplainPlan.actualVariantId)
        expect(await scalar(admin, "SELECT TO_CHAR(COUNT(*)) FROM \(plainUser).TP_XP_NOTE") == "0",
               "without the grants, an actual plan of an INSERT runs nothing")
        do {
            let explained = try await explain(plain, join(region: "north"), OracleExplainPlan.estimatedVariantId)
            expect(relations(explained.plan) == joinedTables, "Estimated Plan still works for that account",
                   "\(relations(explained.plan))")
        } catch {
            expect(false, "Estimated Plan still works for that account", message(error))
        }

        // Only SYS can grant the V$ views.
        let sys: OraclePluginDriver
        do {
            sys = try await connect(user: "SYS", password: environment["TP_CHECK_SYS_PASSWORD"] ?? "", role: .sysdba)
        } catch {
            print("SKIP: whether the grants the message names are enough, with no SYSDBA login: \(message(error))")
            return
        }
        defer { sys.disconnect() }
        for view in ["V_$SESSION", "V_$PARAMETER", "V_$SQL_PLAN_STATISTICS_ALL"] {
            if let failure = await run(sys, "GRANT SELECT ON SYS.\(view) TO \(plainUser)") {
                expect(false, "SYS grants \(view)", message(failure))
                return
            }
        }
        do {
            let explained = try await explain(plain, join(region: "north"), OracleExplainPlan.actualVariantId)
            expect(relations(explained.plan) == joinedTables, "the three grants the message names are enough for Actual Plan",
                   "\(relations(explained.plan))")
        } catch {
            expect(false, "the three grants the message names are enough for Actual Plan", message(error))
        }
    }

    static func cleanUp(_ admin: OraclePluginDriver) async {
        for table in ["TP_XP_ITEMS", "TP_XP_ORDERS", "TP_XP_CUSTOMERS", "TP_XP_LOG"] {
            await run(admin, "BEGIN EXECUTE IMMEDIATE 'DROP TABLE \(table) PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;")
        }
        await run(admin, "BEGIN EXECUTE IMMEDIATE 'DROP USER \(plainUser) CASCADE'; EXCEPTION WHEN OTHERS THEN NULL; END;")
    }
}
SWIFT

echo "Building the check from Plugins/OracleDriverPlugin and the app's plan parser (the first build takes a few minutes)"
swift build --package-path "$WORK" --scratch-path "$SCRATCH" > "$WORK/build.log" 2>&1 || {
    echo "the check failed to build" >&2
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}

TP_CHECK_HOST="$HOST" TP_CHECK_PORT="$PORT" TP_CHECK_SERVICE="$SERVICE" TP_CHECK_USER="$USER_NAME" \
    TP_CHECK_PASSWORD="$PASSWORD" TP_CHECK_SYS_PASSWORD="$SYS_PASSWORD" "$SCRATCH/debug/Check" 2> /dev/null
