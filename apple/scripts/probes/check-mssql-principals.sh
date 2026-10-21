#!/usr/bin/env bash
#
# Run the statements Users & Roles generates for SQL Server, and its catalog reads, against a real server.
#
# MSSQLPrincipalStatements grants a server permission through `EXEC [master].sys.sp_executesql`, because the server
# answers Msg 4621 outside master, and runs database statements through `EXEC [db].sys.sp_executesql`, so the session
# keeps its database. The apply runs in one transaction. This checks all three, and that logins, users and roles
# round-trip from a session sitting in master: create, grant, disable, read back, revoke, enable, password, drop.
#
# Usage:
#   scripts/probes/check-mssql-principals.sh [host] [port] [sa password]
#
# Needs FreeTDS's tsql (brew install freetds) and a throwaway server, for example:
#   docker run -d --platform linux/amd64 -e ACCEPT_EULA=Y -e 'MSSQL_SA_PASSWORD=Tp_Probe_1!x' -p 1433:1433 \
#     mcr.microsoft.com/mssql/server:2019-latest
#
# Creates the database TP_PR_DB and logins prefixed tp_pr_, and drops them again. Exits non-zero on a disagreement,
# 3 when a prerequisite is missing.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1433}"
SA_PASSWORD="${3:-${MSSQL_SA_PASSWORD:-}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

[ -n "$SA_PASSWORD" ] || {
    echo "no password: pass one as the 3rd argument or set MSSQL_SA_PASSWORD" >&2
    exit 3
}
command -v tsql > /dev/null || {
    echo "tsql not found (brew install freetds)" >&2
    exit 3
}
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/Gen"

cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gen",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .executableTarget(name: "Gen", dependencies: [.product(name: "TableProMSSQLCore", package: "TableProCore")])
    ]
)
EOF

cat > "$WORK/Sources/Gen/main.swift" <<'EOF'
import Foundation
import TableProMSSQLCore

let db = "TP_PR_DB"
let password = "Zq9_Probe_77!k"
func batch(_ statements: [String]?) {
    guard let statements else {
        print("SELECT 'GENERATOR REFUSED'")
        print("go")
        return
    }
    print("BEGIN TRANSACTION\ngo")
    for statement in statements { print(statement + "\ngo") }
    print("COMMIT TRANSACTION\ngo")
}

let before = MSSQLPrincipalDirectory(
    database: db,
    logins: [.init(name: "tp_pr_app", isDisabled: false, user: "tp_pr_app"), .init(name: "tp_pr_bare", isDisabled: false, user: nil)],
    serverRoles: ["processadmin"],
    databasePrincipals: [.init(name: "tp_pr_readers", isRole: true, hasConnect: false)],
    serverMemberships: [],
    databaseMemberships: []
)
let after = MSSQLPrincipalDirectory(
    database: db,
    logins: [
        .init(name: "tp_pr_app", isDisabled: true, user: "tp_pr_app"),
        .init(name: "tp_pr_bare", isDisabled: false, user: "tp_pr_bare"),
        .init(name: "tp_pr_new", isDisabled: false, user: "tp_pr_new")
    ],
    serverRoles: ["processadmin"],
    databasePrincipals: [.init(name: "tp_pr_readers", isRole: true, hasConnect: false)],
    serverMemberships: [.init(member: "tp_pr_app", role: "processadmin")],
    databaseMemberships: [
        .init(member: "tp_pr_app", role: "tp_pr_readers"),
        .init(member: "tp_pr_bare", role: "tp_pr_readers"),
        .init(member: "tp_pr_new", role: "tp_pr_readers")
    ]
)
let orders = MSSQLSecurable.object(schema: "dbo", name: "Orders")

switch CommandLine.arguments[1] {
case "apply":
    let s = MSSQLPrincipalStatements(directory: before)
    var all: [String] = []
    all += s.create(name: "tp_pr_new", password: password, canLogin: true, memberOf: ["tp_pr_readers"]) ?? []
    all += s.alter(name: "tp_pr_app", oldCanLogin: true, newCanLogin: false, oldMemberOf: [],
                   newMemberOf: ["tp_pr_readers", "processadmin"]) ?? []
    all += s.alter(name: "tp_pr_bare", oldCanLogin: true, newCanLogin: true, oldMemberOf: [], newMemberOf: ["tp_pr_readers"]) ?? []
    all += s.grantStatements([
        MSSQLGrant(permission: "VIEW SERVER STATE", securable: .server),
        MSSQLGrant(permission: "CREATE TABLE", securable: .database),
        MSSQLGrant(permission: "SELECT", securable: .schema("dbo")),
        MSSQLGrant(permission: "UPDATE", securable: orders, column: "total"),
        MSSQLGrant(permission: "DELETE", securable: orders, withGrantOption: true)
    ], to: "tp_pr_app") ?? []
    all += s.setPassword(name: "tp_pr_app", password: "Zq9_Probe_88!k") ?? []
    batch(all)
case "read":
    for query in [
        MSSQLPrincipalQueries.logins(database: db),
        MSSQLPrincipalQueries.serverRoleMembers,
        MSSQLPrincipalQueries.databaseRoleMembers(database: db),
        MSSQLPrincipalQueries.serverPermissions(grantee: "tp_pr_app"),
        MSSQLPrincipalQueries.databasePermissions(grantee: "tp_pr_app", database: db),
        MSSQLPrincipalQueries.databasePrincipals(database: db),
        MSSQLPrincipalQueries.schemas(database: db),
        MSSQLPrincipalQueries.objects(schema: "dbo", database: db),
        MSSQLPrincipalQueries.columns(schema: "dbo", object: "Orders", database: db),
        MSSQLPrincipalQueries.searchObjects(matching: "ord", limit: 5, database: db),
        MSSQLPrincipalQueries.builtinPermissions
    ] {
        print(query + "\ngo")
    }
case "revoke":
    let s = MSSQLPrincipalStatements(directory: after)
    var all: [String] = []
    all += s.revokeStatements([
        MSSQLGrant(permission: "VIEW SERVER STATE", securable: .server),
        MSSQLGrant(permission: "DELETE", securable: orders, withGrantOption: true),
        MSSQLGrant(permission: "UPDATE", securable: orders, column: "total")
    ], from: "tp_pr_app") ?? []
    all += s.alter(name: "tp_pr_app", oldCanLogin: false, newCanLogin: true,
                   oldMemberOf: ["tp_pr_readers", "processadmin"], newMemberOf: []) ?? []
    batch(all)
default:
    let s = MSSQLPrincipalStatements(directory: after)
    batch(["tp_pr_new", "tp_pr_readers", "tp_pr_app", "tp_pr_bare"].flatMap { s.drop(name: $0) ?? [] })
}
EOF

echo "Building the generator against Packages/TableProCore"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
GEN="$WORK/.build/debug/Gen"

sql() {
    tsql -H "$HOST" -p "$PORT" -U sa -P "$SA_PASSWORD" 2>&1 | grep -v -E '^(locale|Setting|using) '
}

disagreements=0
check() {
    if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; disagreements=$((disagreements + 1)); fi
}
no_errors() {
    ! grep -q -E 'Msg [0-9]+|GENERATOR REFUSED' <<< "$1"
}
contains() {
    grep -q -F -- "$2" <<< "$1"
}

sql > /dev/null <<'EOF'
IF DB_ID(N'TP_PR_DB') IS NOT NULL DROP DATABASE TP_PR_DB
go
IF SUSER_ID(N'tp_pr_app') IS NOT NULL DROP LOGIN tp_pr_app
go
IF SUSER_ID(N'tp_pr_bare') IS NOT NULL DROP LOGIN tp_pr_bare
go
IF SUSER_ID(N'tp_pr_new') IS NOT NULL DROP LOGIN tp_pr_new
go
EOF
setup="$(sql <<'EOF'
CREATE DATABASE TP_PR_DB
go
EXEC [TP_PR_DB].sys.sp_executesql N'CREATE TABLE dbo.Orders (id int, total int)'
go
CREATE LOGIN tp_pr_app WITH PASSWORD = N'Zq9_Probe_77!k'
go
CREATE LOGIN tp_pr_bare WITH PASSWORD = N'Zq9_Probe_77!k'
go
EXEC [TP_PR_DB].sys.sp_executesql N'CREATE USER tp_pr_app FOR LOGIN tp_pr_app'
go
EXEC [TP_PR_DB].sys.sp_executesql N'CREATE ROLE tp_pr_readers'
go
EOF
)"
no_errors "$setup" || {
    echo "setup failed:" >&2
    echo "$setup" >&2
    exit 3
}

applied="$("$GEN" apply | sql)"
no_errors "$applied"; check $? "the apply runs in one transaction from a session in master"

read="$("$GEN" read | sql)"
contains "$read" "$(printf 'tp_pr_app\t1\ttp_pr_app')"; check $? "the login reads back disabled with its user"
contains "$read" "$(printf 'tp_pr_bare\t0\ttp_pr_bare')"; check $? "a login with no user got one before joining a role"
contains "$read" "$(printf 'tp_pr_app\tprocessadmin')"; check $? "the server role membership reads back"
contains "$read" "$(printf 'tp_pr_new\ttp_pr_readers')"; check $? "the created user joined the database role"
contains "$read" "$(printf 'VIEW SERVER STATE\tG')"; check $? "the server permission was granted in master"
contains "$read" "$(printf '1\tDELETE\tW\tdbo\tOrders')"; check $? "the grant option reads back"
contains "$read" "$(printf '1\tUPDATE\tG\tdbo\tOrders\ttotal')"; check $? "the column permission reads back"
contains "$read" "$(printf '0\tCREATE TABLE\tG')"; check $? "the database permission reads back"
no_errors "$read"; check $? "every catalog read runs"

outside="$(printf 'USE TP_PR_DB\ngo\nGRANT VIEW SERVER STATE TO tp_pr_app\ngo\n' | sql)"
contains "$outside" "Msg 4621"; check $? "a server permission outside master is refused (Msg 4621)"

rolled="$(sql <<'EOF'
BEGIN TRANSACTION
go
CREATE LOGIN tp_pr_rolled WITH PASSWORD = N'Zq9_Probe_77!k'
go
ROLLBACK TRANSACTION
go
SELECT 'rolled=' + CAST(COUNT(*) AS varchar(4)) FROM sys.server_principals WHERE name = N'tp_pr_rolled'
go
EOF
)"
contains "$rolled" "rolled=0"; check $? "CREATE LOGIN rolls back with its transaction"

revoked="$("$GEN" revoke | sql)"
no_errors "$revoked"; check $? "revoke, enable and leaving both roles run"
dropped="$("$GEN" drop | sql)"
no_errors "$dropped"; check $? "dropping the users and the role runs, members first"
left="$(printf "SELECT 'left=' + CAST(COUNT(*) AS varchar(4)) FROM sys.server_principals WHERE name LIKE N'tp!_pr!_%%' ESCAPE '!'\ngo\n" | sql)"
contains "$left" "left=0"; check $? "no login is left"

sql > /dev/null <<'EOF'
DROP DATABASE TP_PR_DB
go
EOF

if [ "$disagreements" = 0 ]; then
    echo "Users & Roles statements round-trip on this server."
    exit 0
fi
echo "$disagreements disagreement(s)."
exit 1
