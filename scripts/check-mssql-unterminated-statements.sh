#!/usr/bin/env bash
#
# Check, against a real SQL Server, that the Safe Mode gates see every statement T-SQL runs without a terminator.
#
# T-SQL needs no `;` between statements, so `SELECT 1` followed by `DELETE FROM t` is one statement to the scanner
# and two to the server. Packages/TableProCore/Sources/TableProSQLGrammar/SQLUnterminatedStatements.swift finds the
# statements that begin inside a scanned one, and the gates tier each of them. Where one begins is the server's
# decision, and it is not the obvious one: `1DELETE` and `$1DELETE` run the DELETE, `0xDELETE` and `1xDELETE` do not,
# a zero-width space ends a word and a letter outside ASCII continues one, and a procedure body swallows the rest of
# its batch.
#
# So this builds a harness from the real Plugins/MSSQLDriverPlugin sources, the TableProCore package and the shipped
# Libs/libsybdb.a, sends each text whole through MSSQLPluginDriver, and watches a three-row canary table and the table
# a SELECT INTO would create. A text that changed either ran its hidden statement, and then both the reader (a
# statement that begins with the hidden keyword) and the iOS gate (SQLWriteClassifier) must have seen it, or the check
# fails. A text the reader splits although the server ran nothing is reported as read conservatively, which is allowed.
#
# Usage:
#   scripts/check-mssql-unterminated-statements.sh [host] [port] [user]
#
# The password comes from MSSQL_SA_PASSWORD and the database from TP_CHECK_DATABASE (default
# tablepro_unterminated_check, created when missing). With no server listening on host:port, the script starts
# mcr.microsoft.com/azure-sql-edge in Docker as tablepro-mssql-check (or TP_MSSQL_CONTAINER), generating a password
# when none is set, and leaves it running for the next run. Exits 1 when a check fails, 3 when it cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-14339}"
USER_NAME="${3:-sa}"
PASSWORD="${MSSQL_SA_PASSWORD:-}"
DATABASE="${TP_CHECK_DATABASE:-tablepro_unterminated_check}"
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
for source in "$ROOT"/Plugins/MSSQLDriverPlugin/*.swift; do
    ln -s "$source" "$WORK/Sources/Check/$(basename "$source")"
done

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSSQLUnterminatedCheck",
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
                .product(name: "TableProQuery", package: "TableProCore"),
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
import TableProQuery
import TableProSQLGrammar

@main
enum Check {
    struct Case {
        let name: String
        let sql: String
        let hidden: String
    }

    static let canary = "dbo.unterminated_canary"
    static let intoTable = "dbo.unterminated_into"

    static let cases: [Case] = [
        Case(name: "a line break", sql: "SELECT 1\nDELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a space", sql: "SELECT 1 DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "after PRINT", sql: "PRINT 'x' DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "after SET", sql: "SET NOCOUNT ON DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "after WAITFOR", sql: "WAITFOR DELAY '00:00:00' DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "after ELSE", sql: "IF 1 = 0 SELECT 1 ELSE DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "after LINENO", sql: "SELECT 1 LINENO 5 DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "after CREATE TYPE", sql: "CREATE TYPE dbo.unterminated_t FROM int DELETE FROM \(canary)",
             hidden: "DELETE"),
        Case(name: "glued to an integer", sql: "SELECT 1DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to a decimal point", sql: "SELECT 1.DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to an exponent", sql: "SELECT 1e1DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to an empty exponent", sql: "SELECT 1eDELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to a signed empty exponent", sql: "SELECT 1E+DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to a fraction", sql: "SELECT .5DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to money", sql: "SELECT $1DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to euro money", sql: "SELECT \u{20AC}1DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to a Unicode literal", sql: "SELECT N'a'DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to a quoted alias", sql: "SELECT 1 AS \"a\"DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to a comment", sql: "SELECT 1/**/DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "glued to a parenthesis", sql: "SELECT (1)DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a no-break space", sql: "SELECT 1\u{00A0}DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "an ideographic space", sql: "SELECT 1\u{3000}DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a zero-width space", sql: "SELECT 1\u{200B}DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a line separator", sql: "SELECT 1\u{2028}DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a vertical tab", sql: "SELECT 1\u{0B}DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a control character", sql: "SELECT 1\u{01}DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "an EXEC after a read", sql: "SELECT 1 EXEC('DELETE FROM \(canary)')", hidden: "EXEC"),
        Case(name: "a MERGE after a read",
             sql: "SELECT 1 MERGE \(canary) AS t USING (SELECT 1 AS id) AS s ON t.id = s.id WHEN MATCHED THEN DELETE;",
             hidden: "MERGE"),
        Case(name: "a DELETE inside an INSERT",
             sql: "INSERT INTO dbo.unterminated_log SELECT id FROM (DELETE FROM \(canary) OUTPUT deleted.id) AS d",
             hidden: "DELETE"),
        Case(name: "an UPDATE of a bracketed name", sql: "SELECT 1\nUPDATE [unterminated_canary] SET id = 9",
             hidden: "UPDATE"),
        Case(name: "an UPDATE of a quoted name", sql: "SELECT 1\nUPDATE \"unterminated_canary\" SET id = 9",
             hidden: "UPDATE"),
        Case(name: "an UPDATE of a bracketed name with SET on its own line",
             sql: "SELECT 1\nUPDATE [unterminated_canary]\nSET id = 9", hidden: "UPDATE"),
        Case(name: "an UPDATE of a bracketed name after PRINT", sql: "PRINT 1\nUPDATE [unterminated_canary] SET id = 9",
             hidden: "UPDATE"),
        Case(name: "a SELECT INTO of bracketed columns after PRINT",
             sql: "PRINT 1\nSELECT [id], [id] AS b INTO \(intoTable) FROM \(canary)", hidden: "SELECT"),
        Case(name: "a SELECT INTO of quoted columns after PRINT",
             sql: "PRINT 1\nSELECT \"id\", id AS b INTO \(intoTable) FROM \(canary)", hidden: "SELECT"),
        Case(name: "a hex literal", sql: "SELECT 0xDELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a hex literal with a digit", sql: "SELECT 0x1DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "an alias after a number", sql: "SELECT 1xDELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "an underscore", sql: "SELECT 1_DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a dollar in a name", sql: "SELECT 1 a$DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a hash in a name", sql: "SELECT 1 a#DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "an at sign in a name", sql: "SELECT 1 a@DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a letter outside ASCII", sql: "SELECT 1 \u{00E9}DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a letter number", sql: "SELECT 1 \u{2170}DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a Kelvin sign", sql: "SELECT 1 \u{212A}DELETE FROM \(canary)", hidden: "DELETE"),
        Case(name: "a fullwidth keyword", sql: "SELECT 1 \u{FF24}\u{FF25}\u{FF2C}\u{FF25}\u{FF34}\u{FF25} FROM \(canary)",
             hidden: "DELETE"),
        Case(name: "a dotless i", sql: "SELECT 1 \u{0131}nsert INTO \(canary) VALUES (9)", hidden: "INSERT"),
        Case(name: "a long s", sql: "SELECT 1 \u{0131}n\u{017F}ert INTO \(canary) VALUES (9)", hidden: "INSERT"),
        Case(name: "an EXEC glued to an exponent", sql: "SELECT 1EXEC('DELETE FROM \(canary)')", hidden: "EXEC"),
        Case(name: "an EXEC glued to a decimal exponent", sql: "SELECT 1.EXEC('DELETE FROM \(canary)')",
             hidden: "EXEC"),
        Case(name: "a string", sql: "SELECT 'DELETE FROM \(canary)'", hidden: "DELETE"),
        Case(name: "a bracketed name", sql: "SELECT [DELETE] FROM \(canary)", hidden: "DELETE"),
        Case(name: "a procedure body",
             sql: "CREATE OR ALTER PROCEDURE dbo.unterminated_p AS SELECT 1 DELETE FROM \(canary)",
             hidden: "DELETE"),
        Case(name: "a function body",
             sql: "CREATE OR ALTER FUNCTION dbo.unterminated_f() RETURNS int AS BEGIN RETURN 1 END DELETE FROM \(canary)",
             hidden: "DELETE"),
    ]

    static let reset = """
        IF OBJECT_ID(N'dbo.unterminated_canary') IS NULL CREATE TABLE dbo.unterminated_canary (id INT);
        IF OBJECT_ID(N'dbo.unterminated_log') IS NULL CREATE TABLE dbo.unterminated_log (id INT);
        IF OBJECT_ID(N'dbo.unterminated_p') IS NOT NULL DROP PROCEDURE dbo.unterminated_p;
        IF OBJECT_ID(N'dbo.unterminated_f') IS NOT NULL DROP FUNCTION dbo.unterminated_f;
        IF TYPE_ID(N'dbo.unterminated_t') IS NOT NULL DROP TYPE dbo.unterminated_t;
        IF OBJECT_ID(N'dbo.unterminated_into') IS NOT NULL DROP TABLE dbo.unterminated_into;
        DELETE FROM dbo.unterminated_canary;
        INSERT INTO dbo.unterminated_canary VALUES (1), (2), (3);
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

    static func readerSees(_ hidden: String, in sql: String) -> Bool {
        SQLStatementScanner.executableStatements(in: sql, grammar: grammar).contains { statement in
            SQLUnterminatedStatements.runnable(in: statement.sql, grammar: grammar).dropFirst().contains {
                StatementBlank.trimming($0).uppercased().hasPrefix(hidden)
            }
        }
    }

    static func canaryState(_ driver: MSSQLPluginDriver) async throws -> String {
        let result = try await driver.execute(
            query: "SELECT CONCAT(COUNT(*), ':', SUM(id), ':', OBJECT_ID(N'\(intoTable)')) AS state FROM \(canary)"
        )
        return result.rows.first?.first?.asText ?? "?"
    }

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let database = ProcessInfo.processInfo.environment["TP_CHECK_DATABASE"] ?? "tablepro_unterminated_check"
        var failures = 0
        var conservative = 0
        do {
            let admin = try await connect("master")
            _ = try await admin.execute(query: "IF DB_ID(N'\(database)') IS NULL CREATE DATABASE [\(database)]")
            admin.disconnect()

            let driver = try await connect(database)
            for check in cases {
                _ = try await driver.executeBatch(query: reset, rowCap: nil, parameters: nil)
                let before = try await canaryState(driver)
                _ = try? await driver.execute(query: check.sql)
                let ran = try await canaryState(driver) != before
                let reader = readerSees(check.hidden, in: check.sql)
                let gate = SQLWriteClassifier.isWriteQuery(check.sql, databaseType: .mssql)
                if ran, reader, gate {
                    print("ok   the server ran the \(check.hidden) and the gate saw it: \(check.name)")
                } else if ran {
                    failures += 1
                    print("FAIL the server ran the \(check.hidden), reader \(reader), gate \(gate): \(check.name)")
                } else if reader {
                    conservative += 1
                    print("ok   the server ran nothing and the reader split it anyway: \(check.name)")
                } else {
                    print("ok   the server ran nothing and the reader split nothing: \(check.name)")
                }
            }
            _ = try await driver.executeBatch(query: reset, rowCap: nil, parameters: nil)
            _ = try await driver.executeBatch(
                query: "DROP TABLE dbo.unterminated_canary; DROP TABLE dbo.unterminated_log;",
                rowCap: nil,
                parameters: nil
            )
            driver.disconnect()
        } catch {
            failures += 1
            print("FAIL: unexpected error \(error)")
        }
        print("\(cases.count) checks, \(failures) failure(s), \(conservative) read conservatively.")
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
