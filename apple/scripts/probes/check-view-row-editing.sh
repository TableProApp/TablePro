#!/usr/bin/env bash
#
# Check which views the data grid lets a user edit, and that a write keyed the way the grid keys it
# changes exactly the base row it names.
#
# Builds a base table and a view of every shape that matters, compiles the driver's own view code
# (its pure enum and PluginViewRowEditing.swift) into a harness, runs the catalog queries the driver
# runs through the engine's command-line client, and compares each answer (reason, base table, key,
# read-only columns, operations) with the expected one. Then it writes through every view the answer
# calls editable: an UPDATE keyed on the answer's key, an INSERT and a DELETE where the answer allows
# them, each checked against the base table. A write the answer refuses (an INSERT, an UPDATE of a
# read-only column) must fail at the server too.
#
# Usage:
#   scripts/probes/check-view-row-editing.sh <postgresql|mysql|mariadb|mssql> [host] [port] [user] [password]
#
# Needs swiftc, a server the user may create a database on, and psql, mysql or mariadb, or FreeTDS's
# tsql for SQL Server (sqlcmd is not used). Throwaway servers that match the defaults:
#   docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=probe postgres:17
#   docker run -d -p 3306:3306 -e MYSQL_ROOT_PASSWORD=probe mysql:8.4
#   docker run -d -p 3306:3306 -e MARIADB_ROOT_PASSWORD=probe mariadb:11
#   docker run -d -p 1433:1433 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD=Probe_pw1234 mcr.microsoft.com/mssql/server:2022-latest
# Exits 1 on a wrong answer, a wrong write or a harness that does not build, 3 when a prerequisite is missing.

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
OTHER="${DATABASE}_elsewhere"
WORK="$(mktemp -d)"
CREATED=0
CHECKS=0
FAILURES=0
NEXT=100

# Runs one statement and prints its rows, fields split by \x1f. With catalog as $3 it prints what the
# harness reads: PostgreSQL records split by \x1e with NULL as \x1d, MySQL's XML, tsql's plain rows.
# A server error goes to stderr with a non-zero status. Not \x01 for NULL: declare -f mangles it.
sql() {
    local database="$1" statement="$2" mode="${3:-rows}" status
    case "$ENGINE" in
        postgresql)
            local format=(-F $'\x1f')
            [ "$mode" = catalog ] && format+=(-R $'\x1e' -P null=$'\x1d')
            PGPASSWORD="$PASSWORD" psql -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$database" \
                -X -q -A -t -v ON_ERROR_STOP=1 "${format[@]}" -c "$statement" < /dev/null
            ;;
        mysql | mariadb)
            local client=(env MYSQL_PWD="$PASSWORD" "$MYSQL_CLIENT" -h "$HOST" -P "$PORT" -u "$USER_NAME"
                --protocol=TCP --default-character-set=utf8mb4)
            [ -n "$database" ] && client+=(-D "$database")
            if [ "$mode" = catalog ]; then
                "${client[@]}" --xml -e "$statement" < /dev/null 2> "$WORK/stderr"
                status=$?
            else
                "${client[@]}" -N -B -e "$statement" < /dev/null 2> "$WORK/stderr" | tr '\t' $'\x1f'
                status=${PIPESTATUS[0]}
            fi
            grep -v '^WARNING: option --ssl-verify-server-cert' "$WORK/stderr" >&2
            return "$status"
            ;;
        mssql)
            printf 'SET NOCOUNT ON\ngo\n%s\ngo\n' "$statement" \
                | tsql -H "$HOST" -p "$PORT" -U "$USER_NAME" -P "$PASSWORD" -D "$database" -o fhq -t $'\x1f' \
                    2> "$WORK/stderr"
            status=${PIPESTATUS[1]}
            # tsql exits 0 after a server error; severity 11 and up is one.
            if grep -Eq '^Msg [0-9]+ \(severity (1[1-9]|2[0-9])' "$WORK/stderr"; then
                cat "$WORK/stderr" >&2
                return 1
            fi
            return "$status"
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
            postgresql) sql postgres "DROP DATABASE $DATABASE" > /dev/null 2>&1 ;;
            mysql | mariadb)
                sql "" "DROP DATABASE IF EXISTS $DATABASE" > /dev/null 2>&1
                sql "" "DROP DATABASE IF EXISTS $OTHER" > /dev/null 2>&1
                ;;
            mssql)
                local database
                for database in "$DATABASE" "$OTHER"; do
                    sql master "IF DB_ID('$database') IS NOT NULL BEGIN ALTER DATABASE [$database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$database] END" > /dev/null 2>&1
                done
                ;;
        esac
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

case "$ENGINE" in
    postgresql) command -v psql > /dev/null || { echo "psql not found (brew install libpq)" >&2; exit 3; } ;;
    mysql | mariadb)
        MYSQL_CLIENT="$(command -v mysql || command -v mariadb)" || { echo "mysql or mariadb not found" >&2; exit 3; }
        ;;
    mssql) command -v tsql > /dev/null || { echo "tsql not found (brew install freetds)" >&2; exit 3; } ;;
esac
command -v swiftc > /dev/null || { echo "swiftc not found (xcode-select --install)" >&2; exit 3; }

if [ "$(sql "$(admin_database)" "SELECT 1" 2> /dev/null)" != 1 ]; then
    echo "no $ENGINE server at $HOST:$PORT as $USER_NAME" >&2
    exit 3
fi

# The harness runs the driver's own files, so a change to a query or a parser is what this checks.
PLUGINS="$ROOT/Plugins"
CORE="$ROOT/Packages/TableProCore/Sources"
mkdir -p "$WORK/modules" "$WORK/harness"
KIT_FILES=("$PLUGINS/TableProPluginKit/PluginViewRowEditing.swift" "$PLUGINS/TableProPluginKit/ArrayExtension.swift")
HARNESS_FILES=("$WORK/harness/common.swift" "$WORK/harness/main.swift")

cat > "$WORK/harness/common.swift" << 'SWIFT'
import Foundation
import TableProPluginKit

struct CatalogError: Error, CustomStringConvertible {
    let description: String
}

let engine = ProcessInfo.processInfo.environment["PROBE_ENGINE"] ?? ""
let catalogClient = ProcessInfo.processInfo.environment["PROBE_CATALOG"] ?? ""

// One client run per statement, sent whole as the driver sends it.
func catalogRows(_ statement: String) throws -> [[String?]] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: catalogClient)
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    input.fileHandleForWriting.write(Data(statement.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CatalogError(description: message.isEmpty ? "the client exited \(process.terminationStatus)" : message)
    }
    switch engine {
    case "mysql", "mariadb":
        guard let rows = XMLRows.parse(data) else { throw CatalogError(description: "unreadable XML") }
        return rows
    case "postgresql":
        return separatedRows(data, recordSeparator: 0x1E, null: "\u{1D}")
    default:
        return separatedRows(data, recordSeparator: 0x0A, null: "NULL")
    }
}

// By byte: a combining mark after a separator would fuse the two into one Character.
func separatedRows(_ data: Data, recordSeparator: UInt8, null: String) -> [[String?]] {
    var bytes = [UInt8](data)
    if bytes.last == 0x0A { bytes.removeLast() }
    guard !bytes.isEmpty else { return [] }
    return bytes.split(separator: recordSeparator, omittingEmptySubsequences: false).map { record in
        record.split(separator: 0x1F, omittingEmptySubsequences: false).map { field in
            let value = String(decoding: field, as: UTF8.self)
            return value == null ? nil : value
        }
    }
}

// The mysql client's --xml is the only output that tells NULL from the text NULL.
final class XMLRows: NSObject, XMLParserDelegate {
    private var rows: [[String?]] = []
    private var row: [String?] = []
    private var field: String?
    private var inField = false

    static func parse(_ data: Data) -> [[String?]]? {
        let reader = XMLRows()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        return parser.parse() ? reader.rows : nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement element: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        if element == "row" { row = [] }
        if element == "field" {
            inField = true
            field = attributes["xsi:nil"] == "true" ? nil : ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inField, let text = field { field = text + string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if element == "field" {
            row.append(field)
            inField = false
        }
        if element == "row" { rows.append(row) }
    }
}

// view|answer|base|keys|writable view:base pairs|read-only columns|operations
func report(_ view: String, _ answer: () throws -> PluginViewRowEditing?) {
    var fields: [String]
    do {
        switch try answer() {
        case nil:
            fields = ["not a view"]
        case .readOnly(let reason):
            fields = ["readOnly \(reason.rawValue)"]
        case .editable(let target):
            let base = [target.baseTable.database, target.baseTable.schema, target.baseTable.name]
                .compactMap { $0 }
                .joined(separator: ".")
            let keys = target.keyColumns.joined(separator: ",")
            let readOnly = target.readOnlyColumns.sorted().joined(separator: ",")
            let operations = [(PluginViewWriteOperations.update, "update"), (.insert, "insert"), (.delete, "delete")]
                .filter { target.operations.contains($0.0) }
                .map(\.1)
                .joined(separator: ",")
            let writable = target.baseColumnNames
                .filter { !target.readOnlyColumns.contains($0.key) }
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            fields = [
                "editable base=\(base) keys=\(keys) readonly=\(readOnly) ops=\(operations)",
                base, keys, writable, readOnly, operations,
            ]
        }
    } catch {
        fields = ["error: \(error)".split(whereSeparator: \.isNewline).joined(separator: " ")]
    }
    print(([view] + fields).joined(separator: "|"))
}
SWIFT

case "$ENGINE" in
    postgresql)
        CORE_MODULE=TableProPostgreSQLCore
        CORE_FILES=(
            "$CORE/TableProPostgreSQLCore/PostgreSQLCatalogBoolean.swift"
            "$CORE/TableProPostgreSQLCore/PostgreSQLCapabilities.swift"
            "$CORE/TableProPostgreSQLCore/PostgreSQLCatalogSearchPath.swift"
        )
        HARNESS_FILES+=("$PLUGINS/PostgreSQLDriverPlugin/PostgreSQLViewRowEditing.swift" "$WORK/harness/QuoteLiteral.swift")
        cat > "$WORK/harness/QuoteLiteral.swift" << 'SWIFT'
// PostgreSQLObjectQueries.quoteLiteral for names with no backslash or NUL; its own file needs most of PluginKit.
enum PostgreSQLObjectQueries {
    static func quoteLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
SWIFT
        cat > "$WORK/harness/main.swift" << 'SWIFT'
import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

let schema = CommandLine.arguments[1]
let capabilities = PostgreSQLCapabilities(serverVersion: Int32(CommandLine.arguments[2]) ?? 0)

// PostgreSQLPluginDriver.fetchViewRowEditing, with catalogRead's search path.
func rowEditing(view: String) throws -> PluginViewRowEditing? {
    guard capabilities.serverVersion >= PostgreSQLViewRowEditing.minimumServerVersion else { return nil }
    var chain: [PostgreSQLViewRowEditing.Relation] = []
    var query = PostgreSQLViewRowEditing.relationQuery(name: view, schema: schema)
    while true {
        let row = try catalogRows(PostgreSQLCatalogSearchPath.pinned + query).first
        switch PostgreSQLViewRowEditing.step(&chain, row: row) {
        case .notAView:
            return nil
        case .readOnly(let reason):
            return .readOnly(reason)
        case .readRelation(let oid):
            query = PostgreSQLViewRowEditing.relationQuery(oid: oid)
        case .readColumns(let viewOID, let baseOID, let baseSchema):
            let viewColumns = try catalogRows(
                PostgreSQLCatalogSearchPath.pinned + PostgreSQLViewRowEditing.viewColumnsQuery(viewOID: viewOID)
            )
            let baseColumns = try catalogRows(
                PostgreSQLCatalogSearchPath.relative(to: baseSchema)
                    + PostgreSQLViewRowEditing.baseColumnsQuery(baseOID: baseOID, capabilities: capabilities)
            )
            return PostgreSQLViewRowEditing.resolve(chain: chain, viewColumns: viewColumns, baseColumns: baseColumns)
        }
    }
}

for view in CommandLine.arguments.dropFirst(3) {
    report(view) { try rowEditing(view: view) }
}
SWIFT
        ;;
    mysql | mariadb)
        KIT_FILES+=("$PLUGINS/TableProPluginKit/PluginColumnInfo.swift")
        CORE_MODULE=TableProMySQLCore
        CORE_FILES=("$CORE/TableProMySQLCore/MySQLLiteralSQL.swift")
        HARNESS_FILES+=(
            "$PLUGINS/MySQLDriverPlugin/MySQLViewRowEditing.swift"
            "$PLUGINS/MySQLDriverPlugin/MySQLCatalogDefault.swift"
            "$PLUGINS/MySQLDriverPlugin/MySQLGeneratedColumnClassification.swift"
        )
        cat > "$WORK/harness/main.swift" << 'SWIFT'
import Foundation
import TableProMySQLCore
import TableProPluginKit

let database = CommandLine.arguments[1]
let flavor = CommandLine.arguments[2]
// MySQLServerVersion.quotesColumnDefault: MariaDB from 10.2.7, and this probe needs no older one.
let quotesDefaults = flavor == "mariadb"

// MySQLPluginDriver.fetchViewRowEditing.
func rowEditing(view: String) throws -> PluginViewRowEditing? {
    let escape = mysqlEscapeStringLiteral
    let topRows = try catalogRows(MySQLViewRowEditing.viewQuery(database: database, name: view, escape: escape))
    guard let top = MySQLViewRowEditing.view(rows: topRows) else { return nil }

    var levels: [MySQLViewRowEditing.Level] = []
    var next: MySQLViewRowEditing.View? = top
    while let current = next {
        guard levels.count < MySQLViewRowEditing.maximumDepth else { return .readOnly(.notUpdatable) }
        let columnRows = try catalogRows(MySQLViewRowEditing.columnsQuery(current.relation, escape: escape))
        switch try MySQLViewRowEditing.step(view: current, columnRows: columnRows) {
        case .readOnly(let reason):
            return .readOnly(reason)
        case .reads(let level):
            levels.append(level)
            let innerRows = try catalogRows(
                MySQLViewRowEditing.viewQuery(database: level.base.database, name: level.base.name, escape: escape)
            )
            next = MySQLViewRowEditing.view(rows: innerRows)
        }
    }

    guard let base = levels.last?.base else { return .readOnly(.notUpdatable) }
    let keyRows = try catalogRows(MySQLViewRowEditing.primaryKeyQuery(base, escape: escape))
    let baseColumnRows = try catalogRows(MySQLViewRowEditing.columnsQuery(base, escape: escape))
    return MySQLViewRowEditing.answer(
        levels: levels,
        keyRows: keyRows,
        columnRows: baseColumnRows,
        quotesDefaults: quotesDefaults,
        insertNeedsPlainColumns: flavor == "mysql"
    )
}

for view in CommandLine.arguments.dropFirst(3) {
    report(view) { try rowEditing(view: view) }
}
SWIFT
        ;;
    mssql)
        CORE_MODULE=TableProMSSQLCore
        CORE_FILES=(
            "$CORE/TableProMSSQLCore/MSSQLViewSources.swift"
            "$CORE/TableProMSSQLCore/MSSQLSchemaQueries.swift"
            "$CORE/TableProMSSQLCore/MSSQLStringLiteral.swift"
        )
        cat > "$WORK/harness/main.swift" << 'SWIFT'
import Foundation
import TableProMSSQLCore
import TableProPluginKit

let schema = CommandLine.arguments[1]

// MSSQLPluginDriver.fetchViewRowEditing.
func rowEditing(view: String) throws -> PluginViewRowEditing? {
    let factRows = try catalogRows(MSSQLViewSources.viewFactsQuery(schema: schema, view: view))
    guard let facts = MSSQLViewSources.ViewFacts(rows: factRows) else { return nil }
    if let refusal = facts.refusal { return .readOnly(reason(refusal)) }

    let browse = MSSQLViewSources.BrowseFacts(
        rows: try catalogRows(MSSQLViewSources.browseQuery(schema: schema, view: view))
    )
    let baseTable: MSSQLViewSources.BaseTable
    switch browse.source {
    case .refused(let refusal):
        return .readOnly(reason(refusal))
    case .table(let table):
        baseTable = table
    }

    let probeRows = try catalogRows(MSSQLViewSources.probesQuery(
        schema: schema,
        view: view,
        writableColumns: browse.writableColumns
    ))
    if let refusal = MSSQLViewSources.refusal(probeRows: probeRows) { return .readOnly(reason(refusal)) }
    let operations = MSSQLViewSources.allowedOperations(writableColumns: browse.writableColumns, probeRows: probeRows)
    let base = MSSQLViewSources.BaseFacts(rows: try catalogRows(MSSQLViewSources.baseColumnsQuery(baseTable)))

    return PluginViewRowEditing.resolve(
        operations: writeOperations(operations),
        baseTable: PluginViewBaseTable(database: baseTable.database, schema: baseTable.schema, name: baseTable.name),
        columns: browse.columns.map {
            PluginViewColumn(name: $0.name, baseColumn: $0.baseColumn, acceptsWrites: $0.acceptsWrites)
        },
        baseKeyColumns: base?.keyColumns,
        baseColumns: base?.columns.map {
            PluginViewBaseColumn(
                name: $0.name,
                isNullable: $0.isNullable,
                defaultValue: $0.defaultValue,
                assignsValue: $0.assignsValue,
                acceptsWrites: $0.acceptsWrites
            )
        }
    )
}

// The driver's two private conversions.
func reason(_ refusal: MSSQLViewSources.Refusal) -> PluginViewReadOnlyReason {
    switch refusal {
    case .notUpdatable: return .notUpdatable
    case .writesRunTriggers: return .writesRunTriggers
    case .readsSeveralTables: return .readsSeveralTables
    case .baseTableHidden: return .baseTableHidden
    case .couldNotCheck: return .couldNotCheck
    }
}

func writeOperations(_ operations: Set<MSSQLViewSources.Operation>) -> PluginViewWriteOperations {
    var result: PluginViewWriteOperations = []
    if operations.contains(.update) { result.insert(.update) }
    if operations.contains(.insert) { result.insert(.insert) }
    if operations.contains(.delete) { result.insert(.delete) }
    return result
}

for view in CommandLine.arguments.dropFirst(3) {
    report(view) { try rowEditing(view: view) }
}
SWIFT
        ;;
esac

build_module() {
    local name="$1"
    shift
    swiftc -parse-as-library -emit-library -static -emit-module -module-name "$name" -I "$WORK/modules" \
        -emit-module-path "$WORK/modules/$name.swiftmodule" -o "$WORK/lib$name.a" "$@"
}
if ! {
    build_module TableProPluginKit "${KIT_FILES[@]}" \
        && build_module "$CORE_MODULE" "${CORE_FILES[@]}" \
        && swiftc -I "$WORK/modules" -L "$WORK" -lTableProPluginKit -l"$CORE_MODULE" \
            -o "$WORK/harness/harness" "${HARNESS_FILES[@]}"
} > "$WORK/build.log" 2>&1; then
    echo "the harness failed to build:" >&2
    grep -E 'error:' "$WORK/build.log" | sort -u | head -20 >&2
    exit 1
fi

case "$ENGINE" in
    postgresql) out="$(sql postgres "CREATE DATABASE $DATABASE" 2>&1)" ;;
    mysql | mariadb) out="$(sql "" "CREATE DATABASE $DATABASE" 2>&1 && sql "" "CREATE DATABASE $OTHER" 2>&1)" ;;
    mssql) out="$(sql master "CREATE DATABASE [$DATABASE]" 2>&1 && sql master "CREATE DATABASE [$OTHER]" 2>&1)" ;;
esac
status=$?
CREATED=1
if [ "$status" -ne 0 ]; then
    echo "could not create $DATABASE: $out" >&2
    exit 3
fi

# EXPRESSION_OPS: what a view showing qty + 1 or the constant 1 beside plain columns allows. MySQL
# refuses any INSERT into it (1471); the others take one that names only the plain columns.
case "$ENGINE" in
    postgresql)
        CONTAINER=public Q_OPEN='"' Q_CLOSE='"'
        ELSEWHERE=elsewhere BASE=public.t OTHER_BASE=elsewhere.t2
        GENERATED="gen int GENERATED ALWAYS AS (qty * 2) STORED"
        EXPRESSION_OPS=update,insert,delete
        HARNESS_OPTION="$(sql postgres "SHOW server_version_num")"
        ;;
    mysql | mariadb)
        CONTAINER="$DATABASE" Q_OPEN='`' Q_CLOSE='`'
        ELSEWHERE="$OTHER" BASE="$DATABASE.t" OTHER_BASE="$OTHER.t2"
        GENERATED="gen int AS (qty * 2) STORED"
        # The flavor the driver reads from the banner, whichever engine name was given.
        case "$(sql "" "SELECT VERSION()")" in
            *MariaDB*) HARNESS_OPTION=mariadb EXPRESSION_OPS=update,insert,delete ;;
            *) HARNESS_OPTION=mysql EXPRESSION_OPS=update,delete ;;
        esac
        ;;
    mssql)
        CONTAINER=dbo Q_OPEN='[' Q_CLOSE=']'
        ELSEWHERE="$OTHER.dbo" BASE="$DATABASE.dbo.t" OTHER_BASE="$OTHER.dbo.t2"
        GENERATED="gen AS (qty * 2)"
        EXPRESSION_OPS=update,insert,delete
        HARNESS_OPTION=-
        ;;
esac
q() { printf '%s%s%s' "$Q_OPEN" "$1" "$Q_CLOSE"; }

# One statement per line: SQL Server needs CREATE VIEW and CREATE TRIGGER to open their own batch.
# The current database reuses the name t2 with another key, so a key read from the wrong catalog shows.
FIXTURE="CREATE TABLE t (id int PRIMARY KEY, name varchar(20), qty int NOT NULL DEFAULT 0, req varchar(20) NOT NULL, $GENERATED)
CREATE TABLE u (tid int)
CREATE TABLE k (name varchar(20), qty int)
CREATE TABLE t2 (id int, code int PRIMARY KEY)
CREATE TABLE $ELSEWHERE.t2 (id int PRIMARY KEY, code int NOT NULL)
INSERT INTO t (id, name, qty, req) VALUES (1, 'a', 1, 'r1')
INSERT INTO t (id, name, qty, req) VALUES (2, 'b', 2, 'r2')
INSERT INTO u (tid) VALUES (1)
INSERT INTO $ELSEWHERE.t2 (id, code) VALUES (1, 7)
INSERT INTO $ELSEWHERE.t2 (id, code) VALUES (2, 7)
CREATE VIEW v_all AS SELECT id, name, qty, req, gen FROM t
CREATE VIEW v_renamed AS SELECT id AS key_id, name AS label, qty AS amount, req FROM t
CREATE VIEW v_computed AS SELECT id, name, req, qty + 1 AS q2 FROM t
CREATE VIEW v_constant AS SELECT id, name, req, 1 AS c FROM t
CREATE VIEW v_hidden_key AS SELECT name, qty, req FROM t
CREATE VIEW v_join AS SELECT t.id, t.name, u.tid FROM t JOIN u ON u.tid = t.id
CREATE VIEW v_self_join AS SELECT m.id, m.name AS manager, e.name FROM t e JOIN t m ON m.id = e.qty
CREATE VIEW v_aggregate AS SELECT name, count(*) AS n FROM t GROUP BY name
CREATE VIEW v_distinct AS SELECT DISTINCT id, name FROM t
CREATE VIEW v_keyless AS SELECT name, qty FROM k
CREATE VIEW v_hidden_required AS SELECT id, name, qty FROM t
CREATE VIEW v_nested AS SELECT key_id, label AS title FROM v_renamed
CREATE VIEW v_elsewhere AS SELECT code, id FROM $ELSEWHERE.t2"

# PostgreSQL's DISTINCT and aggregate views read one table, so they fail its update check, not the table count.
EXPECTED="t|not a view
v_all|editable base=$BASE keys=id readonly=gen ops=update,insert,delete
v_renamed|editable base=$BASE keys=key_id readonly= ops=update,insert,delete
v_computed|editable base=$BASE keys=id readonly=q2 ops=$EXPRESSION_OPS
v_constant|editable base=$BASE keys=id readonly=c ops=$EXPRESSION_OPS
v_hidden_key|readOnly keyNotExposed
v_join|readOnly readsSeveralTables
v_aggregate|readOnly notUpdatable
v_distinct|readOnly notUpdatable
v_keyless|readOnly baseTableHasNoKey
v_hidden_required|editable base=$BASE keys=id readonly= ops=update,delete
v_nested|editable base=$BASE keys=key_id readonly= ops=update,delete
v_elsewhere|editable base=$OTHER_BASE keys=id readonly= ops=update,insert,delete"

case "$ENGINE" in
    postgresql)
        FIXTURE="CREATE SCHEMA elsewhere
$FIXTURE
CREATE VIEW v_rule AS SELECT id, name FROM t
CREATE RULE r_rule AS ON UPDATE TO v_rule DO INSTEAD UPDATE t SET name = upper(NEW.name) WHERE id = OLD.id
CREATE FUNCTION f_trigger() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RETURN NEW; END'
CREATE VIEW v_trigger AS SELECT id, name FROM t
CREATE TRIGGER tr_trigger INSTEAD OF UPDATE ON v_trigger FOR EACH ROW EXECUTE FUNCTION f_trigger()"
        EXPECTED="$EXPECTED
v_self_join|readOnly notUpdatable
v_rule|readOnly writesRunTriggers
v_trigger|readOnly writesRunTriggers"
        ;;
    mysql | mariadb)
        # A column list renames by position: v_columns.name shows t.id.
        FIXTURE="$FIXTURE
CREATE VIEW v_columns (name, id, qty, req) AS SELECT id, name, qty, req FROM t"
        EXPECTED="$EXPECTED
v_self_join|readOnly readsSeveralTables
v_columns|editable base=$BASE keys=name readonly= ops=update,insert,delete"
        ;;
    mssql)
        FIXTURE="$FIXTURE
CREATE VIEW v_trigger AS SELECT id, name FROM t
CREATE TRIGGER tr_trigger ON v_trigger INSTEAD OF UPDATE AS BEGIN SET NOCOUNT ON; END
CREATE VIEW v_metadata WITH VIEW_METADATA AS SELECT id, name FROM t"
        EXPECTED="$EXPECTED
v_self_join|readOnly readsSeveralTables
v_trigger|readOnly writesRunTriggers
v_metadata|readOnly baseTableHidden"
        ;;
esac

while IFS= read -r line; do
    if ! out="$(sql "$DATABASE" "$line" 2>&1)"; then
        echo "fixture failed: $line: $out" >&2
        exit 3
    fi
done <<< "$FIXTURE"

{
    echo '#!/usr/bin/env bash'
    declare -p ENGINE HOST PORT USER_NAME PASSWORD DATABASE WORK
    [ -n "${MYSQL_CLIENT:-}" ] && declare -p MYSQL_CLIENT
    declare -f sql
    echo 'sql "$DATABASE" "$(cat)" catalog'
} > "$WORK/catalog.sh"
chmod +x "$WORK/catalog.sh"

pass() {
    CHECKS=$((CHECKS + 1))
    echo "  ok    $1"
}
fail() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    echo "  FAIL  $1"
}
# The mariadb client repeats a failed statement between dashed lines before its error.
one_line() {
    local text
    text="$(printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ')"
    printf '%s' "${text##*-------------- }" | cut -c 1-140
}

echo "Checking view row editing on $ENGINE at $HOST:$PORT"
echo "Answers"
ANSWERS="$(PROBE_ENGINE="$ENGINE" PROBE_CATALOG="$WORK/catalog.sh" "$WORK/harness/harness" \
    "$CONTAINER" "$HARNESS_OPTION" $(printf '%s\n' "$EXPECTED" | cut -d '|' -f 1) 2> "$WORK/harness.log")"
[ -s "$WORK/harness.log" ] && sed 's/^/  harness: /' "$WORK/harness.log"
EDITABLE=""
while IFS='|' read -r view expected; do
    line="$(printf '%s\n' "$ANSWERS" | awk -F '|' -v view="$view" '$1 == view')"
    if [ -z "$line" ]; then
        fail "$view: no answer from the harness"
        continue
    fi
    IFS='|' read -r _ answer _ <<< "$line"
    if [ "$answer" = "$expected" ]; then
        pass "$view: $answer"
    else
        fail "$view: expected $expected, got $answer"
    fi
    case "$answer" in editable*) EDITABLE="$EDITABLE$line"$'\n' ;; esac
done <<< "$EXPECTED"

snapshot() { sql "$DATABASE" "SELECT * FROM $1 ORDER BY id"; }

# Lines of $2 that $1 lacks.
lines_only_in() {
    LC_ALL=C comm -13 <(printf '%s\n' "$1" | LC_ALL=C sort) <(printf '%s\n' "$2" | LC_ALL=C sort) | grep -v '^$'
}

count_lines() { printf '%s' "$1" | grep -c '^'; }

key_clause() {
    local clause="" key
    for key in ${1//,/ }; do
        clause="${clause:+$clause AND }$(q "$key") = $2"
    done
    printf '%s' "$clause"
}

# Every key in the fixture is t.id or t2.id, so row n is keyed by n.
value_for() {
    case "$1" in
        id | qty | code) printf '%s' "$2" ;;
        *) printf "'w%s'" "$2" ;;
    esac
}

# Runs a write, then checks the base table $2: $4 rows gone, $5 rows new, every one of them row $6.
expect_change() {
    local label="$1" base="$2" statement="$3" removed="$4" added="$5" id="$6"
    local before after error gone new rows
    before="$(snapshot "$base")"
    if ! error="$(sql "$DATABASE" "$statement" 2>&1 > /dev/null)"; then
        fail "$label: $(one_line "$error")"
        return 1
    fi
    after="$(snapshot "$base")"
    gone="$(lines_only_in "$after" "$before")"
    new="$(lines_only_in "$before" "$after")"
    rows="$(printf '%s\n%s\n' "$gone" "$new" | grep -v '^$' | cut -d $'\x1f' -f 1 | sort -u | tr '\n' ' ')"
    if [ "$(count_lines "$gone")" = "$removed" ] && [ "$(count_lines "$new")" = "$added" ] && [ "$rows" = "$id " ]; then
        pass "$label"
        return 0
    fi
    fail "$label: $(count_lines "$gone") rows gone, $(count_lines "$new") new, ids ${rows:-none}"
    return 1
}

expect_value() {
    local label="$1" statement="$2" expected="$3" actual
    actual="$(sql "$DATABASE" "$statement" 2>&1)"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label: expected '$expected', got '$actual'"
    fi
}

expect_refusal() {
    local label="$1" statement="$2" error
    if error="$(sql "$DATABASE" "$statement" 2>&1 > /dev/null)"; then
        fail "$label: the server accepted it"
    else
        pass "$label: $(one_line "$error")"
    fi
}

# Puts row $2 straight into the base table, for a DELETE through a view that cannot INSERT.
seed() {
    case "${1##*.}" in
        t2) sql "$DATABASE" "INSERT INTO $1 (id, code) VALUES ($2, $2)" ;;
        *) sql "$DATABASE" "INSERT INTO $1 (id, name, qty, req) VALUES ($2, 'w$2', $2, 'w$2')" ;;
    esac
}

# The statements the grid builds: SET and VALUES over the columns it may write, WHERE over the key.
check_writes() {
    local view="$1" base="$2" keys="$3" writable="$4" readonly="$5" ops="$6"
    local pair column="" base_column="" value columns="" values="" id target="" error

    for pair in ${writable//,/ }; do
        case ",$keys," in *",${pair%%:*},"*) continue ;; esac
        column="${pair%%:*}" base_column="${pair#*:}"
        break
    done
    if [ -z "$column" ]; then
        fail "$view: no writable column outside the key to UPDATE"
    else
        NEXT=$((NEXT + 1))
        value="$(value_for "$base_column" "$NEXT")"
        if expect_change "$view: UPDATE of $column keyed on $keys changes base row 2 only" "$base" \
            "UPDATE $(q "$view") SET $(q "$column") = $value WHERE $(key_clause "$keys" 2)" 1 1 2; then
            expect_value "$view: base row 2 holds $value in $base_column" \
                "SELECT $base_column FROM $base WHERE id = 2" "${value//\'/}"
        fi
    fi

    NEXT=$((NEXT + 1))
    id=$NEXT
    for pair in ${writable//,/ }; do
        columns="${columns:+$columns, }$(q "${pair%%:*}")"
        values="${values:+$values, }$(value_for "${pair#*:}" "$id")"
    done
    case ",$ops," in
        *,insert,*)
            expect_change "$view: INSERT adds base row $id only" "$base" \
                "INSERT INTO $(q "$view") ($columns) VALUES ($values)" 0 1 "$id" && target="$id"
            ;;
        *) expect_refusal "$view: the server refuses the INSERT too" "INSERT INTO $(q "$view") ($columns) VALUES ($values)" ;;
    esac

    case ",$ops," in
        *,delete,*)
            if [ -z "$target" ]; then
                NEXT=$((NEXT + 1))
                target=$NEXT
                if ! error="$(seed "$base" "$target" 2>&1 > /dev/null)"; then
                    fail "$view: could not seed row $target for the DELETE: $(one_line "$error")"
                    target=""
                fi
            fi
            [ -n "$target" ] && expect_change "$view: DELETE keyed on $keys removes base row $target only" "$base" \
                "DELETE FROM $(q "$view") WHERE $(key_clause "$keys" "$target")" 1 0 "$target"
            ;;
        *) expect_refusal "$view: the server refuses the DELETE too" "DELETE FROM $(q "$view") WHERE $(key_clause "$keys" 2)" ;;
    esac

    # Assigning a column its own value still has to be refused.
    for column in ${readonly//,/ }; do
        expect_refusal "$view: the server refuses an UPDATE of read-only $column" \
            "UPDATE $(q "$view") SET $(q "$column") = $(q "$column") WHERE $(key_clause "$keys" 2)"
    done
}

echo "Writes through the editable views"
while IFS='|' read -r view _ base keys writable readonly ops; do
    [ -n "$view" ] && check_writes "$view" "$base" "$keys" "$writable" "$readonly" "$ops"
done <<< "$EDITABLE"

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES of $CHECKS checks failed"
    exit 1
fi
echo "All $CHECKS checks passed"
