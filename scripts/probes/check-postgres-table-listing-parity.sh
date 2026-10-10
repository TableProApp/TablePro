#!/usr/bin/env bash
#
# Check that PostgreSQL's all-schema and schema-set table listings list exactly what the
# per-schema listing does, and what the listing listed before it moved off information_schema.
#
# The sidebar lists each schema through .schema(name); Open Quickly and search use .allSchemas; the
# export dialog and the schema filter use .schemas(names). All three have to agree row for row on
# every rung of PostgreSQLTableListingLadder: a table one listing shows and another hides is a
# search that finds nothing, or a result that opens nothing. Against the pre-change listing, frozen
# below, the only row allowed to go is a materialized view the role holds no privilege on.
#
# This builds a database with every shape the listing treats specially (declarative partitions,
# a partition in another schema than its parent, legacy inheritance, a materialized view, a
# foreign table, a schema the role cannot use, quoted names with dots and mixed case), compiles
# the plugin's real query builders into a small harness, and compares the listings as the owner
# and as a role with ordinary privileges. It also reads database metadata for the connected
# database, another one, and one the role may not connect to.
#
# Usage:
#   scripts/probes/check-postgres-table-listing-parity.sh [host] [port] [user]
#
# Needs psql, a reachable PostgreSQL 10 or newer the user may create a database and a role on, and
# a Debug build of TableProPluginKit in DerivedData (run verify.sh build first). Exits non-zero on
# a disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
USER_NAME="${3:-postgres}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Named per run and never dropped unless this run created them, so pointing the check at a shared
# server cannot touch anything that was already there, and two runs cannot remove each other's.
RUN_ID="$$_$RANDOM"
DATABASE="tablepro_listing_parity_$RUN_ID"
CLOSED_DATABASE="tablepro_listing_closed_$RUN_ID"
READER="tablepro_listing_reader_$RUN_ID"
CREATED_DATABASE=0
CREATED_CLOSED_DATABASE=0
CREATED_READER=0
WORK="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK"
    if [ "$CREATED_DATABASE" -eq 1 ]; then
        psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE $DATABASE" > /dev/null 2>&1
    fi
    if [ "$CREATED_CLOSED_DATABASE" -eq 1 ]; then
        psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE $CLOSED_DATABASE" > /dev/null 2>&1
    fi
    if [ "$CREATED_READER" -eq 1 ]; then
        psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP ROLE $READER" > /dev/null 2>&1
    fi
}
trap cleanup EXIT

command -v psql > /dev/null || {
    echo "psql not found" >&2
    exit 3
}

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR
FRAMEWORK_DIR="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path '*/Build/Products/Debug/TableProPluginKit.framework' -print 2> /dev/null \
    | while read -r path; do echo "$(stat -f %m "$path") $(dirname "$path")"; done \
    | sort -rn | head -1 | cut -d' ' -f2-)"
[ -n "$FRAMEWORK_DIR" ] || {
    echo "no Debug TableProPluginKit.framework in DerivedData; build the app first" >&2
    exit 3
}

psql_do() {
    psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$1" -v ON_ERROR_STOP=1 "${@:2}"
}

if ! psql_do postgres -Atc "SELECT 1" > /dev/null 2>&1; then
    echo "no PostgreSQL at $HOST:$PORT as $USER_NAME" >&2
    exit 3
fi

# The same plugin sources the test target compiles, read out of project.yml so the list cannot
# drift from what the tests exercise.
SOURCES=()
while IFS= read -r source; do
    SOURCES+=("$ROOT/$source")
done < <(grep -oE 'Plugins/PostgreSQLDriverPlugin/[A-Za-z+]+\.swift' "$ROOT/project.yml" | sort -u)

cat > "$WORK/main.swift" << 'SWIFT'
@main
enum ListingSQL {
    static func main() {
        let arguments = CommandLine.arguments
        let attempts = PostgreSQLTableListingLadder.degradableAttempts + [PostgreSQLTableListingLadder.leastCapableAttempt]
        if arguments[1] == "rungs" {
            print(attempts.count)
            return
        }
        if arguments[1] == "schemas" {
            print(PostgreSQLSchemaQueries.listSchemas)
            return
        }
        if arguments[1] == "dbmeta" {
            print(PostgreSQLSchemaQueries.databaseMetadata(database: arguments[2]))
            return
        }
        if arguments[1] == "alldbmeta" {
            print(PostgreSQLSchemaQueries.allDatabaseMetadata)
            return
        }
        let attempt = attempts[Int(arguments[2]) ?? 0]
        let listing: PostgreSQLTableListingScope
        switch arguments[1] {
        case "all": listing = .allSchemas
        case "set": listing = .schemas(Array(arguments.dropFirst(3)))
        default: listing = .schema(arguments[3])
        }
        print(PostgreSQLTableListingLadder.query(
            for: attempt,
            in: listing,
            includeMaterializedViews: true,
            includeForeignTables: true
        ))
    }
}
SWIFT

xcrun swiftc -swift-version 6 -parse-as-library -module-name ListingSQL -Onone \
    -F "$FRAMEWORK_DIR" -framework TableProPluginKit -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
    "${SOURCES[@]}" "$WORK/main.swift" -o "$WORK/listing-sql" > "$WORK/compile.log" 2>&1 || {
    echo "harness failed to compile:" >&2
    grep -E 'error:' "$WORK/compile.log" | sort -u | head -20 >&2
    exit 3
}
HARNESS="$WORK/listing-sql"

VERSION="$(psql_do postgres -Atc "SHOW server_version")"
echo "Checking the all-schema table listing against PostgreSQL $VERSION at $HOST:$PORT"

psql_do postgres -c "CREATE DATABASE $DATABASE" > /dev/null || exit 3
CREATED_DATABASE=1
psql_do postgres -c "CREATE DATABASE $CLOSED_DATABASE" > /dev/null || exit 3
CREATED_CLOSED_DATABASE=1
psql_do postgres -c "REVOKE CONNECT ON DATABASE $CLOSED_DATABASE FROM PUBLIC" > /dev/null || exit 3
psql_do postgres -c "CREATE ROLE $READER" > /dev/null || exit 3
CREATED_READER=1

psql_do "$DATABASE" > /dev/null << SQL || exit 3
CREATE SCHEMA attendance;
CREATE SCHEMA "Attendance";
CREATE SCHEMA "my.schema";
CREATE SCHEMA archive;
CREATE SCHEMA locked;
CREATE SCHEMA empty_schema;
CREATE TABLE public.timesheet (id int);
CREATE TABLE attendance.timesheet (id int);
CREATE TABLE attendance."time.sheet" (id int);
CREATE TABLE "Attendance"."TimeSheet" (id int);
CREATE TABLE "my.schema".orders (id int);
CREATE TABLE locked.secret (id int);
CREATE TABLE public.events (at date) PARTITION BY RANGE (at);
CREATE TABLE public.events_2025 PARTITION OF public.events FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE archive.events_2024 PARTITION OF public.events FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE public.parent_legacy (id int);
CREATE TABLE public.child_legacy () INHERITS (public.parent_legacy);
CREATE VIEW attendance.active AS SELECT id FROM attendance.timesheet;
CREATE MATERIALIZED VIEW attendance.summary AS SELECT count(*) FROM attendance.timesheet;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SERVER loopback FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname '$DATABASE');
CREATE FOREIGN TABLE archive.remote_orders (id int) SERVER loopback OPTIONS (table_name 'orders');
GRANT USAGE ON SCHEMA public, attendance, "Attendance", "my.schema", archive, empty_schema TO $READER;
GRANT SELECT ON ALL TABLES IN SCHEMA public, attendance, "Attendance", "my.schema", archive TO $READER;
REVOKE ALL ON SCHEMA locked FROM PUBLIC;
CREATE MATERIALIZED VIEW attendance.unreadable AS SELECT 1 AS one;
SQL

# The rung 0 all-schema listing as it stood before the listing read pg_class directly.
cat > "$WORK/before.sql" << 'SQL'
SELECT t.table_name, CASE WHEN pc.relkind = 'p' THEN 'PARTITIONED TABLE' ELSE t.table_type END AS table_type,
       obj_description(pc.oid, 'pg_class') AS table_comment,
       CASE WHEN pc.relkind = 'p' THEN (SELECT count(*) FROM pg_catalog.pg_inherits ci WHERE ci.inhparent = pc.oid) END AS partition_count,
       t.table_schema AS schema_name
FROM information_schema.tables t
LEFT JOIN pg_catalog.pg_namespace pn ON pn.nspname = t.table_schema
LEFT JOIN pg_catalog.pg_class pc ON pc.relnamespace = pn.oid AND pc.relname = t.table_name
WHERE t.table_schema IN (
SELECT schema_name FROM information_schema.schemata
WHERE schema_name NOT LIKE 'pg!_%' ESCAPE '!'
  AND schema_name <> 'information_schema'
ORDER BY schema_name
)
  AND t.table_type IN ('BASE TABLE', 'VIEW')
      AND NOT EXISTS (
          SELECT 1
          FROM pg_catalog.pg_inherits i
          JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
          JOIN pg_catalog.pg_namespace parentns ON parentns.oid = parent.relnamespace
          WHERE i.inhrelid = pc.oid
            AND parent.relkind IN ('p', 'I')
            AND EXISTS (
                  SELECT 1
                  FROM information_schema.tables pt
                  WHERE pt.table_schema = parentns.nspname
                    AND pt.table_name = parent.relname))
UNION ALL
SELECT m.matviewname AS table_name, 'MATERIALIZED VIEW' AS table_type,
       obj_description(mc.oid, 'pg_class') AS table_comment,
       NULL::bigint AS partition_count,
       m.schemaname AS schema_name
FROM pg_matviews m
LEFT JOIN pg_catalog.pg_namespace mn ON mn.nspname = m.schemaname
LEFT JOIN pg_catalog.pg_class mc ON mc.relnamespace = mn.oid AND mc.relname = m.matviewname
WHERE m.schemaname IN (
SELECT schema_name FROM information_schema.schemata
WHERE schema_name NOT LIKE 'pg!_%' ESCAPE '!'
  AND schema_name <> 'information_schema'
ORDER BY schema_name
)
UNION ALL
SELECT c.relname AS table_name, 'FOREIGN TABLE' AS table_type,
       obj_description(c.oid, 'pg_class') AS table_comment,
       NULL::bigint AS partition_count,
       n.nspname AS schema_name
FROM pg_foreign_table ft
JOIN pg_class c ON c.oid = ft.ftrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN (
SELECT schema_name FROM information_schema.schemata
WHERE schema_name NOT LIKE 'pg!_%' ESCAPE '!'
  AND schema_name <> 'information_schema'
ORDER BY schema_name
)
      AND NOT EXISTS (
          SELECT 1
          FROM pg_catalog.pg_inherits i
          JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
          JOIN pg_catalog.pg_namespace parentns ON parentns.oid = parent.relnamespace
          WHERE i.inhrelid = c.oid
            AND parent.relkind IN ('p', 'I')
            AND EXISTS (
                  SELECT 1
                  FROM information_schema.tables pt
                  WHERE pt.table_schema = parentns.nspname
                    AND pt.table_name = parent.relname))
ORDER BY schema_name, table_name
SQL

ROLE="$READER"
as_role() {
    psql_do "$DATABASE" -Atq -F '|' -c "SET ROLE $ROLE" -c "$1"
}

# Rows of a listing that projects schema_name, as schema|name|type.
schema_rows() {
    as_role "$1" | while IFS='|' read -r name type _ _ schema; do
        printf '%s|%s|%s\n' "$schema" "$name" "$type"
    done | sort
}

FAILURES=0
fail() {
    echo "FAIL: $*" >&2
    FAILURES=$((FAILURES + 1))
}

RUNGS="$("$HARNESS" rungs)"
SCHEMA_LIST="$("$HARNESS" schemas)"
for ROLE in "$USER_NAME" "$READER"; do
    SCHEMAS=()
    while IFS= read -r schema; do
        [ -n "$schema" ] && SCHEMAS+=("$schema")
    done < <(as_role "$SCHEMA_LIST")
    for ((rung = 0; rung < RUNGS; rung++)); do
        : > "$WORK/one.txt"
        for schema in "${SCHEMAS[@]}"; do
            as_role "$("$HARNESS" one "$rung" "$schema")" | while IFS='|' read -r name type _; do
                printf '%s|%s|%s\n' "$schema" "$name" "$type"
            done >> "$WORK/one.txt"
        done
        sort -o "$WORK/one.txt" "$WORK/one.txt"
        schema_rows "$("$HARNESS" all "$rung")" > "$WORK/all.txt"
        schema_rows "$("$HARNESS" set "$rung" "${SCHEMAS[@]}")" > "$WORK/set.txt"

        for form in all set; do
            if diff -u "$WORK/one.txt" "$WORK/$form.txt" > "$WORK/diff.txt"; then
                echo "$ROLE rung $rung: $(wc -l < "$WORK/$form.txt" | tr -d ' ') tables, per-schema and $form listings agree"
            else
                fail "$ROLE rung $rung: per-schema (-) and $form (+) listings differ"
                cat "$WORK/diff.txt" >&2
            fi
        done
    done

    schema_rows "$("$HARNESS" all 0)" > "$WORK/after.txt"
    schema_rows "$(cat "$WORK/before.sql")" > "$WORK/before.txt"
    added="$(comm -13 "$WORK/before.txt" "$WORK/after.txt")"
    dropped="$(comm -23 "$WORK/before.txt" "$WORK/after.txt")"
    [ -z "$added" ] || fail "$ROLE: rows the pre-change listing did not list: $added"
    if [ "$ROLE" = "$READER" ]; then
        [ "$dropped" = "attendance|unreadable|MATERIALIZED VIEW" ] || fail "$ROLE: dropped rows other than the unreadable view: $dropped"
    else
        [ -z "$dropped" ] || fail "$ROLE: rows the pre-change listing listed: $dropped"
    fi

    current="$(as_role "$("$HARNESS" dbmeta "$DATABASE")")"
    [[ "$current" =~ ^[0-9]+\|[0-9]+$ ]] || fail "$ROLE: the connected database read '$current', not a count and a size"
    other="$(as_role "$("$HARNESS" dbmeta postgres)")"
    [[ "$other" =~ ^\|[0-9]+$ ]] || fail "$ROLE: another database read '$other', not a size with no count"
    closed="$(as_role "$("$HARNESS" dbmeta "$CLOSED_DATABASE")" 2>&1)"
    all_closed="$(as_role "$("$HARNESS" alldbmeta)" 2>&1 | grep "^$CLOSED_DATABASE|")"
    if [ "$ROLE" = "$READER" ]; then
        [ "$closed" = "|" ] || fail "$ROLE: a database refusing CONNECT read '$closed', not two NULLs"
        [ "$all_closed" = "$CLOSED_DATABASE|" ] || fail "$ROLE: the all-database read gave '$all_closed' for a database refusing CONNECT"
    else
        [[ "$closed" =~ ^\|[0-9]+$ ]] || fail "$ROLE: a closed database read '$closed' for the owner"
    fi
done

for expected in "attendance|timesheet|BASE TABLE" "attendance|time.sheet|BASE TABLE" "Attendance|TimeSheet|BASE TABLE" "my.schema|orders|BASE TABLE"; do
    grep -qxF "$expected" "$WORK/all.txt" || fail "the all-schema listing is missing $expected"
done
if grep -q '^locked|' "$WORK/all.txt"; then
    fail "the all-schema listing shows a schema the role cannot use"
fi

[ "$FAILURES" -eq 0 ] || exit 1
echo "PASS"
