#!/usr/bin/env bash
#
# Check the terminator rules PLSQLUnitTracker hard-codes against a real Oracle server.
#
# The editor decides per statement whether the `;` that ends it is sent. The rule is written by
# hand in TablePro/Core/Utilities/SQL/PLSQLUnitTracker.swift and pinned by PLSQLScriptCorpus, and
# nothing else checks it against Oracle. Getting it wrong is silent in the worst way: a unit sent
# without the `;` after its END is stored INVALID while the CREATE reports success, and a
# CALL-bodied trigger sent with one is stored INVALID the same way. So this sends every shape both
# ways, through the same OracleCoreConnection the plugin uses, and compares what Oracle stored
# with what the tracker decides.
#
# Usage:
#   scripts/check-oracle-plsql-terminators.sh [host] [port] [service] [user] [password]
#
# Defaults suit a throwaway Oracle Free container:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# The user needs CREATE PROCEDURE, CREATE TRIGGER, CREATE TYPE and CREATE TABLE. Every object it
# creates is prefixed TP_TERM_ and dropped again. Exits non-zero on a disagreement, 3 when a
# prerequisite is missing.

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

struct Shape {
    let name: String
    let object: String?
    let objectType: String
    let body: String
    let keepsTerminator: Bool
}

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

func run(_ sql: String) async -> String? {
    do {
        _ = try await connection.executeQuery(sql)
        return nil
    } catch {
        return String(describing: error)
    }
}

func status(of object: String, type: String) async -> String {
    let sql = "SELECT STATUS FROM USER_OBJECTS WHERE OBJECT_NAME = '\(object)' AND OBJECT_TYPE = '\(type)'"
    let rows = (try? await connection.executeQuery(sql).rows) ?? []
    return rows.first?.first?.stringValue ?? "MISSING"
}

_ = await run("CREATE TABLE TP_TERM_TAB (A NUMBER)")
_ = await run("CREATE OR REPLACE PROCEDURE TP_TERM_LOG(P NUMBER) IS BEGIN NULL; END;")

let shapes = [
    Shape(name: "procedure", object: "TP_TERM_P", objectType: "PROCEDURE",
          body: "CREATE OR REPLACE PROCEDURE TP_TERM_P IS V NUMBER; BEGIN V := 1; END", keepsTerminator: true),
    Shape(name: "function", object: "TP_TERM_F", objectType: "FUNCTION",
          body: "CREATE OR REPLACE FUNCTION TP_TERM_F RETURN NUMBER IS BEGIN RETURN 1; END", keepsTerminator: true),
    Shape(name: "package specification", object: "TP_TERM_PKG", objectType: "PACKAGE",
          body: "CREATE OR REPLACE PACKAGE TP_TERM_PKG AS PROCEDURE A; END TP_TERM_PKG", keepsTerminator: true),
    Shape(name: "package body", object: "TP_TERM_PKG", objectType: "PACKAGE BODY",
          body: "CREATE OR REPLACE PACKAGE BODY TP_TERM_PKG AS PROCEDURE A IS BEGIN NULL; END A; END TP_TERM_PKG",
          keepsTerminator: true),
    Shape(name: "block-bodied trigger", object: "TP_TERM_TRG", objectType: "TRIGGER",
          body: "CREATE OR REPLACE TRIGGER TP_TERM_TRG BEFORE INSERT ON TP_TERM_TAB FOR EACH ROW BEGIN :NEW.A := 1; END",
          keepsTerminator: true),
    Shape(name: "CALL-bodied trigger", object: "TP_TERM_CALL_TRG", objectType: "TRIGGER",
          body: "CREATE OR REPLACE TRIGGER TP_TERM_CALL_TRG BEFORE INSERT ON TP_TERM_TAB FOR EACH ROW CALL TP_TERM_LOG(:NEW.A)",
          keepsTerminator: false),
    Shape(name: "anonymous block", object: nil, objectType: "",
          body: "BEGIN NULL; END", keepsTerminator: true),
    Shape(name: "declare block", object: nil, objectType: "",
          body: "DECLARE V NUMBER; BEGIN V := 1; END", keepsTerminator: true),
]

var disagreements = 0
for shape in shapes {
    // The broken form goes first, so each unit is left VALID for the ones that depend on it: a package body
    // compiled against a specification stored INVALID is INVALID whatever its own terminator.
    for withTerminator in [false, true] {
        let sql = withTerminator ? shape.body + ";" : shape.body
        let failure = await run(sql)
        var works = failure == nil
        if works, let object = shape.object {
            works = await status(of: object, type: shape.objectType) == "VALID"
        }
        let expected = withTerminator == shape.keepsTerminator
        let form = withTerminator ? "with ';'" : "without ';'"
        let mark = works == expected ? "ok  " : "FAIL"
        print("\(mark) \(shape.name) \(form): \(works ? "works" : "broken")")
        if works != expected { disagreements += 1 }
    }
}

let slash = await run("BEGIN NULL; END;\n/")
print("\(slash == nil ? "FAIL" : "ok  ") a '/' line sent to the server is refused")
if slash == nil { disagreements += 1 }

for drop in [
    "DROP TRIGGER TP_TERM_TRG", "DROP TRIGGER TP_TERM_CALL_TRG", "DROP PACKAGE TP_TERM_PKG",
    "DROP FUNCTION TP_TERM_F", "DROP PROCEDURE TP_TERM_P", "DROP PROCEDURE TP_TERM_LOG", "DROP TABLE TP_TERM_TAB",
] {
    _ = await run(drop)
}

print(disagreements == 0 ? "The terminator rules match this server." : "\(disagreements) disagreement(s).")
exit(disagreements == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$SERVICE" "$USER_NAME" "$PASSWORD" 2> /dev/null
