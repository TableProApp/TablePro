#!/usr/bin/env bash
#
# Check that values too long for one length byte travel both ways against a real Oracle server.
#
# A value over 252 bytes goes on the wire in chunks, and the server decides how each chunk gives its length: a UB4
# when it sets the big-chunk compile capability (12c and later), one byte when it does not (11.2). Getting it wrong
# is silent until a long value shows up, then the session hangs: 11.2 waits for the rest of a statement that never
# comes, or the driver waits for the rest of a row the server already sent (#4629). So this sends and reads every
# kind of long value the app uses through OracleCoreConnection: statement text, VARCHAR2, NVARCHAR2, LONG and CLOB
# reads, text and raw binds, a long error message, a long DBMS_OUTPUT line, a long view text and a check's condition.
#
# Usage:
#   TP_ORACLE_PASSWORD=<password> scripts/probes/check-oracle-long-values.sh [host] [port] [service-or-sid] [user] [service|sid]
#
# Defaults suit a throwaway Oracle Free container. For 11.2, the oracle-xe:11 image and its SID:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#   docker run -d --platform linux/amd64 --name oracle11-probe -p 1522:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-xe:11-slim
#   scripts/probes/check-oracle-long-values.sh 127.0.0.1 1522 XE probe sid
#
# The password comes from TP_ORACLE_PASSWORD (default probe_pw), never the command line, which other users can read.
#
# ORACLE_NIO_CHECKOUT=<path> builds against a local oracle-nio checkout instead of the pinned revision.
# The user needs CREATE TABLE, CREATE VIEW and CREATE TRIGGER. Every object it creates is prefixed TP_LONGV_ and
# dropped again.
# Exits non-zero on a disagreement, 3 when a prerequisite is missing.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1521}"
SERVICE="${3:-FREEPDB1}"
USER_NAME="${4:-probe}"
MODE="${5:-service}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/Probe"

cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProOracle")],
    targets: [
        .executableTarget(
            name: "Probe",
            dependencies: [.product(name: "TableProOracleCore", package: "TableProOracle")]
        )
    ]
)
EOF

cat > "$WORK/Sources/Probe/main.swift" <<'EOF'
import Foundation
import TableProOracleCore

let arguments = CommandLine.arguments
let usesSID = arguments[5] == "sid"
let connection = OracleCoreConnection(options: OracleConnectionOptions(
    host: arguments[1], port: Int(arguments[2]) ?? 1_521, user: arguments[4],
    password: ProcessInfo.processInfo.environment["TP_ORACLE_PASSWORD"] ?? "probe_pw",
    identifierMode: usesSID ? .sid : .service,
    serviceName: usesSID ? "" : arguments[3],
    sid: usesSID ? arguments[3] : ""
))

do {
    try await connection.connect()
} catch {
    print("cannot connect: \(error)")
    exit(3)
}
// A framing mismatch hangs rather than fails, so every statement gets a deadline.
connection.applyQueryTimeout(30)
print("Oracle \(connection.serverRelease.map { String($0.major) } ?? "?")")

var disagreements = 0

@MainActor
func check(_ holds: Bool, _ claim: String) {
    print("\(holds ? "ok  " : "FAIL") \(claim)")
    if !holds { disagreements += 1 }
}

func run(_ sql: String, binds: [OracleBindValue] = []) async -> Result<OracleRawResult, Error> {
    do {
        return .success(try await connection.executeQuery(sql, binds: binds))
    } catch {
        return .failure(error)
    }
}

// The first cell of the first row; no row fails the claim, so a skipped read cannot pass.
@MainActor
func value(_ sql: String, binds: [OracleBindValue] = [], _ claim: String) async -> OracleRawCell? {
    switch await run(sql, binds: binds) {
    case .success(let result):
        guard let cell = result.rows.first?.first else {
            check(false, "\(claim): no row")
            return nil
        }
        return cell
    case .failure(let error):
        check(false, "\(claim): \(error)")
        return nil
    }
}

// A statement the checks after it depend on.
@MainActor
func setUp(_ sql: String, binds: [OracleBindValue] = [], _ claim: String) async {
    if case .failure(let error) = await run(sql, binds: binds) {
        check(false, "\(claim): \(error)")
    }
}

func text(_ count: Int, _ unit: String) -> String {
    String(repeating: unit, count: count)
}

let padding = text(40_000, "x")
let longStatement = "SELECT 'statement' FROM dual /* \(padding) */"
if let cell = await value(longStatement, "a 40 KB statement") {
    check(cell.stringValue == "statement", "a 40 KB statement runs")
}

if let cell = await value("SELECT RPAD('v', 4000, 'v') FROM dual", "a 4,000-byte VARCHAR2") {
    check(cell.stringValue == text(4_000, "v"), "a 4,000-byte VARCHAR2 reads whole")
}
if let cell = await value("SELECT RPAD(UNISTR('\\00e9'), 1000, UNISTR('\\00e9')) FROM dual", "a multi-byte VARCHAR2") {
    check(cell.stringValue == text(1_000, "é"), "1,000 two-byte characters read whole")
}
if let cell = await value("SELECT TO_NCHAR(RPAD('n', 1000, 'n')) FROM dual", "a long NVARCHAR2") {
    check(cell.stringValue == text(1_000, "n"), "a 1,000-character NVARCHAR2 reads whole")
}

let shortText = text(1_500, "c")
if let cell = await value("SELECT :1 FROM dual", binds: [.text(shortText)], "a 1,500-byte CHAR bind") {
    check(cell.stringValue == shortText, "a 1,500-byte text bind comes back whole")
}
let varcharText = text(3_000, "d")
if let cell = await value("SELECT :1 FROM dual", binds: [.text(varcharText)], "a 3,000-byte VARCHAR2 bind") {
    check(cell.stringValue == varcharText, "a 3,000-byte text bind comes back whole")
}
let rawBytes = Data((0..<1_000).map { UInt8($0 % 256) })
if let cell = await value("SELECT :1 FROM dual", binds: [.bytes(rawBytes)], "a 1,000-byte RAW bind") {
    if case .bytes(let data) = cell {
        check(data == rawBytes, "a 1,000-byte RAW bind comes back whole")
    } else {
        check(false, "a 1,000-byte RAW bind comes back as bytes: \(cell)")
    }
}

_ = await run("DROP TABLE TP_LONGV_T PURGE")
let longValue = text(100_000, "L")
if case .failure(let error) = await run("CREATE TABLE TP_LONGV_T (ID NUMBER, L LONG)") {
    print("cannot create TP_LONGV_T: \(error)")
    exit(3)
}
await setUp("INSERT INTO TP_LONGV_T (ID, L) VALUES (1, :1)", binds: [.text(longValue)], "a 100,000-byte bind into a LONG")
if let cell = await value("SELECT L FROM TP_LONGV_T WHERE ID = 1", "a 100,000-byte LONG") {
    check(cell.stringValue == longValue, "a 100,000-byte LONG written by bind reads back whole")
}
_ = await run("DROP TABLE TP_LONGV_T PURGE")

_ = await run("DROP TABLE TP_LONGV_C PURGE")
await setUp("CREATE TABLE TP_LONGV_C (ID NUMBER, C CLOB, N NCLOB, B BLOB)", "creating TP_LONGV_C")
await setUp("INSERT INTO TP_LONGV_C (ID, C) VALUES (1, :1)", binds: [.text(longValue)], "a 100,000-byte bind into a CLOB")
if let cell = await value("SELECT C FROM TP_LONGV_C WHERE ID = 1", "a 100,000-byte CLOB") {
    check(cell.stringValue == longValue, "a 100,000-byte CLOB reads back whole")
}
await setUp("INSERT INTO TP_LONGV_C (ID, C, N, B) VALUES (2, NULL, NULL, NULL)", "inserting NULL LOBs")
await setUp("INSERT INTO TP_LONGV_C (ID, C, N, B) VALUES (3, EMPTY_CLOB(), EMPTY_CLOB(), EMPTY_BLOB())", "inserting empty LOBs")
await setUp("INSERT INTO TP_LONGV_C (ID, C, N, B) VALUES (4, 'c', 'n', HEXTORAW('0B'))", "inserting short LOBs")
switch await run("SELECT ID, C, N, B FROM TP_LONGV_C WHERE ID > 1 ORDER BY ID") {
case .success(let result):
    let cells = result.rows.map { Array($0.dropFirst()) }
    let expected: [[OracleRawCell]] = [
        [.null, .null, .null], [.null, .null, .null], [.string("c"), .string("n"), .bytes(Data([0x0B]))],
    ]
    check(cells == expected, "NULL, empty and short CLOB, NCLOB and BLOB columns read")
case .failure(let error):
    check(false, "NULL, empty and short CLOB, NCLOB and BLOB columns read: \(error)")
}
_ = await run("DROP TABLE TP_LONGV_C PURGE")

_ = await run("DROP TABLE TP_LONGV_G PURGE")
await setUp("CREATE TABLE TP_LONGV_G (ID NUMBER)", "creating TP_LONGV_G")
let triggerBody = "BEGIN\n" + (1...60).map { "  NULL; -- line \($0) of a body long enough to be chunked" }.joined(separator: "\n")
    + "\nEND;"
await setUp("CREATE OR REPLACE TRIGGER TP_LONGV_G_BI BEFORE INSERT ON TP_LONGV_G\n\(triggerBody)", "creating the trigger")
let triggerList = """
    SELECT
        TRIGGER_NAME,
        TABLE_NAME,
        OWNER,
        TRIGGER_TYPE,
        TRIGGERING_EVENT,
        STATUS,
        WHEN_CLAUSE,
        DESCRIPTION,
        ACTION_TYPE,
        TABLE_OWNER,
        TRIGGER_BODY
    FROM SYS.ALL_TRIGGERS
    WHERE TRIGGER_NAME = 'TP_LONGV_G_BI'
    ORDER BY TABLE_NAME, TRIGGER_NAME
    """
switch await run(triggerList) {
case .success(let result):
    let body = result.rows.first?.last?.stringValue ?? ""
    check(body.contains("line 60 of a body"), "the sidebar's trigger read returns the whole LONG body (\(body.utf8.count) bytes)")
case .failure(let error):
    check(false, "the sidebar's trigger read: \(error)")
}
_ = await run("DROP TABLE TP_LONGV_G PURGE")

_ = await run("DROP TABLE TP_LONGV_K PURGE")
await setUp("CREATE TABLE TP_LONGV_K (A NUMBER, B NUMBER, CONSTRAINT TP_LONGV_K_PK PRIMARY KEY (A, B), "
    + "CONSTRAINT TP_LONGV_K_CK CHECK (A > 0 AND B > 0))", "creating TP_LONGV_K")
switch await run(OracleSchemaQueries.tableConstraints(schema: arguments[4].uppercased(), table: "TP_LONGV_K")) {
case .success(let result):
    let constraints = OracleSchemaQueries.parseTableConstraints(result.rows)
    check(constraints.map(\.name) == ["TP_LONGV_K_PK", "TP_LONGV_K_CK"]
        && constraints.last?.condition == "A > 0 AND B > 0", "keys and checks read with their whole condition")
case .failure(let error):
    check(false, "the table constraint read: \(error)")
}
switch await run(OracleSchemaQueries.viewDefinition(schema: arguments[4].uppercased(), view: "TP_LONGV_K")) {
case .success(let result):
    check(result.rows.isEmpty, "a table read as a view returns no rows")
case .failure(let error):
    check(false, "a table read as a view: \(error)")
}
let viewColumns = (0..<900).map { "A AS COLUMN_WITH_A_LONG_NAME_\($0)" }.joined(separator: ", ")
await setUp("CREATE OR REPLACE VIEW TP_LONGV_V AS SELECT \(viewColumns) FROM TP_LONGV_K", "creating TP_LONGV_V")
let storedLength = await value(
    "SELECT TEXT_LENGTH FROM ALL_VIEWS WHERE VIEW_NAME = 'TP_LONGV_V' AND OWNER = USER", "the view's stored length"
)?.stringValue.flatMap { Int($0) }
if let cell = await value(
    OracleSchemaQueries.viewDefinition(schema: arguments[4].uppercased(), view: "TP_LONGV_V"), "a long view text"
) {
    let text = cell.stringValue ?? ""
    check(storedLength != nil && text.utf8.count == storedLength, "a \(text.utf8.count)-byte view text reads whole")
}
_ = await run("DROP VIEW TP_LONGV_V")
_ = await run("DROP TABLE TP_LONGV_K PURGE")

let message = text(1_800, "e")
switch await run("BEGIN RAISE_APPLICATION_ERROR(-20001, '\(message)'); END;") {
case .success:
    check(false, "a 1,800-byte error message is raised")
case .failure(let error):
    let described = String(describing: error)
    check(described.contains("20001") && described.contains(text(300, "e")), "a 1,800-byte error message reads whole")
}

do {
    try await connection.captureServerOutput()
    _ = try await connection.executeQuery("BEGIN DBMS_OUTPUT.PUT_LINE(RPAD('o', 3000, 'o')); END;")
    let output = try await connection.drainServerOutput(maxLines: 10)
    check(output.lines == [text(3_000, "o")], "a 3,000-byte DBMS_OUTPUT line reads whole")
} catch {
    check(false, "a 3,000-byte DBMS_OUTPUT line: \(error)")
}

if let cell = await value("SELECT 'still here' FROM dual", "the session after every check") {
    check(cell.stringValue == "still here", "the session still answers")
}

connection.disconnect()
print(disagreements == 0 ? "Long values travel both ways on this server." : "\(disagreements) disagreement(s).")
exit(disagreements == 0 ? 0 : 1)
EOF

if [ -n "${ORACLE_NIO_CHECKOUT:-}" ]; then
    (cd "$WORK" && swift package edit oracle-nio --path "$ORACLE_NIO_CHECKOUT" > "$WORK/edit.log" 2>&1) || {
        cat "$WORK/edit.log" >&2
        exit 3
    }
fi

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
TP_ORACLE_PASSWORD="${TP_ORACLE_PASSWORD:-probe_pw}" "$WORK/.build/debug/Probe" "$HOST" "$PORT" "$SERVICE" "$USER_NAME" "$MODE" 2> /dev/null
