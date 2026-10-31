#!/usr/bin/env bash
#
# Check which views the data grid lets a user edit, and that an edit keyed the way the grid keys it
# changes exactly the row it names.
#
# The drivers decide from the server's catalog: PostgreSQL's pg_relation_is_updatable and the
# view's stored query, MySQL and MariaDB's information_schema.VIEWS, SQL Server's
# sys.dm_exec_describe_first_result_set. This builds one table and a view of every shape that
# matters (all columns, a renamed key, swapped names, no key, a join, a join showing one table's
# columns, DISTINCT, a keyless table, and on SQL Server a table in another database whose name the
# current one reuses with another key),
# runs the plugin's real queries and parsers from its own source files, compares each answer with
# the expected one, then writes through every view the answer calls editable: an UPDATE and a
# DELETE keyed on the columns it named, and an INSERT, each checked against the base table.
#
# Usage:
#   scripts/probes/check-view-row-editing.sh <postgresql|mysql|mariadb|mssql> [host] [port] [user] [password]
#
# Needs psql, mysql or mariadb, or FreeTDS's tsql, and a server the user may create a database on.
# Throwaway servers that match the defaults:
#   docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=probe postgres:17
#   docker run -d -p 3306:3306 -e MYSQL_ROOT_PASSWORD=probe mysql:8.4
#   docker run -d -p 3306:3306 -e MARIADB_ROOT_PASSWORD=probe mariadb:11
#   docker run -d -p 1433:1433 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD=Probe_pw1234 mcr.microsoft.com/mssql/server:2022-latest
# Exits non-zero on a wrong answer or a wrong write, 3 when a prerequisite is missing.

set -uo pipefail

ENGINE="${1:-}"
case "$ENGINE" in
    postgresql) DEFAULT_PORT=5432 DEFAULT_USER=postgres DEFAULT_PASSWORD=probe ;;
    mysql | mariadb) DEFAULT_PORT=3306 DEFAULT_USER=root DEFAULT_PASSWORD=probe ;;
    mssql) DEFAULT_PORT=1433 DEFAULT_USER=sa DEFAULT_PASSWORD=Probe_pw1234 ;;
    *)
        echo "usage: $0 <postgresql|mysql|mariadb|mssql> [host] [port] [user] [password]" >&2
        exit 3
        ;;
esac
HOST="${2:-127.0.0.1}"
PORT="${3:-$DEFAULT_PORT}"
USER_NAME="${4:-$DEFAULT_USER}"
PASSWORD="${5:-$DEFAULT_PASSWORD}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATABASE="tablepro_views_$$_$RANDOM"
WORK="$(mktemp -d)"
CREATED=0
FAILURES=0

# One statement per call; prints rows with fields joined by a unit separator and NULL as empty.
sql() {
    local database="$1" statement="$2"
    case "$ENGINE" in
        postgresql)
            PGPASSWORD="$PASSWORD" psql -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$database" \
                -X -q -At -F $'\x1f' -v ON_ERROR_STOP=1 -c "$statement" 2>&1
            ;;
        mysql | mariadb)
            MYSQL_PWD="$PASSWORD" "$MYSQL_CLIENT" -h "$HOST" -P "$PORT" -u "$USER_NAME" --protocol=TCP \
                -N -B --raw ${database:+-D "$database"} -e "$statement" 2>&1 \
                | grep -v '^WARNING: option --ssl-verify-server-cert' \
                | sed -e $'s/\t/\x1f/g' -e $'s/\x1fNULL\x1f/\x1f\x1f/g' -e $'s/\x1fNULL$/\x1f/' -e $'s/^NULL\x1f/\x1f/'
            ;;
        mssql)
            printf 'SET NOCOUNT ON\ngo\n%s\ngo\n' "$statement" \
                | tsql -H "$HOST" -p "$PORT" -U "$USER_NAME" -P "$PASSWORD" -D "$database" -o fhq -t $'\x1f' 2>&1 \
                | sed -e $'s/\x1fNULL\x1f/\x1f\x1f/g' -e $'s/\x1fNULL$/\x1f/' -e $'s/^NULL\x1f/\x1f/'
            ;;
    esac
}

admin_database() {
    case "$ENGINE" in
        postgresql) echo postgres ;;
        mysql | mariadb) echo "" ;;
        mssql) echo master ;;
    esac
}

cleanup() {
    if [ "$CREATED" -eq 1 ]; then
        case "$ENGINE" in
            mssql)
                local database
                for database in "$DATABASE" "${DATABASE}_other"; do
                    sql master "IF DB_ID('$database') IS NOT NULL BEGIN ALTER DATABASE [$database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$database] END" > /dev/null
                done
                ;;
            *) sql "$(admin_database)" "DROP DATABASE $DATABASE" > /dev/null ;;
        esac
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

case "$ENGINE" in
    postgresql) command -v psql > /dev/null || { echo "psql not found (brew install libpq)" >&2; exit 3; } ;;
    mysql | mariadb)
        MYSQL_CLIENT="$(command -v mysql || command -v mariadb)" || { echo "mysql not found" >&2; exit 3; }
        ;;
    mssql) command -v tsql > /dev/null || { echo "tsql not found (brew install freetds)" >&2; exit 3; } ;;
esac
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p)"
    case "$DEVELOPER_DIR" in
        *CommandLineTools*) DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
    esac
fi
export DEVELOPER_DIR

if ! sql "$(admin_database)" "SELECT 1" | grep -qx '1'; then
    echo "no $ENGINE server at $HOST:$PORT as $USER_NAME" >&2
    exit 3
fi

# The resolver reads the plugin's own files, so a change to a parser or a query is what this runs.
mkdir -p "$WORK/Sources/ViewEditing"
cat > "$WORK/Package.swift" << EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViewEditing",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .executableTarget(
            name: "ViewEditing",
            dependencies: [
                .product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProMSSQLCore", package: "TableProCore"),
            ]
        )
    ]
)
EOF
ln -s "$ROOT/Plugins/PostgreSQLDriverPlugin/PostgreSQLViewRowEditing.swift" "$WORK/Sources/ViewEditing/"
ln -s "$ROOT/Plugins/MySQLDriverPlugin/MySQLViewRowEditing.swift" "$WORK/Sources/ViewEditing/"
cat > "$WORK/Sources/ViewEditing/main.swift" << 'SWIFT'
import Foundation
import TableProMSSQLCore
import TableProPluginKit

// The driver's literal quoting, minus the backslash and NUL cases no fixture name has.
enum PostgreSQLObjectQueries {
    static func quoteLiteral(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "''"))'" }
}

let separator: Character = "\u{1F}"

func rows(_ text: String) -> [[String?]] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
        line.split(separator: separator, omittingEmptySubsequences: false).map { $0.isEmpty ? nil : String($0) }
    }
}

// Runs one statement through the probe's own client, which reads it from the environment.
func query(_ statement: String) -> [[String?]] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", "\"$PROBE_SQL\" \"$PROBE_DATABASE\" \"$1\"", "probe", statement]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return rows(String(decoding: data, as: UTF8.self))
}

func describe(_ editing: PluginViewRowEditing) -> String {
    switch editing {
    case .editable(let keys): return "editable:" + keys.joined(separator: ",")
    case .readOnly(let reason): return "readonly:" + reason.rawValue
    @unknown default: return "unknown"
    }
}

func postgreSQL(view: String, schema: String) -> PluginViewRowEditing? {
    guard let row = query(PostgreSQLViewRowEditing.viewQuery(name: view, schema: schema)).first,
          let viewOID = row[0] else { return nil }
    let isUpdatable = row[1] == "t"
    let origins = PostgreSQLViewRowEditing.targetOrigins(nodeTree: row[2] ?? "")
    var names: [Int: String] = [:]
    var keys: [Int] = []
    if isUpdatable, let base = origins.first?.tableOID {
        for detail in query(PostgreSQLViewRowEditing.columnsAndKeyQuery(viewOID: viewOID, baseTableOID: base)) {
            guard let number = detail[1].flatMap(Int.init) else { continue }
            if detail[0] == "v" { names[number] = detail[2] } else { keys.append(number) }
        }
    }
    return PostgreSQLViewRowEditing.resolve(
        isUpdatable: isUpdatable, origins: origins, viewColumnNames: names, baseKeyColumnNumbers: keys
    )
}

func mySQL(view: String, database: String) -> PluginViewRowEditing? {
    let escape: (String) -> String = { $0.replacingOccurrences(of: "'", with: "''") }
    guard let row = query(MySQLViewRowEditing.viewQuery(name: view, database: database, escape: escape)).first
    else { return nil }
    let isUpdatable = row[0]?.uppercased() == "YES"
    let definition = row[1].flatMap(MySQLViewRowEditing.parse(definition:))
    var keys: [String] = []
    if isUpdatable, let base = definition?.baseTable {
        keys = query(MySQLViewRowEditing.primaryKeyQuery(table: base, viewDatabase: database, escape: escape))
            .compactMap { $0[0] }
    }
    return MySQLViewRowEditing.resolve(isUpdatable: isUpdatable, definition: definition, baseKeyColumns: keys)
}

func msSQL(view: String, schema: String) -> PluginViewRowEditing {
    let errors = query(MSSQLViewSources.compileErrorsQuery(schema: schema, view: view)).compactMap { $0[0].flatMap(Int.init) }
    let summary = MSSQLViewSources.summarize(rows: query(MSSQLViewSources.columnSourcesQuery(schema: schema, view: view)))
    var keys: [String] = []
    if summary.baseTables.count == 1, let base = summary.baseTables.first {
        keys = query(MSSQLViewSources.primaryKeyQuery(base)).compactMap { $0[0] }
    }
    return PluginViewRowEditing.resolve(
        isUpdatable: MSSQLViewSources.isUpdatable(compileErrors: errors),
        baseTableCount: MSSQLViewSources.baseTableCount(summary, compileErrors: errors),
        baseKeyColumns: keys,
        origins: summary.origins.map { PluginViewColumnOrigin(viewColumn: $0.viewColumn, baseColumn: $0.baseColumn) }
    )
}

let arguments = CommandLine.arguments
let engine = arguments[1], container = arguments[2], view = arguments[3]
let editing: PluginViewRowEditing?
switch engine {
case "postgresql": editing = postgreSQL(view: view, schema: container)
case "mssql": editing = msSQL(view: view, schema: container)
default: editing = mySQL(view: view, database: container)
}
print(editing.map(describe) ?? "nil")
SWIFT
swift build --package-path "$WORK" > "$WORK/build.log" 2>&1 || {
    echo "the resolver failed to build:" >&2
    grep -E 'error:' "$WORK/build.log" | sort -u | head -20 >&2
    exit 3
}
RESOLVER="$(swift build --package-path "$WORK" --show-bin-path)/ViewEditing"

case "$ENGINE" in
    mssql) out="$(sql master "CREATE DATABASE [$DATABASE]")" ;;
    *) out="$(sql "$(admin_database)" "CREATE DATABASE $DATABASE")" ;;
esac
if [ -n "$out" ]; then
    echo "could not create $DATABASE: $out" >&2
    exit 3
fi
CREATED=1

case "$ENGINE" in
    postgresql) CONTAINER=public Q_OPEN='"' Q_CLOSE='"' ;;
    mysql | mariadb) CONTAINER="$DATABASE" Q_OPEN='`' Q_CLOSE='`' ;;
    mssql) CONTAINER=dbo Q_OPEN='[' Q_CLOSE=']' ;;
esac
q() { printf '%s%s%s' "$Q_OPEN" "$1" "$Q_CLOSE"; }

# One statement per line: SQL Server needs CREATE VIEW to open its own batch.
FIXTURE="CREATE TABLE t (id int PRIMARY KEY, name varchar(20), qty int)
CREATE TABLE u (tid int)
CREATE TABLE k (name varchar(20), qty int)
INSERT INTO t (id, name, qty) VALUES (1, 'a', 1)
INSERT INTO t (id, name, qty) VALUES (2, 'b', 2)
INSERT INTO u (tid) VALUES (1)
CREATE VIEW v_simple AS SELECT id, name, qty FROM t
CREATE VIEW v_renamed AS SELECT id AS key_id, name, qty + 1 AS q2 FROM t
CREATE VIEW v_swap AS SELECT name AS id, id AS name FROM t
CREATE VIEW v_nokey AS SELECT name, qty FROM t
CREATE VIEW v_join AS SELECT t.id, t.name, u.tid FROM t JOIN u ON u.tid = t.id
CREATE VIEW v_join_one AS SELECT t.id, t.name FROM t JOIN u ON u.tid = t.id
CREATE VIEW v_distinct AS SELECT DISTINCT id, name FROM t
CREATE VIEW v_keyless AS SELECT name, qty FROM k"
while IFS= read -r line; do
    out="$(sql "$DATABASE" "$line")"
    if [ -n "$out" ]; then
        echo "fixture failed: $line: $out" >&2
        exit 3
    fi
done <<< "$FIXTURE"

# The other database's t2 is keyed on id; the current one's t2 is keyed on code, which repeats over there.
if [ "$ENGINE" = mssql ]; then
    OTHER_FIXTURE="CREATE DATABASE [${DATABASE}_other]
CREATE TABLE [${DATABASE}_other].dbo.t2 (code int NOT NULL, id int PRIMARY KEY)
INSERT INTO [${DATABASE}_other].dbo.t2 (code, id) VALUES (7, 1), (7, 2)
CREATE TABLE dbo.t2 (code int PRIMARY KEY, id int)
CREATE VIEW v_otherdb AS SELECT code, id FROM [${DATABASE}_other].dbo.t2"
    while IFS= read -r line; do
        out="$(sql "$DATABASE" "$line")"
        if [ -n "$out" ]; then
            echo "fixture failed: $line: $out" >&2
            exit 3
        fi
    done <<< "$OTHER_FIXTURE"
fi

case "$ENGINE" in
    postgresql) JOIN_ANSWER=readonly:notUpdatable ;;
    *) JOIN_ANSWER=readonly:readsSeveralTables ;;
esac
EXPECTED="v_simple editable:id
v_renamed editable:key_id
v_swap editable:name
v_nokey readonly:keyNotExposed
v_join $JOIN_ANSWER
v_join_one $JOIN_ANSWER
v_distinct readonly:notUpdatable
v_keyless readonly:baseTableHasNoKey"
[ "$ENGINE" = mssql ] && EXPECTED="$EXPECTED
v_otherdb editable:id"

export PROBE_SQL="$WORK/sql.sh" PROBE_DATABASE="$DATABASE"
{
    echo '#!/usr/bin/env bash'
    declare -p ENGINE HOST PORT USER_NAME PASSWORD
    [ -n "${MYSQL_CLIENT:-}" ] && declare -p MYSQL_CLIENT
    declare -f sql
    echo 'sql "$1" "$2"'
} > "$PROBE_SQL"
chmod +x "$PROBE_SQL"

echo "Checking view row editing on $ENGINE at $HOST:$PORT"
while read -r view expected; do
    actual="$("$RESOLVER" "$ENGINE" "$CONTAINER" "$view")"
    if [ "$actual" = "$expected" ]; then
        echo "  ok    $view: $actual"
    else
        echo "  FAIL  $view: expected $expected, got $actual"
        FAILURES=$((FAILURES + 1))
    fi
done <<< "$EXPECTED"

# A write keyed the way the grid keys it. Each check reads the base table, never the view.
expect_value() {
    local label="$1" statement="$2" expected="$3"
    local actual
    actual="$(sql "$DATABASE" "$statement")"
    if [ "$actual" = "$expected" ]; then
        echo "  ok    $label"
    else
        echo "  FAIL  $label: expected '$expected', got '$actual'"
        FAILURES=$((FAILURES + 1))
    fi
}
write() {
    local label="$1" statement="$2"
    local out
    out="$(sql "$DATABASE" "$statement")"
    if [ -n "$out" ]; then
        echo "  FAIL  $label: $out"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "Writing through the editable views"
write "update v_renamed" "UPDATE $(q v_renamed) SET $(q name) = 'renamed' WHERE $(q key_id) = 2"
expect_value "update v_renamed changed row 2 only" "SELECT name FROM t ORDER BY id" $'a\nrenamed'
write "update v_swap" "UPDATE $(q v_swap) SET $(q id) = 'swapped' WHERE $(q name) = 1"
expect_value "update v_swap changed row 1 only" "SELECT name FROM t ORDER BY id" $'swapped\nrenamed'
write "insert v_simple" "INSERT INTO $(q v_simple) ($(q id), $(q name), $(q qty)) VALUES (3, 'new', 3)"
expect_value "insert v_simple added row 3" "SELECT COUNT(*) FROM t WHERE id = 3 AND name = 'new'" "1"
write "delete v_simple" "DELETE FROM $(q v_simple) WHERE $(q id) = 3"
expect_value "delete v_simple removed row 3 only" "SELECT COUNT(*) FROM t" "2"
if [ "$ENGINE" = mssql ]; then
    write "update v_otherdb" "UPDATE [v_otherdb] SET [code] = 8 WHERE [id] = 2"
    expect_value "update v_otherdb changed row 2 only" "SELECT code FROM [${DATABASE}_other].dbo.t2 ORDER BY id" $'7\n8'
fi

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed"
    exit 1
fi
echo "All checks passed"
