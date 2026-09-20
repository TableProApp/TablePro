#!/usr/bin/env bash
#
# Check the curated SQL lexical grammars against real servers.
#
# Packages/TableProCore/Sources/TableProSQLGrammar/SQLLexicalProfile.swift says, per engine, where a string, a quoted
# identifier and a comment end. The Safe Mode and external gates count statements with it, so a fact that is wrong
# there lets a server run a statement the gate never saw. This sends texts that hide a DROP behind one lexical trick
# each, as one call per text, and checks that the server ran the hidden DROP exactly when the grammar splits the text
# into more than one statement. The corpus is the one TableProSQLGrammarTests pins.
#
# Usage:
#   scripts/check-sql-lexical-grammar.sh [engine...]      engines: postgresql mysql mariadb sqlserver sqlite duckdb
#
# Each server engine is skipped unless its connection is set in the environment:
#   PG_URL           postgresql://postgres:probe@127.0.0.1:15432/postgres        (psql, one simple Query per call)
#   MYSQL_ARGS       "-h 127.0.0.1 -P 13306 -uroot -pprobe probe"                   (mysql client, one COM_QUERY)
#   MARIADB_ARGS     "-h 127.0.0.1 -P 13307 -uroot -pprobe probe"                   (mariadb client, one COM_QUERY)
#   MSSQL_ARGS       "-H 127.0.0.1 -p 14333 -U sa -P Probe_pw1234"                  (FreeTDS tsql, one batch)
# SQLite and DuckDB run against throwaway files with the sqlite3 and duckdb command line tools.
#
# Throwaway servers that match those defaults:
#   docker run -d --name lexer-pg -p 15432:5432 -e POSTGRES_PASSWORD=probe postgres:17-alpine
#   docker run -d --name lexer-mysql -p 13306:3306 -e MYSQL_ROOT_PASSWORD=probe -e MYSQL_DATABASE=probe mysql:8.4
#   docker run -d --name lexer-mariadb -p 13307:3306 -e MARIADB_ROOT_PASSWORD=probe -e MARIADB_DATABASE=probe mariadb:11
#   docker run -d --name lexer-mssql -p 14333:1433 -e ACCEPT_EULA=1 -e MSSQL_SA_PASSWORD=Probe_pw1234 \
#     mcr.microsoft.com/azure-sql-edge:latest
#
# Exits non-zero on a disagreement, 3 when nothing could be checked.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINES=("$@")
if [ ${#ENGINES[@]} -eq 0 ]; then
    ENGINES=(postgresql mysql mariadb sqlserver sqlite duckdb)
fi

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
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .executableTarget(
            name: "Probe",
            dependencies: [.product(name: "TableProSQLGrammar", package: "TableProCore")]
        )
    ]
)
EOF

cat > "$WORK/Sources/Probe/main.swift" <<'EOF'
import Foundation
import TableProSQLGrammar

while let line = readLine() {
    let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard fields.count == 2, let data = Data(base64Encoded: fields[1]), let sql = String(data: data, encoding: .utf8)
    else {
        print("?")
        continue
    }
    let grammar = SQLLexicalReadings.resolve(databaseTypeId: fields[0], declared: nil, session: nil).execution
    print(SQLStatementScanner.executableStatements(in: sql, grammar: grammar).count)
}
EOF

echo "Building the probe against Packages/TableProCore (the first build takes a minute)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 3
}
PROBE="$WORK/.build/debug/Probe"

CASE_NAMES=(
    "literal backslash"
    "nested comment"
    "bracketed identifier"
    "dollar-quoted body"
    "non-ASCII dollar tag"
    "E'' literal"
    "hash comment"
    "backslash escape"
    "doubled bracket"
    "carriage return in --"
    "-- with no space"
    "SQLite parameter"
    "dollars glued to an identifier"
    "dollars glued to a non-ASCII identifier"
)
CASE_SQL=(
    "SELECT 'C:\\' AS p; DROP TABLE lexer_canary"
    "SELECT 1 /* /* */ ' */; DROP TABLE lexer_canary; --'"
    "SELECT [it's] FROM lexer_t; DROP TABLE lexer_canary; SELECT 'x'"
    "SELECT \$\$it's\$\$; DROP TABLE lexer_canary; SELECT 'x'"
    "SELECT \$ü\$it's\$ü\$; DROP TABLE lexer_canary; SELECT 'x'"
    "SELECT E'\\''; DROP TABLE lexer_canary; --'"
    $'SELECT 1 # \'\n; DROP TABLE lexer_canary; -- \''
    "SELECT 'a\\'; DROP TABLE lexer_canary; -- '"
    "SELECT 1 AS [a]]'b]; DROP TABLE lexer_canary; SELECT 'x'"
    $'SELECT 1 -- x\r; DROP TABLE lexer_canary'
    "SELECT 1 --1; DROP TABLE lexer_canary"
    "SELECT \$a('); DROP TABLE lexer_canary; --'"
    "SELECT 1 AS x\$\$; DROP TABLE lexer_canary; --\$\$"
    "SELECT 1 AS é\$\$; DROP TABLE lexer_canary; --\$\$"
)

SQLITE_DB="$WORK/lexer.sqlite"
DUCKDB_DB="$WORK/lexer.duckdb"

type_id() {
    case "$1" in
        postgresql) echo "PostgreSQL" ;;
        mysql) echo "MySQL" ;;
        mariadb) echo "MariaDB" ;;
        sqlserver) echo "SQL Server" ;;
        sqlite) echo "SQLite" ;;
        duckdb) echo "DuckDB" ;;
    esac
}

available() {
    case "$1" in
        postgresql) [ -n "${PG_URL:-}" ] && command -v psql > /dev/null ;;
        mysql) [ -n "${MYSQL_ARGS:-}" ] && command -v mysql > /dev/null ;;
        mariadb) [ -n "${MARIADB_ARGS:-}" ] && command -v mariadb > /dev/null ;;
        sqlserver) [ -n "${MSSQL_ARGS:-}" ] && command -v tsql > /dev/null ;;
        sqlite) command -v sqlite3 > /dev/null ;;
        duckdb) command -v duckdb > /dev/null ;;
        *) return 1 ;;
    esac
}

read -r -a MYSQL_ARGV <<< "${MYSQL_ARGS:-}"
read -r -a MARIADB_ARGV <<< "${MARIADB_ARGS:-}"
read -r -a MSSQL_ARGV <<< "${MSSQL_ARGS:-}"

run_sql() {
    local engine="$1" sql="$2"
    case "$engine" in
        postgresql) psql "$PG_URL" -X -q -v ON_ERROR_STOP=0 -c "$sql" > /dev/null 2>&1 ;;
        mysql) mysql "${MYSQL_ARGV[@]}" --comments --delimiter='@@@@' -e "$sql" > /dev/null 2>&1 ;;
        mariadb) mariadb "${MARIADB_ARGV[@]}" --comments --delimiter='@@@@' -e "$sql" > /dev/null 2>&1 ;;
        sqlserver) printf '%s\ngo\n' "$sql" | tsql "${MSSQL_ARGV[@]}" > /dev/null 2>&1 ;;
        sqlite) sqlite3 "$SQLITE_DB" "$sql" > /dev/null 2>&1 ;;
        duckdb) duckdb "$DUCKDB_DB" -c "$sql" > /dev/null 2>&1 ;;
    esac
}

canary_exists() {
    local engine="$1" answer=""
    local catalog="SELECT count(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'lexer_canary'"
    case "$engine" in
        postgresql)
            answer=$(psql "$PG_URL" -X -qAt -c "SELECT count(*) FROM pg_tables WHERE tablename = 'lexer_canary'") ;;
        mysql) answer=$(mysql "${MYSQL_ARGV[@]}" -N -e "$catalog" 2> /dev/null) ;;
        mariadb) answer=$(mariadb "${MARIADB_ARGV[@]}" -N -e "$catalog" 2> /dev/null) ;;
        sqlserver)
            answer=$(printf "SELECT CASE WHEN OBJECT_ID('lexer_canary') IS NULL THEN 'gone' ELSE 'kept' END\ngo\n" \
                | tsql "${MSSQL_ARGV[@]}" 2> /dev/null | grep -Eo 'gone|kept' | tail -1)
            if [ "$answer" = "kept" ]; then answer=1; else answer=0; fi ;;
        sqlite)
            answer=$(sqlite3 "$SQLITE_DB" "SELECT count(*) FROM sqlite_master WHERE name = 'lexer_canary'") ;;
        duckdb)
            answer=$(duckdb "$DUCKDB_DB" -noheader -list -c \
                "SELECT count(*) FROM duckdb_tables() WHERE table_name = 'lexer_canary'") ;;
    esac
    [ "$(echo "$answer" | tr -d '[:space:]')" = "1" ]
}

prepare() {
    local engine="$1" column
    case "$engine" in
        sqlserver) column="[it's]" ;;
        mysql | mariadb) column="\`it's\`" ;;
        *) column="\"it's\"" ;;
    esac
    run_sql "$engine" "DROP TABLE IF EXISTS lexer_canary"
    run_sql "$engine" "CREATE TABLE lexer_canary (a INT)"
    run_sql "$engine" "DROP TABLE IF EXISTS lexer_t"
    run_sql "$engine" "CREATE TABLE lexer_t ($column INT)"
}

checked=0
disagreements=0
for engine in "${ENGINES[@]}"; do
    if ! available "$engine"; then
        echo "skip $engine: no connection or client"
        continue
    fi
    id="$(type_id "$engine")"
    for index in "${!CASE_SQL[@]}"; do
        sql="${CASE_SQL[$index]}"
        predicted=$(printf '%s\t%s\n' "$id" "$(printf '%s' "$sql" | base64)" | "$PROBE")
        prepare "$engine"
        run_sql "$engine" "$sql"
        if canary_exists "$engine"; then ran=0; else ran=1; fi
        expected=0
        [ "$predicted" -gt 1 ] && expected=1
        checked=$((checked + 1))
        if [ "$ran" -eq "$expected" ]; then
            mark="ok  "
        else
            mark="FAIL"
            disagreements=$((disagreements + 1))
        fi
        verdict="the hidden DROP did not run"
        [ "$ran" -eq 1 ] && verdict="the hidden DROP ran"
        echo "$mark $engine ${CASE_NAMES[$index]}: grammar splits into $predicted, $verdict"
    done
    run_sql "$engine" "DROP TABLE IF EXISTS lexer_canary"
    run_sql "$engine" "DROP TABLE IF EXISTS lexer_t"
done

if [ "$checked" -eq 0 ]; then
    echo "Nothing was checked."
    exit 3
fi
echo "$checked checks, $disagreements disagreement(s)."
[ "$disagreements" -eq 0 ]
