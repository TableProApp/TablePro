#!/usr/bin/env bash
#
# Check that SQL Server's all-schema table listing lists exactly what the per-schema listing does.
#
# Open Quickly and the sidebar filter find tables in schemas nobody has opened through one query,
# MSSQLSchemaQueries.tables(in: .allSchemas). The sidebar lists each schema through
# tables(in: .schema(name)), for every schema MSSQLSchemaQueries.schemas returns. The two have to
# agree row for row: a table the one-schema listing shows and the search cannot find is the bug
# this listing exists to fix, and one the search finds that the sidebar hides is a result that
# opens nothing.
#
# This builds a database with every shape the listing treats specially (a view, an empty schema,
# mixed-case and dotted names, a schema the reader holds no permission on, tables in the role and
# guest schemas the schema list leaves out), once under the server's default collation and once
# under a case-sensitive one, prints the plugin's real queries from TableProMSSQLCore, and compares
# the two listings as the server administrator and as a login with only SELECT grants. Then it
# times the per-schema listing against the single query over one connection on a database with
# many schemas.
#
# Usage:
#   scripts/check-mssql-table-listing-parity.sh [host] [port] [user] [password]
#
# Needs FreeTDS's tsql and a SQL Server the user may create a database and a login on. A throwaway
# server that matches the defaults:
#   docker run -d --name listing-mssql -p 1433:1433 -e ACCEPT_EULA=1 -e MSSQL_SA_PASSWORD=Probe_pw1234 \
#     mcr.microsoft.com/azure-sql-edge:latest
# Exits non-zero on a disagreement, 3 when a prerequisite is missing.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1433}"
ADMIN="${3:-sa}"
ADMIN_PASSWORD="${4:-Probe_pw1234}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Named per run and dropped only when this run created them, so pointing the check at a shared
# server cannot touch anything that was already there.
RUN_ID="$$_$RANDOM"
READER="tablepro_listing_reader_$RUN_ID"
READER_PASSWORD="Reader_pw_${RUN_ID}_X9"
DATABASES=()
CREATED_READER=0
WORK="$(mktemp -d)"

admin_sql() {
    printf '%s\ngo\n' "$2" | tsql -H "$HOST" -p "$PORT" -U "$ADMIN" -P "$ADMIN_PASSWORD" -D "$1" -o fhq -t '|' 2>&1
}

cleanup() {
    local database
    for database in "${DATABASES[@]+"${DATABASES[@]}"}"; do
        admin_sql master "ALTER DATABASE [$database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$database]" > /dev/null
    done
    if [ "$CREATED_READER" -eq 1 ]; then
        admin_sql master "DROP LOGIN [$READER]" > /dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

command -v tsql > /dev/null || {
    echo "tsql not found (brew install freetds)" >&2
    exit 3
}
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p)"
    case "$DEVELOPER_DIR" in
        *CommandLineTools*) DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
    esac
fi
export DEVELOPER_DIR

if ! admin_sql master "SELECT 1" | grep -qx '1'; then
    echo "no SQL Server at $HOST:$PORT as $ADMIN" >&2
    exit 3
fi

mkdir -p "$WORK/Sources/ListingSQL"
cat > "$WORK/Package.swift" << EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ListingSQL",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .executableTarget(
            name: "ListingSQL",
            dependencies: [.product(name: "TableProMSSQLCore", package: "TableProCore")]
        )
    ]
)
EOF
cat > "$WORK/Sources/ListingSQL/main.swift" << 'SWIFT'
import TableProMSSQLCore

let arguments = CommandLine.arguments
switch arguments[1] {
case "schemas":
    print(MSSQLSchemaQueries.schemas)
case "one":
    print(MSSQLSchemaQueries.tables(in: .schema(arguments[2])))
default:
    print(MSSQLSchemaQueries.tables(in: .allSchemas))
}
SWIFT
swift build --package-path "$WORK" > "$WORK/build.log" 2>&1 || {
    echo "the query printer failed to build:" >&2
    grep -E 'error:' "$WORK/build.log" | sort -u | head -20 >&2
    exit 3
}
PRINTER="$(swift build --package-path "$WORK" --show-bin-path)/ListingSQL"

VERSION="$(admin_sql master "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64))" | head -1)"
echo "Checking the all-schema table listing against SQL Server $VERSION at $HOST:$PORT"

admin_sql master "CREATE LOGIN [$READER] WITH PASSWORD = '$READER_PASSWORD', CHECK_POLICY = OFF" | grep -E 'Msg [0-9]+' && exit 3
CREATED_READER=1

# One batch per line: CREATE SCHEMA and CREATE VIEW must each open their own batch.
FIXTURE="CREATE SCHEMA sales
CREATE SCHEMA [Mixed Case]
CREATE SCHEMA [dot.ted]
CREATE SCHEMA empty_schema
CREATE SCHEMA locked
CREATE TABLE dbo.people (id int); CREATE TABLE sales.orders (id int); CREATE TABLE [Mixed Case].[Orders] (id int); CREATE TABLE [dot.ted].[a.b] (id int)
CREATE TABLE locked.secret (id int); CREATE TABLE locked.visible (id int)
CREATE TABLE db_datareader.in_role_schema (id int); CREATE TABLE guest.in_guest_schema (id int)
CREATE VIEW sales.v_orders AS SELECT id FROM sales.orders
CREATE USER [$READER] FOR LOGIN [$READER]
GRANT SELECT ON SCHEMA::dbo TO [$READER]; GRANT SELECT ON SCHEMA::sales TO [$READER]; GRANT SELECT ON SCHEMA::[Mixed Case] TO [$READER]; GRANT SELECT ON SCHEMA::[dot.ted] TO [$READER]
GRANT SELECT ON OBJECT::locked.visible TO [$READER]; GRANT SELECT ON OBJECT::db_datareader.in_role_schema TO [$READER]"

create_database() {
    local database="$1" collation="$2"
    admin_sql master "CREATE DATABASE [$database] $collation" | grep -E 'Msg [0-9]+' && return 1
    DATABASES+=("$database")
    local line
    while IFS= read -r line; do
        admin_sql "$database" "$line" | grep -E 'Msg [0-9]+' && return 1
    done <<< "$FIXTURE"
    return 0
}

# Every row as schema|name|type, in the same shape for both listings.
listings() {
    local database="$1" user="$2" password="$3" schema
    : > "$WORK/one.txt"
    printf '%s\ngo\n' "$("$PRINTER" schemas)" \
        | tsql -H "$HOST" -p "$PORT" -U "$user" -P "$password" -D "$database" -o fhq -t '|' > "$WORK/schemas.txt" 2>&1
    while IFS= read -r schema; do
        [ -n "$schema" ] || continue
        printf '%s\ngo\n' "$("$PRINTER" one "$schema")" \
            | tsql -H "$HOST" -p "$PORT" -U "$user" -P "$password" -D "$database" -o fhq -t '|' 2>&1 \
            | while IFS='|' read -r name type; do
                printf '%s|%s|%s\n' "$schema" "$name" "$type"
            done >> "$WORK/one.txt"
    done < "$WORK/schemas.txt"
    printf '%s\ngo\n' "$("$PRINTER" all)" \
        | tsql -H "$HOST" -p "$PORT" -U "$user" -P "$password" -D "$database" -o fhq -t '|' 2>&1 \
        | while IFS='|' read -r name type schema; do
            printf '%s|%s|%s\n' "$schema" "$name" "$type"
        done > "$WORK/all.txt"
    sort -o "$WORK/one.txt" "$WORK/one.txt"
    sort -o "$WORK/all.txt" "$WORK/all.txt"
}

FAILURES=0
check() {
    local label="$1" database="$2" user="$3" password="$4"
    listings "$database" "$user" "$password"
    if grep -q 'Msg [0-9]' "$WORK/one.txt" "$WORK/all.txt"; then
        echo "FAIL $label: the server rejected a listing query" >&2
        grep -h 'Msg [0-9]' "$WORK/one.txt" "$WORK/all.txt" | sort -u >&2
        FAILURES=$((FAILURES + 1))
        return
    fi
    if diff -u "$WORK/one.txt" "$WORK/all.txt" > "$WORK/diff.txt"; then
        echo "$label: $(wc -l < "$WORK/all.txt" | tr -d ' ') objects, listings agree"
    else
        echo "FAIL $label: per-schema (-) and all-schema (+) listings differ" >&2
        cat "$WORK/diff.txt" >&2
        FAILURES=$((FAILURES + 1))
    fi
    local expected
    for expected in "sales|orders|BASE TABLE" "sales|v_orders|VIEW" "Mixed Case|Orders|BASE TABLE" "dot.ted|a.b|BASE TABLE" "locked|visible|BASE TABLE"; do
        grep -qxF "$expected" "$WORK/all.txt" || {
            echo "FAIL $label: the all-schema listing is missing $expected" >&2
            FAILURES=$((FAILURES + 1))
        }
    done
    if grep -qE '^(db_datareader|guest)\|' "$WORK/all.txt"; then
        echo "FAIL $label: the all-schema listing shows a schema the schema list leaves out" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

for collation in "" "COLLATE Latin1_General_CS_AS"; do
    database="tablepro_listing_parity_${RUN_ID}_${#DATABASES[@]}"
    create_database "$database" "$collation" || {
        echo "could not build the fixture in $database" >&2
        exit 3
    }
    label="${collation:-default collation}"
    check "$label, $ADMIN" "$database" "$ADMIN" "$ADMIN_PASSWORD"
    check "$label, reader" "$database" "$READER" "$READER_PASSWORD"
    if grep -q '^locked|secret|' "$WORK/all.txt"; then
        echo "FAIL $label: the reader's all-schema listing shows a table it holds no permission on" >&2
        FAILURES=$((FAILURES + 1))
    fi
done

# Round trips on one connection: one batch per schema against the single query.
SCHEMA_COUNT=300
database="tablepro_listing_parity_${RUN_ID}_timing"
admin_sql master "CREATE DATABASE [$database]" | grep -E 'Msg [0-9]+' && exit 3
DATABASES+=("$database")
{
    for ((i = 0; i < SCHEMA_COUNT; i++)); do
        printf 'CREATE SCHEMA s%03d\ngo\nCREATE TABLE s%03d.a (id int); CREATE TABLE s%03d.b (id int)\ngo\n' "$i" "$i" "$i"
    done
} | tsql -H "$HOST" -p "$PORT" -U "$ADMIN" -P "$ADMIN_PASSWORD" -D "$database" -o fhq > /dev/null 2>&1
admin_sql "$database" "$("$PRINTER" schemas)" > "$WORK/timing-schemas.txt"
while IFS= read -r schema; do
    printf '%s\ngo\n' "$("$PRINTER" one "$schema")"
done < "$WORK/timing-schemas.txt" > "$WORK/per-schema.sql"
printf '%s\ngo\n' "$("$PRINTER" all)" > "$WORK/all-schemas.sql"
elapsed() {
    local start end
    start="$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')"
    tsql -H "$HOST" -p "$PORT" -U "$ADMIN" -P "$ADMIN_PASSWORD" -D "$database" -o fhq < "$1" > "$2" 2>&1
    end="$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000')"
    echo $((end - start))
}
PER_SCHEMA_MS="$(elapsed "$WORK/per-schema.sql" "$WORK/per-schema.out")"
ALL_SCHEMAS_MS="$(elapsed "$WORK/all-schemas.sql" "$WORK/all-schemas.out")"
echo "$(wc -l < "$WORK/timing-schemas.txt" | tr -d ' ') schemas: per-schema $(grep -c . "$WORK/per-schema.out") rows in ${PER_SCHEMA_MS} ms, all-schema $(grep -c . "$WORK/all-schemas.out") rows in ${ALL_SCHEMAS_MS} ms (one connection each)"

[ "$FAILURES" -eq 0 ] || exit 1
echo "PASS"
