#!/usr/bin/env bash
#
# Check, against a real SQL Server, that every MERGE the editor and SQL import send keeps the `;` the server requires.
#
# SQL Server fails a whole batch whose MERGE has no `;` with Msg 10713, and runs none of its statements. The
# statement scanner and the import parser strip the `;` that ends a statement, so a MERGE run alone, the last
# statement of a script, one sent statement by statement or one imported from a file went out without it.
# Packages/TableProCore/Sources/TableProSQLGrammar/SQLMergeStatementTracker.swift decides which `;` belongs to a
# MERGE, and where one does not is the server's decision: a MERGE inside parentheses, a MERGE JOIN hint, and a name
# such as @merge or x$merge need none, while a MERGE after a name and a space, or on a table named range, does.
#
# So this builds a harness from the real Plugins/MSSQLDriverPlugin sources, the TableProCore package, the app's
# TablePro/Core/Utilities/SQL/SQLFileParser.swift and the shipped Libs/libsybdb.a. For each editor text it takes what
# the scanner sends, as one batch cut from the first statement to the last the way the app's batch planner cuts it,
# statement by statement, and what the import parser reads from the text saved as a file, and runs each through
# MSSQLPluginDriver. Each must run and leave the rows expected. For a MERGE it also sends the batch without its last
# `;`, which must still fail with Msg 10713: that is what the scanner used to send, and what shows the rule holds.
#
# Usage:
#   scripts/check-mssql-merge-terminator.sh [host] [port] [user]
#
# The password comes from MSSQL_SA_PASSWORD and the database from TP_CHECK_DATABASE (default
# tablepro_merge_terminator_check, created when missing). With no server listening on host:port, the script starts
# mcr.microsoft.com/azure-sql-edge in Docker as tablepro-mssql-check (or TP_MSSQL_CONTAINER), generating a password
# when none is set, and leaves it running for the next run. Exits 1 when a check fails, 3 when it cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-14339}"
USER_NAME="${3:-sa}"
PASSWORD="${MSSQL_SA_PASSWORD:-}"
DATABASE="${TP_CHECK_DATABASE:-tablepro_merge_terminator_check}"
CONTAINER="${TP_MSSQL_CONTAINER:-tablepro-mssql-check}"
IMAGE="mcr.microsoft.com/azure-sql-edge:latest"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$ROOT/Libs/libsybdb.a" ] || {
    echo "not found: Libs/libsybdb.a (run scripts/download-libs.sh)" >&2
    exit 3
}

listening() {
    nc -z "$HOST" "$PORT" > /dev/null 2>&1
}

if ! listening; then
    command -v docker > /dev/null 2>&1 || {
        echo "no SQL Server at $HOST:$PORT and no docker to start one" >&2
        exit 3
    }
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        echo "starting container $CONTAINER"
        docker start "$CONTAINER" > /dev/null || exit 3
    else
        if [ -z "$PASSWORD" ]; then
            PASSWORD="TpCheck#$(openssl rand -hex 8)"
            echo "generated a password for $CONTAINER; export MSSQL_SA_PASSWORD='$PASSWORD' to reuse it"
        fi
        echo "starting $IMAGE as $CONTAINER on $HOST:$PORT"
        docker run -d --name "$CONTAINER" -e ACCEPT_EULA=1 -e "MSSQL_SA_PASSWORD=$PASSWORD" \
            -p "$HOST:$PORT:1433" "$IMAGE" > /dev/null || exit 3
    fi
    for _ in $(seq 1 60); do
        listening && break
        sleep 2
    done
fi

[ -n "$PASSWORD" ] || {
    echo "no password: set MSSQL_SA_PASSWORD for the server at $HOST:$PORT" >&2
    exit 3
}

mkdir -p "$WORK/Sources/Check"
ln -s "$ROOT/Plugins/MSSQLDriverPlugin/CFreeTDS" "$WORK/CFreeTDS"
for source in "$ROOT"/Plugins/MSSQLDriverPlugin/*.swift "$ROOT"/TablePro/Core/Utilities/SQL/SQLFileParser.swift \
    "$ROOT"/TablePro/Core/Utilities/SQL/SQLFileBatchLines.swift \
    "$ROOT"/TablePro/Core/Utilities/SQL/SQLChunkDecoder.swift "$ROOT"/TablePro/Core/Utilities/Text/ByteOrderMark.swift; do
    ln -s "$source" "$WORK/Sources/Check/$(basename "$source")"
done
echo 'enum DecompressionError: Error { case fileReadFailed(String) }' > "$WORK/Sources/Check/DecompressionError.swift"

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSSQLMergeTerminatorCheck",
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
                .product(name: "TableProSQLGrammar", package: "TableProCore"),
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
import TableProCoreTypes
import TableProPluginKit
import TableProSQLGrammar

@main
enum Check {
    struct Case {
        let name: String
        let text: String
        let needsTerminator: Bool
        let keepsTerminator: Bool
        let runsStatementByStatement: Bool
        let expectation: String
        let expected: String

        init(
            _ name: String,
            _ text: String,
            needsTerminator: Bool,
            keepsTerminator: Bool? = nil,
            runsStatementByStatement: Bool = true,
            expectation: String = "SELECT COUNT(*) FROM dbo.merge_target",
            expected: String = "2"
        ) {
            self.name = name
            self.text = text
            self.needsTerminator = needsTerminator
            self.keepsTerminator = keepsTerminator ?? needsTerminator
            self.runsStatementByStatement = runsStatementByStatement
            self.expectation = expectation
            self.expected = expected
        }
    }

    static let merge = """
        MERGE dbo.merge_target AS t USING dbo.merge_source AS s ON t.id = s.id \
        WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v)
        """

    static let cases: [Case] = [
        Case("a MERGE alone", "\(merge);", needsTerminator: true),
        Case("a MERGE in lower case", "\(merge.lowercased());", needsTerminator: true),
        Case("a MERGE after a common table expression",
             "WITH src AS (SELECT id, v FROM dbo.merge_source)\n"
                 + merge.replacingOccurrences(of: "USING dbo.merge_source", with: "USING src") + ";",
             needsTerminator: true),
        Case("a MERGE after IF", "IF 1 = 1\n    \(merge);", needsTerminator: true),
        Case("a MERGE after ELSE", "IF 1 = 0 SELECT 1\nELSE\n    \(merge);", needsTerminator: true),
        Case("a MERGE after a DECLARE with no ;", "DECLARE @d INT = 1\n\(merge);", needsTerminator: true),
        Case("a MERGE glued to a number", "SELECT 1\(merge);", needsTerminator: true),
        Case("a MERGE with OUTPUT", "\(merge)\nOUTPUT $action, inserted.id;", needsTerminator: true),
        Case("a MERGE into a temporary table in the middle of a script",
             "SELECT id, v INTO #merge_stage FROM dbo.merge_target WHERE 1 = 0;\n"
                 + "MERGE #merge_stage AS t USING dbo.merge_source AS s ON t.id = s.id "
                 + "WHEN NOT MATCHED THEN INSERT (id, v) VALUES (s.id, s.v);\n"
                 + "INSERT INTO dbo.merge_target SELECT id, v FROM #merge_stage;\nDROP TABLE #merge_stage;",
             needsTerminator: false),
        Case("a script that ends with a MERGE",
             "DECLARE @d INT = 1;\nUPDATE dbo.merge_source SET v = v + @d;\n\(merge);",
             needsTerminator: true, runsStatementByStatement: false),
        Case("a procedure whose body is a MERGE", "CREATE PROCEDURE dbo.merge_proc AS\n\(merge);",
             needsTerminator: true,
             expectation: "SELECT COUNT(*) FROM sys.procedures WHERE name = 'merge_proc'", expected: "1"),
        Case("a procedure whose BEGIN ... END body holds a MERGE",
             "CREATE PROCEDURE dbo.merge_proc AS\nBEGIN\n    UPDATE dbo.merge_source SET v = v;\n    \(merge);\nEND;",
             needsTerminator: false,
             expectation: "SELECT COUNT(*) FROM sys.procedures WHERE name = 'merge_proc'", expected: "1"),
        Case("a MERGE after a name in Japanese",
             "SELECT COUNT(*) FROM dbo.merge_source AS \u{6CE8}\u{6587}\n\(merge);", needsTerminator: true),
        Case("a MERGE after an accented name and a line comment",
             "SELECT 1 AS caf\u{00E9} -- note\n\(merge);", needsTerminator: true),
        Case("a MERGE after a name that ends in $", "SELECT 1 AS x$\n\(merge);", needsTerminator: true),
        Case("a MERGE after a name in Chinese and a block comment",
             "SELECT COUNT(*) FROM dbo.merge_source AS \u{9867}\u{5BA2} /* c */ \(merge);", needsTerminator: true),
        Case("a MERGE into a table named range",
             merge.replacingOccurrences(of: "dbo.merge_target", with: "range") + ";", needsTerminator: true,
             expectation: "SELECT COUNT(*) FROM range"),
        Case("a MERGE into a table named Range, in mixed case",
             merge.replacingOccurrences(of: "dbo.merge_target", with: "Range") + ";", needsTerminator: true,
             expectation: "SELECT COUNT(*) FROM range"),
        Case("a MERGE inside parentheses",
             "INSERT INTO dbo.merge_log (act, id)\nSELECT act, id FROM (\(merge)\n"
                 + "OUTPUT $action, inserted.id) AS c (act, id);",
             needsTerminator: false),
        Case("a MERGE JOIN hint",
             "SELECT s.id FROM dbo.merge_source AS s INNER MERGE JOIN dbo.merge_target AS t ON s.id = t.id;",
             needsTerminator: false, expected: "0"),
        Case("a MERGE JOIN query hint", "SELECT id FROM dbo.merge_source OPTION (MERGE JOIN);",
             needsTerminator: false, expected: "0"),
        Case("MERGE RANGE", "ALTER PARTITION FUNCTION merge_pf () MERGE RANGE (2);", needsTerminator: false,
             keepsTerminator: true,
             expectation: "SELECT fanout FROM sys.partition_functions WHERE name = 'merge_pf'", expected: "3"),
        Case("a variable named merge", "DECLARE @merge INT = 1\nSELECT @merge AS a;", needsTerminator: false,
             expected: "0"),
        Case("a name ending in merge", "SELECT 1 AS x$merge;", needsTerminator: false, expected: "0"),
        Case("a name with a letter outside ASCII", "SELECT 1 AS \u{00E9}merge;", needsTerminator: false,
             expected: "0"),
        Case("a name in Japanese that ends in merge", "SELECT 1 AS \u{6CE8}\u{6587}merge;", needsTerminator: false,
             expected: "0"),
    ]

    static let reset = """
        IF OBJECT_ID(N'dbo.merge_proc') IS NOT NULL DROP PROCEDURE dbo.merge_proc;
        IF OBJECT_ID(N'dbo.merge_target') IS NOT NULL DROP TABLE dbo.merge_target;
        IF OBJECT_ID(N'dbo.merge_source') IS NOT NULL DROP TABLE dbo.merge_source;
        IF OBJECT_ID(N'dbo.merge_log') IS NOT NULL DROP TABLE dbo.merge_log;
        IF OBJECT_ID(N'dbo.range') IS NOT NULL DROP TABLE dbo.range;
        IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'merge_pf') DROP PARTITION FUNCTION merge_pf;
        CREATE TABLE dbo.merge_target (id INT PRIMARY KEY, v INT);
        CREATE TABLE range (id INT PRIMARY KEY, v INT);
        CREATE TABLE dbo.merge_source (id INT, v INT);
        CREATE TABLE dbo.merge_log (act NVARCHAR(10), id INT);
        CREATE PARTITION FUNCTION merge_pf (INT) AS RANGE LEFT FOR VALUES (1, 2, 3);
        INSERT INTO dbo.merge_source VALUES (1, 10), (2, 20);
        """

    static let teardown = """
        DROP PROCEDURE IF EXISTS dbo.merge_proc;
        DROP TABLE IF EXISTS dbo.merge_target, dbo.merge_source, dbo.merge_log, dbo.range;
        IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = 'merge_pf') DROP PARTITION FUNCTION merge_pf;
        """

    static let grammar = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil)
        .execution

    static func connect(_ database: String) async throws -> MSSQLPluginDriver {
        let environment = ProcessInfo.processInfo.environment
        let config = DriverConnectionConfig(
            host: environment["TP_CHECK_HOST"] ?? "127.0.0.1",
            port: Int(environment["TP_CHECK_PORT"] ?? "") ?? 1433,
            username: environment["TP_CHECK_USER"] ?? "sa",
            password: environment["TP_CHECK_PASSWORD"] ?? "",
            database: database
        )
        let deadline = Date().addingTimeInterval(120)
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

    /// The text the app's batch planner sends for a script with no GO line: from the first statement's start to the
    /// last one's end.
    static func batchText(of text: String) -> String? {
        let statements = SQLStatementScanner.executableStatements(in: text, grammar: grammar)
        guard let first = statements.first, let last = statements.last else { return nil }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        return (text as NSString).substring(with: span)
    }

    static func answer(_ driver: MSSQLPluginDriver, _ query: String) async throws -> String {
        let result = try await driver.execute(query: query)
        return result.rows.first?.first?.asText ?? "?"
    }

    static func runBatch(_ driver: MSSQLPluginDriver, _ sql: String) async throws -> [PluginBatchError] {
        try await driver.executeBatch(query: sql, rowCap: nil, parameters: nil)?.errors ?? []
    }

    static func runStatements(_ driver: MSSQLPluginDriver, _ statements: [String]) async -> String? {
        for statement in statements {
            do {
                _ = try await driver.execute(query: statement)
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    /// What SQL import reads from the text saved as a file, each piece of which it sends whole: a statement at a time
    /// for a text with no GO line, as these are, and a batch at a time for one with.
    static func imported(_ text: String) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sql")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var statements: [String] = []
        for try await (statement, _) in SQLFileParser().parseFile(url: url, encoding: .utf8, grammar: grammar) {
            statements.append(statement)
        }
        return statements
    }

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let database = ProcessInfo.processInfo.environment["TP_CHECK_DATABASE"] ?? "tablepro_merge_terminator_check"
        var failures = 0
        func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("PASS: \(label)")
            } else {
                failures += 1
                print("FAIL: \(label) \(detail())")
            }
        }
        do {
            let admin = try await connect("master")
            _ = try await admin.execute(query: "IF DB_ID(N'\(database)') IS NULL CREATE DATABASE [\(database)]")
            admin.disconnect()

            let driver = try await connect(database)
            for check in cases {
                guard let batch = batchText(of: check.text) else {
                    expect(false, "\(check.name): the scanner finds a statement")
                    continue
                }
                expect(batch.hasSuffix(";") == check.keepsTerminator,
                       "\(check.name): the batch \(check.keepsTerminator ? "keeps" : "drops") its last ;", batch)

                _ = try await runBatch(driver, reset)
                let errors = try await runBatch(driver, batch)
                let afterBatch = try await answer(driver, check.expectation)
                expect(errors.isEmpty && afterBatch == check.expected, "\(check.name): the batch runs",
                       "errors \(errors.map(\.message)), answer \(afterBatch)")

                if check.runsStatementByStatement {
                    _ = try await runBatch(driver, reset)
                    let scanned = SQLStatementScanner.executableStatements(in: check.text, grammar: grammar).map(\.sql)
                    let failure = await runStatements(driver, scanned)
                    let afterStatements = try await answer(driver, check.expectation)
                    expect(failure == nil && afterStatements == check.expected,
                           "\(check.name): statement by statement it runs",
                           "error \(failure ?? "none"), answer \(afterStatements)")

                    for (file, reading) in [(check.text, "a statement at a time"), (check.text + "\nGO\n", "as a batch")] {
                        _ = try await runBatch(driver, reset)
                        let pieces = try await imported(file)
                        var importErrors: [PluginBatchError] = []
                        for piece in pieces {
                            importErrors += try await runBatch(driver, piece)
                        }
                        let afterImport = try await answer(driver, check.expectation)
                        expect(importErrors.isEmpty && afterImport == check.expected,
                               "\(check.name): imported from a file \(reading) it runs",
                               "pieces \(pieces), errors \(importErrors.map(\.message)), answer \(afterImport)")
                    }
                }

                guard check.needsTerminator else { continue }
                _ = try await runBatch(driver, reset)
                let stripped = try await runBatch(driver, String(batch.dropLast()))
                expect(stripped.contains { $0.code == 10713 },
                       "\(check.name): without its ; the server still refuses it with Msg 10713",
                       "\(stripped.map { "\($0.code ?? 0) \($0.message)" })")
            }
            _ = try await runBatch(driver, teardown)
            driver.disconnect()
        } catch {
            failures += 1
            print("FAIL: unexpected error \(error)")
        }
        print("\(cases.count) texts, \(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
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
