#!/usr/bin/env bash
#
# Check that every Oracle column type reads back as it was declared, and that its values read back as stored.
#
# OracleColumnTypeSpelling rebuilds a declared type from ALL_TAB_COLS by a rule measured once on 23ai: DATA_LENGTH
# is bytes, so the character types take CHAR_LENGTH and CHAR_USED; TIMESTAMP and INTERVAL carry their precision in
# DATA_TYPE; FLOAT reports binary digits; NUMBER(*,s) has no precision; object types need DATA_TYPE_OWNER and
# DATA_TYPE_MOD. A wrong rule is silent: the Structure tab shows another type, and DDL, copy and export recreate
# another column. So this creates one column of each shape, reads it through the same OracleCoreConnection and
# OracleSchemaQueries the app uses, creates a second column from the spelling the app produced, and compares the two
# dictionary rows. It then reads a value of each type whose text the core builds from the wire bytes.
#
# Usage:
#   scripts/probes/check-oracle-type-roundtrip.sh [host] [port] [service] [user] [password]
#
# Defaults suit a throwaway Oracle Free container:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# The user needs CREATE TABLE and CREATE TYPE. Every object it creates is prefixed TP_TYPES_ and dropped again.
# Exits non-zero on a disagreement, 3 when a prerequisite is missing.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1521}"
SERVICE="${3:-FREEPDB1}"
USER_NAME="${4:-probe}"
PASSWORD="${5:-probe_pw}"
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
guard let release = connection.serverRelease else {
    print("the login reply carried no server release")
    exit(3)
}
print("Oracle \(release.major).\(release.update)")

var disagreements = 0

@MainActor
func check(_ holds: Bool, _ claim: String) {
    print("\(holds ? "ok  " : "FAIL") \(claim)")
    if !holds { disagreements += 1 }
}

func run(_ sql: String) async -> String? {
    do {
        _ = try await connection.executeQuery(sql)
        return nil
    } catch {
        return String(describing: error)
    }
}

@MainActor
func result(_ sql: String) async -> OracleRawResult? {
    do {
        return try await connection.executeQuery(sql)
    } catch {
        print("FAIL \(sql.prefix(80)): \(error)")
        disagreements += 1
        return nil
    }
}

let schema = await result(OracleSchemaQueries.currentSchema)?.rows.first?.first?.stringValue ?? arguments[4].uppercased()

var declared = [
    "NVARCHAR2(100)", "NCHAR(10)", "NCHAR", "VARCHAR2(50 CHAR)", "VARCHAR2(50 BYTE)", "CHAR(10 CHAR)", "CHAR",
    "NUMBER", "NUMBER(10)", "NUMBER(10,2)", "NUMBER(*,2)", "NUMBER(5,-2)", "INTEGER", "FLOAT", "FLOAT(10)", "REAL",
    "BINARY_FLOAT", "BINARY_DOUBLE", "DATE", "TIMESTAMP", "TIMESTAMP(0)", "TIMESTAMP(9) WITH TIME ZONE",
    "TIMESTAMP WITH LOCAL TIME ZONE", "INTERVAL YEAR(4) TO MONTH", "INTERVAL DAY(3) TO SECOND(0)", "RAW(16)", "BLOB",
    "CLOB", "NCLOB", "BFILE", "ROWID", "UROWID", "UROWID(100)", "XMLTYPE", "TP_TYPES_OBJ", "REF TP_TYPES_OBJ",
]
if release.major >= 21 { declared.append("JSON") }
if release.major >= 23 { declared += ["BOOLEAN", "VECTOR", "VECTOR(3, FLOAT32)"] }

_ = await run("DROP TABLE TP_TYPES_T PURGE")
_ = await run("DROP TABLE TP_TYPES_R PURGE")
_ = await run("DROP TYPE TP_TYPES_OBJ FORCE")
if let failure = await run("CREATE TYPE TP_TYPES_OBJ AS OBJECT (A NUMBER)") {
    print("cannot create TP_TYPES_OBJ: \(failure)")
    exit(3)
}

func dictionaryRow(_ table: String, _ column: String) async -> [String?] {
    let vectorInfo = release.hasVectorInfo ? "VECTOR_INFO" : "NULL"
    let sql = """
        SELECT DATA_TYPE, DATA_TYPE_MOD, DATA_TYPE_OWNER, DATA_LENGTH, DATA_PRECISION, DATA_SCALE, CHAR_LENGTH,
               CHAR_USED, \(vectorInfo)
        FROM USER_TAB_COLS WHERE TABLE_NAME = '\(table)' AND COLUMN_NAME = '\(column)'
        """
    return await result(sql)?.rows.first?.map(\.stringValue) ?? []
}

print("\nDeclared types")
for (index, type) in declared.enumerated() {
    let column = "C\(index)"
    _ = await run("DROP TABLE TP_TYPES_T PURGE")
    if let failure = await run("CREATE TABLE TP_TYPES_T (\(column) \(type))") {
        print("skip \(type): \(failure.prefix(80))")
        continue
    }
    let read = await result(OracleSchemaQueries.columns(schema: schema, table: "TP_TYPES_T", release: release))?
        .rows.compactMap(OracleSchemaQueries.parseColumnRow).first
    guard let spelling = read?.displayType else {
        check(false, "\(type) reads back")
        continue
    }
    _ = await run("DROP TABLE TP_TYPES_R PURGE")
    if let failure = await run("CREATE TABLE TP_TYPES_R (\(column) \(spelling))") {
        check(false, "\(type) reads back as \(spelling), which fails: \(failure.prefix(80))")
        continue
    }
    let original = await dictionaryRow("TP_TYPES_T", column)
    let recreated = await dictionaryRow("TP_TYPES_R", column)
    check(original == recreated, "\(type) reads back as \(spelling) and recreates the same column")
}
_ = await run("DROP TABLE TP_TYPES_R PURGE")

print("\nValues")
_ = await run("DROP TABLE TP_TYPES_T PURGE")
_ = await run("""
    CREATE TABLE TP_TYPES_T (
      D DATE, T6 TIMESTAMP(6), T0 TIMESTAMP(0), TZ TIMESTAMP(6) WITH TIME ZONE, N NCHAR(3), U UROWID, B CLOB
    )
    """)
_ = await run("""
    INSERT INTO TP_TYPES_T VALUES (
      TO_DATE('2026-10-06 15:22:20', 'YYYY-MM-DD HH24:MI:SS'),
      TO_TIMESTAMP('2026-10-06 15:22:20.050000', 'YYYY-MM-DD HH24:MI:SS.FF'),
      TO_TIMESTAMP('2026-10-06 15:22:20', 'YYYY-MM-DD HH24:MI:SS'),
      TO_TIMESTAMP_TZ('2026-10-06 15:22:20.000001 -05:30', 'YYYY-MM-DD HH24:MI:SS.FF TZH:TZM'),
      N'ab', NULL, 'clob text'
    )
    """)
_ = await run("UPDATE TP_TYPES_T SET U = ROWID")
let expectedText: [String: String] = [
    "D": "2026-10-06 15:22:20", "T6": "2026-10-06 15:22:20.050000", "T0": "2026-10-06 15:22:20",
    "TZ": "2026-10-06 15:22:20.000001-05:30", "N": "ab ", "B": "clob text",
]
if let values = await result("SELECT D, T6, T0, TZ, N, U, B FROM TP_TYPES_T") {
    for (index, column) in values.columns.enumerated() {
        let text = values.rows.first?[index].stringValue
        if let expected = expectedText[column.name] {
            check(text == expected, "\(column.name) (\(column.typeName)) reads \(String(reflecting: text))")
        } else {
            check(text?.isEmpty == false, "\(column.name) (\(column.typeName)) reads \(String(reflecting: text))")
        }
    }
    check(values.columns.last?.typeName == "clob", "a CLOB column is typed clob, not long")
}
if release.major >= 21 {
    let json = await result("SELECT JSON('{\"b\":1,\"a\":[2,3]}') FROM DUAL")?.rows.first?.first?.stringValue
    check(json == "{\"b\":1,\"a\":[2,3]}", "JSON reads as its text in stored order: \(String(reflecting: json))")
}
let empty = await result("SELECT D, N FROM TP_TYPES_T WHERE 1 = 0")
check(empty?.columns.map(\.name) == ["D", "N"], "an empty result keeps its own columns: \(empty?.columns.map(\.name) ?? [])")

_ = await run("DROP TABLE TP_TYPES_T PURGE")
_ = await run("DROP TYPE TP_TYPES_OBJ FORCE")
print(disagreements == 0 ? "\nall checks hold" : "\n\(disagreements) disagreement(s)")
exit(disagreements == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$SERVICE" "$USER_NAME" "$PASSWORD" 2> /dev/null
