#!/usr/bin/env bash
#
# Check, against a real SQL Server, that a SQL file imported into it runs the way sqlcmd runs it.
#
# sqlcmd and SQL Server Management Studio cut a script into batches at each line holding only GO, send every batch
# whole, and never send the GO line. The import used to split a file at each `;` and send the GO lines on: the server
# ran the statement after a GO, refused the GO itself with Msg 2812 or Msg 102, cut a procedure off at its first inner
# `;`, and dropped every variable before the statement that read it (Msg 137). None of that shows in a unit test,
# because each case depends on what the server does with the text it is sent.
#
# So this builds a harness from the real TablePro/Core/Utilities/SQL/SQLFileParser.swift and the files it reads
# lines and chunks with, the real Plugins/MSSQLDriverPlugin sources, the TableProCore package and the shipped
# Libs/libsybdb.a. Each script is read by SQLFileParser with the SQL Server grammar and every batch it hands out goes
# through MSSQLPluginDriver.executeBatch, as ImportDataSinkAdapter sends it: the first batch that raises an error stops
# the import, with the server's line placed in the file. Then the database is read back.
#
# Usage:
#   scripts/check-mssql-sql-import.sh [host] [port] [user]
#
# The password comes from MSSQL_SA_PASSWORD and the database from TP_CHECK_DATABASE (default
# tablepro_sql_import_check, created when missing). With no server listening on host:port, the script starts
# mcr.microsoft.com/azure-sql-edge in Docker as tablepro-mssql-check (or TP_MSSQL_CONTAINER), generating a password
# when none is set, and leaves it running for the next run. Exits 1 when a check fails, 3 when it cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-14339}"
USER_NAME="${3:-sa}"
PASSWORD="${MSSQL_SA_PASSWORD:-}"
DATABASE="${TP_CHECK_DATABASE:-tablepro_sql_import_check}"
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
for source in "$ROOT"/Plugins/MSSQLDriverPlugin/*.swift \
    "$ROOT/TablePro/Core/Utilities/SQL/SQLFileParser.swift" \
    "$ROOT/TablePro/Core/Utilities/SQL/SQLFileBatchLines.swift" \
    "$ROOT/TablePro/Core/Utilities/SQL/SQLChunkDecoder.swift" \
    "$ROOT/TablePro/Core/Utilities/Text/ByteOrderMark.swift"; do
    ln -s "$source" "$WORK/Sources/Check/$(basename "$source")"
done

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSSQLSQLImportCheck",
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

/// The one type SQLFileParser needs from the app beyond the files linked in beside it.
enum DecompressionError: Error {
    case decompressFailed
    case fileReadFailed(String)
}

@main
enum Check {
    nonisolated(unsafe) static var failures = 0

    static let grammar = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil).execution

    struct ImportFailure {
        let batchLine: Int
        let errorLine: Int?
        let message: String
    }

    static func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS: \(label)")
        } else {
            failures += 1
            print("FAIL: \(label) \(detail())")
        }
    }

    /// The import as the app runs it on SQL Server with Stop and Rollback and no transaction: every run the parser hands
    /// out goes to the server whole, and the first that raises an error ends the import. The error's line is the
    /// server's line moved onto the file by where the batch starts, which is what `BatchErrorText` does.
    static func importScript(
        _ text: String,
        driver: MSSQLPluginDriver,
        parser: SQLFileParser = SQLFileParser()
    ) async throws -> (runs: [String], failure: ImportFailure?) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sql")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var runs: [String] = []
        for try await (batch, line) in parser.parseFile(url: url, encoding: .utf8, grammar: grammar) {
            runs.append(batch)
            let answer = try await driver.executeBatch(query: batch, rowCap: 1, parameters: nil)
            if let error = answer?.errors.first {
                let fileLine = error.line.map { line + $0 - 1 }
                return (runs, ImportFailure(batchLine: line, errorLine: fileLine, message: error.message))
            }
        }
        return (runs, nil)
    }

    static func scalar(_ sql: String, _ driver: MSSQLPluginDriver) async throws -> String? {
        try await driver.execute(query: sql).rows.first?.first?.asText
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

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            try await run()
        } catch {
            failures += 1
            print("FAIL: unexpected error \(error)")
        }
        print(failures == 0 ? "OK: every check passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func run() async throws {
        let database = ProcessInfo.processInfo.environment["TP_CHECK_DATABASE"] ?? "tablepro_sql_import_check"
        let admin = try await connect("master")
        _ = try await admin.execute(query: "IF DB_ID(N'\(database)') IS NULL CREATE DATABASE [\(database)]")
        admin.disconnect()

        let driver = try await connect(database)
        _ = try await driver.executeBatch(query: """
            IF OBJECT_ID(N'dbo.import_v') IS NOT NULL DROP VIEW dbo.import_v;
            IF OBJECT_ID(N'dbo.import_p') IS NOT NULL DROP PROCEDURE dbo.import_p;
            IF OBJECT_ID(N'dbo.import_c') IS NOT NULL DROP PROCEDURE dbo.import_c;
            IF OBJECT_ID(N'dbo.import_rows') IS NOT NULL DROP TABLE dbo.import_rows;
            CREATE TABLE dbo.import_rows (id INT NULL, v NVARCHAR(40) NULL);
            EXEC (N'CREATE PROCEDURE dbo.import_p AS SELECT 0;');
            """, rowCap: nil, parameters: nil)

        try await compareScript(driver)
        try await ssmsScript(driver)
        try await declaredVariable(driver)
        try await repeatedBatch(driver)
        try await commentsInARoutine(driver)
        try await goInsideALiteral(driver)
        try await errorLine(driver)
        try await dumpWithGoLines(driver)
        try await dumpCutAtSemicolons(driver)
        driver.disconnect()
    }

    static func compareScript(_ driver: MSSQLPluginDriver) async throws {
        let script = """
            DROP PROCEDURE [dbo].[import_p];
            GO
            CREATE PROCEDURE dbo.import_p AS SET NOCOUNT ON; SELECT 1;
            GO

            """
        let result = try await importScript(script, driver: driver)
        expect(result.failure == nil, "a Compare script imports", "\(String(describing: result.failure))")
        expect(!result.runs.contains { $0.uppercased().contains("\nGO") || $0.uppercased() == "GO" },
               "no GO line reaches the server", "\(result.runs)")
        let definition = try await scalar("SELECT OBJECT_DEFINITION(OBJECT_ID(N'dbo.import_p'))", driver)
        expect(definition == "CREATE PROCEDURE dbo.import_p AS SET NOCOUNT ON; SELECT 1;",
               "the procedure keeps the statement after its inner semicolon", "\(String(describing: definition))")
        let answer = try await driver.executeBatch(query: "EXEC dbo.import_p", rowCap: nil, parameters: nil)
        expect(answer?.resultSets.first?.rows.first?.first?.asText == "1", "the imported procedure runs")
    }

    static func ssmsScript(_ driver: MSSQLPluginDriver) async throws {
        let script = """
            DELETE FROM dbo.import_rows
            GO
            INSERT dbo.import_rows (id, v) VALUES (1, N'one')
            INSERT dbo.import_rows (id, v) VALUES (2, N'two')
            GO
            """
        let result = try await importScript(script, driver: driver)
        expect(result.failure == nil, "an SSMS script with no semicolons imports", "\(String(describing: result.failure))")
        expect(try await scalar("SELECT COUNT(*) FROM dbo.import_rows", driver) == "2", "both rows arrive")
    }

    static func declaredVariable(_ driver: MSSQLPluginDriver) async throws {
        let script = """
            DELETE FROM dbo.import_rows;
            DECLARE @x INT = 7;
            INSERT INTO dbo.import_rows (id) VALUES (@x);
            """
        let result = try await importScript(script, driver: driver)
        expect(result.failure == nil, "a variable is declared for the statement that reads it",
               "\(String(describing: result.failure))")
        expect(try await scalar("SELECT MAX(id) FROM dbo.import_rows", driver) == "7", "the variable's value arrives")
    }

    static func repeatedBatch(_ driver: MSSQLPluginDriver) async throws {
        let script = "DELETE FROM dbo.import_rows\nGO\nINSERT dbo.import_rows (id) VALUES (3)\nGO 3\n"
        let result = try await importScript(script, driver: driver)
        expect(result.failure == nil, "GO 3 imports", "\(String(describing: result.failure))")
        expect(try await scalar("SELECT COUNT(*) FROM dbo.import_rows", driver) == "3", "GO 3 runs its batch three times")
    }

    static func commentsInARoutine(_ driver: MSSQLPluginDriver) async throws {
        let script = """
            CREATE PROCEDURE dbo.import_c AS
            -- keeps this note
            SELECT 2; /* and this one */
            GO
            """
        let result = try await importScript(script, driver: driver)
        expect(result.failure == nil, "a routine with comments imports", "\(String(describing: result.failure))")
        let definition = try await scalar("SELECT OBJECT_DEFINITION(OBJECT_ID(N'dbo.import_c'))", driver) ?? ""
        expect(definition.contains("-- keeps this note") && definition.contains("/* and this one */"),
               "the stored routine keeps the comments written in it", definition)
    }

    static func goInsideALiteral(_ driver: MSSQLPluginDriver) async throws {
        let script = "DELETE FROM dbo.import_rows;\nINSERT dbo.import_rows (id, v) VALUES (9, N'a\nGO\nb');\nGO\n"
        let result = try await importScript(script, driver: driver)
        expect(result.failure == nil, "a GO line inside a literal imports", "\(String(describing: result.failure))")
        expect(try await scalar("SELECT v FROM dbo.import_rows WHERE id = 9", driver) == "a\nGO\nb",
               "the literal keeps its GO line")
    }

    static func errorLine(_ driver: MSSQLPluginDriver) async throws {
        let script = """
            SELECT 1
            GO
            -- the batch below starts on line 3

            SELECT 2
            SELECT * FROM dbo.no_such_table
            GO
            SELECT 3
            """
        let result = try await importScript(script, driver: driver)
        expect(result.failure?.batchLine == 3, "the failure names the batch's first line",
               "\(String(describing: result.failure))")
        expect(result.failure?.errorLine == 6, "the server's line lands on the file's line",
               "\(String(describing: result.failure))")
        expect(result.failure?.message.contains("no_such_table") == true, "the server's own message is kept")
        expect(result.runs.count == 2, "the import stops at the batch that failed", "\(result.runs)")
    }

    /// The shape TablePro's SQL export writes for SQL Server: every statement a batch of its own, so a view or a routine
    /// is first in its batch as SQL Server requires. Written without the GO lines, the same dump fails its view with
    /// Msg 111 and runs none of the batch, which is what the export used to write.
    static func dumpWithGoLines(_ driver: MSSQLPluginDriver) async throws {
        let statements = [
            "IF OBJECT_ID(N'dbo.import_v') IS NOT NULL DROP VIEW dbo.import_v;",
            "DELETE FROM dbo.import_rows;",
            "INSERT INTO [dbo].[import_rows] ([id], [v]) VALUES (1, N'x'), (2, N'y');",
            "CREATE VIEW dbo.import_v AS SELECT id FROM dbo.import_rows;",
        ]
        let withGo = try await importScript(statements.map { "\($0)\nGO" }.joined(separator: "\n"), driver: driver)
        expect(withGo.failure == nil, "a dump with a GO line after each statement imports",
               "\(String(describing: withGo.failure))")
        expect(try await scalar("SELECT COUNT(*) FROM dbo.import_v", driver) == "2", "the dump's view reads its rows")

        let withoutGo = try await importScript(statements.joined(separator: "\n"), driver: driver)
        expect(withoutGo.failure?.message.contains("must be the first statement") == true,
               "the same dump with no GO line fails its view as sqlcmd would", "\(String(describing: withoutGo.failure))")
    }

    /// A batch past the cut length ends at a semicolon, which is what keeps a dump written with no GO line inside what
    /// the server takes in one request. A small cut length stands in for the real one.
    static func dumpCutAtSemicolons(_ driver: MSSQLPluginDriver) async throws {
        let rows = (1...40).map { "INSERT INTO dbo.import_rows (id, v) VALUES (\($0), N'r;\($0)');" }
        let script = (["DELETE FROM dbo.import_rows;"] + rows).joined(separator: "\n")
        let result = try await importScript(script, driver: driver, parser: SQLFileParser(batchCutLength: 200))
        expect(result.failure == nil, "a cut dump imports", "\(String(describing: result.failure))")
        expect(result.runs.count > 1, "the dump was sent in more than one batch", "\(result.runs.count)")
        expect(try await scalar("SELECT COUNT(*) FROM dbo.import_rows", driver) == "40", "every row of a cut dump arrives")
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
