#!/usr/bin/env bash
#
# Check that NCHAR, NVARCHAR2 and NCLOB text reads and writes back unchanged under the database's national character set.
#
# Oracle allows two national character sets. AL16UTF16 sends NCHAR values as UTF-16; UTF8 sends them as CESU-8, where a
# character outside the BMP is two 3-byte surrogates (measured on 23ai). oracle-nio converts CESU-8 to UTF-16 while it
# reads a row, so a wrong guess about either form shows up here as a failed statement or as mojibake. This reads Lao text
# and U+1D11E from each NCHAR type, a 20,008-character NCLOB that spans several wire chunks, and the same text written
# back as the quoted literal the grid saves and as a bind, all through the same OracleCoreConnection the app uses.
#
# Usage:
#   scripts/probes/check-oracle-national-charset.sh [host] [port] [service] [user] [password]
#
# Defaults suit a throwaway Oracle Free container, whose FREEPDB1 uses AL16UTF16:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# To check UTF8 as well, switch that throwaway PDB before creating anything in it (unsupported outside a test database):
#   docker exec -i oracle-probe sqlplus -s / as sysdba <<'SQL'
#   ALTER PLUGGABLE DATABASE FREEPDB1 CLOSE IMMEDIATE;
#   ALTER PLUGGABLE DATABASE FREEPDB1 OPEN RESTRICTED;
#   ALTER SESSION SET CONTAINER = FREEPDB1;
#   ALTER DATABASE NATIONAL CHARACTER SET INTERNAL_USE UTF8;
#   ALTER PLUGGABLE DATABASE FREEPDB1 CLOSE IMMEDIATE;
#   ALTER PLUGGABLE DATABASE FREEPDB1 OPEN;
#   SQL
#
# The writes send text as a plain literal or a CHAR or VARCHAR bind, which the server converts through the database
# character set, so a database character set without Lao fails the write checks. The user needs CREATE TABLE. Every object it creates is prefixed
# TP_NCHAR_ and dropped again. Exits non-zero on a disagreement, 3 when a prerequisite is missing.

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

var disagreements = 0

@MainActor
func check(_ holds: Bool, _ claim: String) {
    print("\(holds ? "ok  " : "FAIL") \(claim)")
    if !holds { disagreements += 1 }
}

@MainActor
func result(_ sql: String, binds: [OracleBindValue] = []) async -> OracleRawResult? {
    do {
        return try await connection.executeQuery(sql, binds: binds)
    } catch {
        print("FAIL \(sql.prefix(80)): \(error)")
        disagreements += 1
        return nil
    }
}

func run(_ sql: String) async {
    _ = try? await connection.executeQuery(sql)
}

let charsets = await result("""
    SELECT parameter, value FROM nls_database_parameters
    WHERE parameter IN ('NLS_CHARACTERSET', 'NLS_NCHAR_CHARACTERSET') ORDER BY parameter
    """)
print((charsets?.rows ?? []).map { "\($0[0].stringValue ?? "?") = \($0[1].stringValue ?? "?")" }.joined(separator: ", "))

let text = "ດ່ານ 𝄞"
let escaped = "\\0E94\\0EC8\\0EB2\\0E99 \\D834\\DD1E"
let large = String(repeating: String(repeating: "ດ", count: 5_000) + "𝄞", count: 4)

await run("DROP TABLE TP_NCHAR_T PURGE")
_ = await result("CREATE TABLE TP_NCHAR_T (ID NUMBER PRIMARY KEY, NV NVARCHAR2(100), NC NCHAR(10), NL NCLOB)")
_ = await result("""
    INSERT INTO TP_NCHAR_T VALUES (1, UNISTR('\(escaped)'), UNISTR('\\0EA5'), TO_NCLOB(UNISTR('\(escaped)')))
    """)
_ = await result("INSERT INTO TP_NCHAR_T (ID) VALUES (2)")
_ = await result("""
    DECLARE c NCLOB;
    BEGIN
      FOR i IN 1..4 LOOP c := c || RPAD(UNISTR('\\0E94'), 5000, UNISTR('\\0E94')) || UNISTR('\\D834\\DD1E'); END LOOP;
      INSERT INTO TP_NCHAR_T (ID, NL) VALUES (3, c);
    END;
    """)

print("\nReads")
if let rows = await result("SELECT NV, NC, NL FROM TP_NCHAR_T WHERE ID = 1")?.rows.first {
    check(rows[0].stringValue == text, "NVARCHAR2 reads \(String(reflecting: rows[0].stringValue))")
    check(rows[1].stringValue == "ລ" + String(repeating: " ", count: 9), "NCHAR reads \(String(reflecting: rows[1].stringValue))")
    check(rows[2].stringValue == text, "NCLOB reads \(String(reflecting: rows[2].stringValue))")
}
if let rows = await result("SELECT NV, NC, NL FROM TP_NCHAR_T WHERE ID = 2")?.rows.first {
    check(rows.allSatisfy { $0.stringValue == nil }, "NULL NCHAR values read as NULL")
}
if let value = await result("SELECT NL FROM TP_NCHAR_T WHERE ID = 3")?.rows.first?.first?.stringValue {
    check(value == large, "a 20,008-character NCLOB reads back whole (\(value.utf16.count) UTF-16 units)")
}
let after = await result("SELECT 1 FROM DUAL")
check(after?.rows.first?.first?.stringValue == "1", "the connection still answers after the NCHAR reads")

print("\nWrites")
_ = await result("UPDATE TP_NCHAR_T SET NV = '\(text)' WHERE ID = 2")
let literal = await result("SELECT NV FROM TP_NCHAR_T WHERE ID = 2")?.rows.first?.first?.stringValue
check(literal == text, "NVARCHAR2 written as a literal reads \(String(reflecting: literal))")
_ = await result(
    "UPDATE TP_NCHAR_T SET NV = :1, NC = :2, NL = :3 WHERE ID = 2",
    binds: [.text(text), .text("ລ"), .text(large)]
)
if let rows = await result("SELECT NV, NC, NL FROM TP_NCHAR_T WHERE ID = 2")?.rows.first {
    check(rows[0].stringValue == text, "NVARCHAR2 written through a bind reads \(String(reflecting: rows[0].stringValue))")
    check(rows[1].stringValue == "ລ" + String(repeating: " ", count: 9), "NCHAR written through a bind reads back")
    check(rows[2].stringValue == large, "an NCLOB written through a bind reads back whole")
}
let matched = await result("SELECT ID FROM TP_NCHAR_T WHERE NV = :1 ORDER BY ID", binds: [.text(text)])
check(matched?.rows.map { $0.first?.stringValue } == ["1", "2"], "a bind matches the NVARCHAR2 rows holding the text")

await run("DROP TABLE TP_NCHAR_T PURGE")
print(disagreements == 0 ? "\nall checks hold" : "\n\(disagreements) disagreement(s)")
exit(disagreements == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$SERVICE" "$USER_NAME" "$PASSWORD" 2> /dev/null
