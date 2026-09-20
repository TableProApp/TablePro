#!/usr/bin/env bash
#
# Prove that no Oracle dictionary read or system-package call the app issues can be captured by an
# object a user plants to shadow a SYS name.
#
# Oracle resolves an unqualified name to an object in the session's current schema before the public
# synonym for the real SYS object, so a user who owns the current schema, or a schema the reader has
# switched into, can plant a table, view or package of the same name. A bare dictionary read then
# returns spoofed rows or runs an attacker's code (a BEQUEATH CURRENT_USER view, or a package the
# call reaches) with the reader's privileges. This shadow in the probe's OWN schema is the same
# object resolution a cross-schema `ALTER SESSION SET CURRENT_SCHEMA` produces: in both cases the
# name resolves against the current schema, so planting it here reproduces the cross-schema attack
# through the exact OracleCoreConnection path the plugin uses.
#
# The cross-schema form driven by `ALTER SESSION SET CURRENT_SCHEMA` cannot be exercised through the
# driver while the pinned oracle-nio hangs on that statement (the nio PR fixes it); the resolution
# it relies on is the one this script proves. `scripts/check-oracle-plsql-terminators.sh` is the
# sibling that models the driver-probe shape.
#
# Usage:
#   scripts/check-oracle-name-resolution.sh [host] [port] [service] [user] [password]
#
# Defaults suit a throwaway Oracle Free container:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# The user needs CREATE TABLE, CREATE VIEW, CREATE TYPE and CREATE PROCEDURE. Every object it
# creates is prefixed TP_NR_, or is a shadow named for a SYS object, and all are dropped again.
# Exits non-zero when anything is captured, 3 when a prerequisite is missing.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1521}"
SERVICE="${3:-FREEPDB1}"
USER_NAME="${4:-probe}"
PASSWORD="${5:-probe_pw}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
let connection = OracleCoreConnection(options: OracleConnectionOptions(
    host: arguments[1], port: Int(arguments[2]) ?? 1_521, user: arguments[4], password: arguments[5],
    identifierMode: .service, serviceName: arguments[3]
))

do {
    try await connection.connect()
} catch {
    print("cannot connect: \(error)")
    exit(3)
}
connection.applyQueryTimeout(30)

@discardableResult
func run(_ sql: String) async -> String? {
    do {
        _ = try await connection.executeQuery(sql)
        return nil
    } catch {
        return String(describing: error)
    }
}

func rows(_ sql: String) async -> [[String?]] {
    ((try? await connection.executeQuery(sql).rows) ?? []).map { row in row.map { $0.stringValue } }
}

func scalar(_ sql: String) async -> String? {
    await rows(sql).first?.first ?? nil
}

// The current schema, which the shadows below are planted in and the reads resolve against.
let schema = (await scalar(OracleSchemaQueries.currentSchema)) ?? arguments[4].uppercased()

let teardown = [
    "DROP TABLE TP_NR_REAL PURGE", "DROP TABLE HITS PURGE", "DROP TABLE ALL_TABLES PURGE",
    "DROP VIEW ALL_TAB_COLUMNS", "DROP PACKAGE SYS", "DROP TYPE TP_NR_PKG FORCE",
    "DROP FUNCTION TP_NR_PAYLOAD"
]
for sql in teardown { await run(sql) }

// A real table the reads should still see, and a hit table any captured code writes to.
guard await run("CREATE TABLE TP_NR_REAL (ID NUMBER, NAME VARCHAR2(20))") == nil,
      await run("CREATE TABLE HITS (WHAT VARCHAR2(200))") == nil else {
    print("cannot create probe tables (needs CREATE TABLE)")
    exit(3)
}
await run("INSERT INTO TP_NR_REAL VALUES (1, 'real')")
await run("COMMIT")

// SQL-level shadows: a table shadowing ALL_TABLES, and a BEQUEATH CURRENT_USER view shadowing
// ALL_TAB_COLUMNS that runs a payload when it is read.
await run("CREATE TABLE ALL_TABLES (OWNER VARCHAR2(128), TABLE_NAME VARCHAR2(128), TABLE_TYPE VARCHAR2(20))")
await run("INSERT INTO ALL_TABLES VALUES ('\(schema)', 'TP_NR_SPOOFED', 'TABLE')")
await run("COMMIT")
await run("""
CREATE OR REPLACE FUNCTION TP_NR_PAYLOAD RETURN VARCHAR2 AUTHID CURRENT_USER IS
  PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
  INSERT INTO HITS VALUES ('ALL_TAB_COLUMNS view payload ran'); COMMIT; RETURN 'N';
END;
""")
await run("""
CREATE OR REPLACE VIEW ALL_TAB_COLUMNS BEQUEATH CURRENT_USER AS
  SELECT '\(schema)' AS OWNER, 'T' AS TABLE_NAME, 'C' AS COLUMN_NAME, 'NUMBER' AS DATA_TYPE,
         22 AS DATA_LENGTH, NULL AS DATA_PRECISION, NULL AS DATA_SCALE, TP_NR_PAYLOAD() AS NULLABLE,
         1 AS COLUMN_ID
  FROM SYS.DUAL
""")

// A package named SYS holding object-type members, which captures SYS.DBMS_OUTPUT and
// SYS.DBMS_DATAPUMP when they are named inside a PL/SQL block.
await run("""
CREATE OR REPLACE TYPE TP_NR_PKG AUTHID CURRENT_USER AS OBJECT (
  KU$_FILE_TYPE_LOG_FILE NUMBER,
  MEMBER FUNCTION OPEN(operation VARCHAR2, job_mode VARCHAR2, remote_link VARCHAR2, job_name VARCHAR2) RETURN NUMBER,
  MEMBER PROCEDURE ADD_FILE(handle NUMBER, filename VARCHAR2, directory VARCHAR2, filesize VARCHAR2 DEFAULT NULL, filetype NUMBER DEFAULT NULL),
  MEMBER PROCEDURE METADATA_FILTER(handle NUMBER, name VARCHAR2, value VARCHAR2),
  MEMBER PROCEDURE START_JOB(handle NUMBER),
  MEMBER PROCEDURE DETACH(handle NUMBER),
  MEMBER PROCEDURE ENABLE(buffer_size INTEGER DEFAULT NULL),
  MEMBER PROCEDURE DISABLE,
  MEMBER PROCEDURE GET_LINE(line OUT VARCHAR2, status OUT INTEGER),
  MEMBER PROCEDURE PUT_LINE(a VARCHAR2)
)
""")
await run("""
CREATE OR REPLACE TYPE BODY TP_NR_PKG AS
  MEMBER FUNCTION OPEN(operation VARCHAR2, job_mode VARCHAR2, remote_link VARCHAR2, job_name VARCHAR2) RETURN NUMBER IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO HITS VALUES ('SYS.DBMS_DATAPUMP.OPEN captured'); COMMIT; RETURN 7; END;
  MEMBER PROCEDURE ADD_FILE(handle NUMBER, filename VARCHAR2, directory VARCHAR2, filesize VARCHAR2 DEFAULT NULL, filetype NUMBER DEFAULT NULL) IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO HITS VALUES ('SYS.DBMS_DATAPUMP.ADD_FILE captured'); COMMIT; END;
  MEMBER PROCEDURE METADATA_FILTER(handle NUMBER, name VARCHAR2, value VARCHAR2) IS BEGIN NULL; END;
  MEMBER PROCEDURE START_JOB(handle NUMBER) IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO HITS VALUES ('SYS.DBMS_DATAPUMP.START_JOB captured'); COMMIT; END;
  MEMBER PROCEDURE DETACH(handle NUMBER) IS BEGIN NULL; END;
  MEMBER PROCEDURE ENABLE(buffer_size INTEGER DEFAULT NULL) IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO HITS VALUES ('SYS.DBMS_OUTPUT.ENABLE captured'); COMMIT; END;
  MEMBER PROCEDURE DISABLE IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO HITS VALUES ('SYS.DBMS_OUTPUT.DISABLE captured'); COMMIT; END;
  MEMBER PROCEDURE GET_LINE(line OUT VARCHAR2, status OUT INTEGER) IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO HITS VALUES ('SYS.DBMS_OUTPUT.GET_LINE captured'); COMMIT; line := 'SPOOF'; status := 0; END;
  MEMBER PROCEDURE PUT_LINE(a VARCHAR2) IS BEGIN NULL; END;
END;
""")
await run("""
CREATE OR REPLACE PACKAGE SYS AUTHID CURRENT_USER AS
  DBMS_DATAPUMP TP_NR_PKG := TP_NR_PKG(3);
  DBMS_OUTPUT TP_NR_PKG := TP_NR_PKG(3);
END;
""")

func report(_ label: String, _ ok: Bool) -> Int {
    print("\(ok ? "ok  " : "FAIL") \(label)")
    return ok ? 0 : 1
}

var failures = 0

// The app's reads must return the real dictionary, not the shadow, and run none of the payload.
_ = await scalar(OracleSchemaQueries.serverVersion)
_ = await rows(OracleSchemaQueries.users)
let tables = await rows(OracleSchemaQueries.tables(schema: schema)).compactMap { $0.first ?? nil }
failures += report("tables() returns the real table, not the spoof",
                   tables.contains("TP_NR_REAL") && !tables.contains("TP_NR_SPOOFED"))
_ = await rows(OracleSchemaQueries.columns(schema: schema, table: "TP_NR_REAL"))
_ = await rows(OracleSchemaQueries.allColumns(schema: schema))
_ = await rows(OracleSchemaQueries.foreignKeys(schema: schema, table: "TP_NR_REAL"))
_ = await rows(OracleSchemaQueries.indexes(schema: schema, table: "TP_NR_REAL"))

// DBMS_OUTPUT enable, print, and drain, the path #2990 added.
do {
    try await connection.captureServerOutput()
    _ = try await connection.executeQuery("BEGIN DBMS_OUTPUT.PUT_LINE('probe line'); END;")
    let output = try await connection.drainServerOutput(maxLines: 100)
    failures += report("drainServerOutput returns the real line", output.lines == ["probe line"])
} catch {
    failures += report("DBMS_OUTPUT enable/drain ran", false)
    print("     \(error)")
}

// A server-side export block of the shape ServerSideExport builds (name-free, CALL-based).
let export = """
DECLARE
  handle NUMBER;
BEGIN
  EXECUTE IMMEDIATE 'CALL SYS.DBMS_DATAPUMP.OPEN(:1, :2, NULL, :3) INTO :4' USING 'EXPORT', 'TABLE', 'TP_NR_JOB', OUT handle;
  EXECUTE IMMEDIATE 'CALL SYS.DBMS_DATAPUMP.DETACH(:1)' USING handle;
EXCEPTION WHEN OTHERS THEN NULL;
END;
"""
_ = await run(export)

let hits = await rows("SELECT WHAT FROM HITS")
failures += report("no SYS shadow was captured (hit table is empty)", hits.isEmpty)
for hit in hits { print("     captured: \(hit.first ?? nil ?? "")") }

for sql in teardown { await run(sql) }
await run("COMMIT")

print(failures == 0 ? "No dictionary read or system-package call was captured." : "\(failures) capture(s).")
exit(failures == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$SERVICE" "$USER_NAME" "$PASSWORD" 2> /dev/null
