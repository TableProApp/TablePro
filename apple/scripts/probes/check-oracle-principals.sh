#!/usr/bin/env bash
#
# Run the statements Users & Roles generates for Oracle, and its dictionary reads, against a real server.
#
# OraclePrincipalStatements refuses a column REVOKE because Oracle answers ORA-01750, and OraclePrincipalQueries
# falls back to the ALL_ and USER_ views on ORA-00942. Both are fixed in the code; this checks them, and that a user
# and a role round-trip: create, grant, lock, read back, revoke, unlock, password, drop.
#
# Usage:
#   scripts/probes/check-oracle-principals.sh [host] [port] [service] [dba user] [dba password] [user] [password]
#
# Defaults suit a throwaway Oracle Free container, whose APP_USER cannot read the DBA_ views:
#   docker run -d --name oracle-probe -p 1521:1521 -e ORACLE_PASSWORD=probe_pw \
#     -e APP_USER=probe -e APP_USER_PASSWORD=probe_pw gvenzl/oracle-free:23-slim-faststart
#
# Creates TP_PR_U, TP_PR_R and PROBE-owned TP_PR_T, and drops them again. Exits non-zero on a disagreement, 3 when a
# prerequisite is missing.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1521}"
SERVICE="${3:-FREEPDB1}"
DBA_USER="${4:-system}"
DBA_PASSWORD="${5:-probe_pw}"
USER_NAME="${6:-probe}"
PASSWORD="${7:-probe_pw}"
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
var disagreements = 0

func connect(_ user: String, _ password: String) async -> OracleCoreConnection {
    let connection = OracleCoreConnection(options: OracleConnectionOptions(
        host: arguments[1], port: Int(arguments[2]) ?? 1_521, user: user, password: password,
        identifierMode: .service, serviceName: arguments[3]
    ))
    do {
        try await connection.connect()
    } catch {
        print("cannot connect as \(user): \(error)")
        exit(3)
    }
    return connection
}

let dba = await connect(arguments[4], arguments[5])
let owner = await connect(arguments[6], arguments[7])
let ownerName = arguments[6].uppercased()
let release = dba.serverRelease

@MainActor func check(_ holds: Bool, _ what: String) {
    print("\(holds ? "ok  " : "FAIL") \(what)")
    if !holds { disagreements += 1 }
}

@discardableResult
func run(_ sql: String, on connection: OracleCoreConnection = dba) async -> Error? {
    do {
        _ = try await connection.executeQuery(sql)
        return nil
    } catch {
        return error
    }
}

func runAll(_ statements: [String]?) async -> Bool {
    guard let statements else { return false }
    for statement in statements {
        if let error = await run(statement) {
            print("     failed: \(statement): \(error)")
            return false
        }
    }
    return true
}

func rows(_ sql: String, on connection: OracleCoreConnection = dba) async -> [[String]]? {
    guard let result = try? await connection.executeQuery(sql) else { return nil }
    return result.rows.map { $0.map { $0.stringValue ?? "" } }
}

await run("DROP USER TP_PR_U")
await run("DROP ROLE TP_PR_R")
await run("DROP TABLE TP_PR_T PURGE", on: owner)
check(await run("CREATE TABLE TP_PR_T (C1 NUMBER, C2 NUMBER)", on: owner) == nil, "the owner creates the table")

let table = OracleSecurable.object(owner: ownerName, name: "TP_PR_T")
let fresh = OraclePrincipalStatements(roles: [])
check(await runAll(fresh.create(name: "TP_PR_R", password: nil, canLogin: false, memberOf: [])), "a role is created")
let statements = OraclePrincipalStatements(roles: ["TP_PR_R", "CONNECT"])
check(await runAll(statements.create(name: "TP_PR_U", password: "Pr_1234x", canLogin: true, memberOf: ["TP_PR_R"])),
      "a user is created with a role")
check(await runAll(statements.grantStatements([
    OracleGrant(privilege: "CREATE SESSION", securable: .system),
    OracleGrant(privilege: "CREATE TABLE", securable: .system, isGrantable: true)
], to: "TP_PR_U")), "system privileges are granted, one WITH ADMIN OPTION")
check(await runAll(statements.grantStatements([
    OracleGrant(privilege: "SELECT", securable: table),
    OracleGrant(privilege: "UPDATE", securable: table, column: "C2")
], to: "TP_PR_R")), "table and column privileges are granted to the role")
check(await runAll(statements.alter(
    name: "TP_PR_U", oldCanLogin: true, newCanLogin: false, oldMemberOf: ["TP_PR_R"], newMemberOf: ["TP_PR_R", "CONNECT"]
)), "the user is locked and joins a second role")

let users = await rows(OraclePrincipalQueries.users(access: .dba, release: release)) ?? []
check(users.contains(["TP_PR_U", "LOCKED"]), "DBA_USERS reads the user as locked")
let roleGrants = await rows(OraclePrincipalQueries.roleGrants(access: .dba)) ?? []
check(roleGrants.contains(["TP_PR_U", "TP_PR_R"]) && roleGrants.contains(["TP_PR_U", "CONNECT"]), "both roles read back")
let system = await rows(OraclePrincipalQueries.systemPrivileges(grantee: "TP_PR_U", access: .dba)) ?? []
check(system.contains(["CREATE SESSION", "NO"]) && system.contains(["CREATE TABLE", "YES"]), "system privileges read back")
let objects = await rows(OraclePrincipalQueries.objectPrivileges(grantee: "TP_PR_R", access: .dba)) ?? []
check(objects.contains([ownerName, "TP_PR_T", "SELECT", "NO"]), "the table privilege reads back")
let columns = await rows(OraclePrincipalQueries.columnPrivileges(grantee: "TP_PR_R", access: .dba)) ?? []
check(columns.contains([ownerName, "TP_PR_T", "C2", "UPDATE", "NO"]), "the column privilege reads back")
check((await rows(OraclePrincipalQueries.systemPrivilegeMap)?.count ?? 0) > 100, "SYSTEM_PRIVILEGE_MAP lists the catalog")

let probe = await run(OraclePrincipalQueries.dbaProbe, on: owner)
check((probe as? OracleCoreError).map(OraclePrincipalQueries.isMissingView) ?? false,
      "an account without the DBA_ views gets ORA-00942 from the probe")
for (what, sql) in [
    ("users", OraclePrincipalQueries.users(access: .session, release: release)),
    ("roles", OraclePrincipalQueries.roles(access: .session)),
    ("role grants", OraclePrincipalQueries.roleGrants(access: .session)),
    ("system privileges", OraclePrincipalQueries.systemPrivileges(grantee: ownerName, access: .session)),
    ("object privileges", OraclePrincipalQueries.objectPrivileges(grantee: "TP_PR_R", access: .session)),
    ("column privileges", OraclePrincipalQueries.columnPrivileges(grantee: "TP_PR_R", access: .session))
] {
    check(await rows(sql, on: owner) != nil, "the session read of \(what) runs without the DBA_ views")
}

let columnRevoke = await run("REVOKE UPDATE (\"C2\") ON \(OraclePrincipalStatements.quoted(ownerName)).\"TP_PR_T\" FROM \"TP_PR_R\"")
check(String(describing: columnRevoke).contains("ORA-01750"), "Oracle refuses a column REVOKE (ORA-01750)")
check(statements.revokeStatements([OracleGrant(privilege: "UPDATE", securable: table, column: "C2")], from: "TP_PR_R") == nil,
      "the generator refuses it too")

check(await runAll(statements.revokeStatements([OracleGrant(privilege: "SELECT", securable: table)], from: "TP_PR_R")),
      "the table privilege is revoked")
check(await runAll(statements.alter(
    name: "TP_PR_U", oldCanLogin: false, newCanLogin: true, oldMemberOf: ["TP_PR_R", "CONNECT"], newMemberOf: []
)), "the user is unlocked and leaves both roles")
check(await runAll(statements.setPassword(name: "TP_PR_U", password: "Pr_5678x")), "the password changes")
check(await runAll(statements.drop(name: "TP_PR_U")), "the user is dropped")
check(await runAll(statements.drop(name: "TP_PR_R")), "the role is dropped")

await run("DROP TABLE TP_PR_T PURGE", on: owner)
dba.disconnect()
owner.disconnect()
try? await Task.sleep(nanoseconds: 500_000_000)

print(disagreements == 0 ? "Users & Roles statements round-trip on this server." : "\(disagreements) disagreement(s).")
exit(disagreements == 0 ? 0 : 1)
EOF

echo "Building the probe against Packages/TableProOracle (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
"$WORK/.build/debug/Probe" "$HOST" "$PORT" "$SERVICE" "$DBA_USER" "$DBA_PASSWORD" "$USER_NAME" "$PASSWORD" 2> /dev/null
