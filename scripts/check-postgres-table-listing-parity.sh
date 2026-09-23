#!/usr/bin/env bash
#
# Check that PostgreSQL's all-schema table listing lists exactly what the per-schema listing does.
#
# Open Quickly and the sidebar filter find tables in schemas nobody has opened through one query,
# PostgreSQLSchemaQueries.fetchTables(in: .allSchemas). The sidebar lists each schema through
# fetchTables(in: .schema(name)). The two have to agree row for row, on every rung of the
# degradation ladder: a table the one-schema listing shows and the search cannot find is the bug
# this listing exists to fix, and one the search finds that the sidebar hides is a result that
# opens nothing.
#
# This builds a database with every shape the listing treats specially (declarative partitions,
# a partition in another schema than its parent, legacy inheritance, a materialized view, a
# foreign table, a schema the role cannot use, quoted names with dots and mixed case), compiles
# the plugin's real query builder into a small harness, and compares the two listings as a role
# with ordinary privileges.
#
# Usage:
#   scripts/check-postgres-table-listing-parity.sh [host] [port] [user]
#
# Needs psql, a reachable PostgreSQL 10 or newer the user may create a database and a role on, and
# a Debug build of TableProPluginKit in DerivedData (run verify.sh build first). Exits non-zero on
# a disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
USER_NAME="${3:-postgres}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Named per run and never dropped unless this run created them, so pointing the check at a shared
# server cannot touch anything that was already there, and two runs cannot remove each other's.
RUN_ID="$$_$RANDOM"
DATABASE="tablepro_listing_parity_$RUN_ID"
READER="tablepro_listing_reader_$RUN_ID"
CREATED_DATABASE=0
CREATED_READER=0
WORK="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK"
    if [ "$CREATED_DATABASE" -eq 1 ]; then
        psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE $DATABASE" > /dev/null 2>&1
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
        let attempt = attempts[Int(arguments[2]) ?? 0]
        let listing: PostgreSQLTableListingScope = arguments[1] == "all" ? .allSchemas : .schema(arguments[3])
        print(PostgreSQLSchemaQueries.fetchTables(
            in: listing,
            includeMaterializedViews: attempt.includeOptionalCatalogs,
            includeForeignTables: attempt.includeOptionalCatalogs,
            includeComments: attempt.includeComments,
            includePartitionAwareness: attempt.includePartitionAwareness
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
SQL

as_reader() {
    psql_do "$DATABASE" -Atq -F '|' -c "SET ROLE $READER" -c "$1"
}

FAILURES=0
RUNGS="$("$HARNESS" rungs)"
SCHEMA_LIST="$("$HARNESS" schemas)"
for ((rung = 0; rung < RUNGS; rung++)); do
    : > "$WORK/one.txt"
    while IFS= read -r schema; do
        [ -n "$schema" ] || continue
        as_reader "$("$HARNESS" one "$rung" "$schema")" | while IFS='|' read -r name type _; do
            printf '%s|%s|%s\n' "$schema" "$name" "$type"
        done >> "$WORK/one.txt"
    done < <(as_reader "$SCHEMA_LIST")
    as_reader "$("$HARNESS" all "$rung")" | while IFS='|' read -r name type _ _ schema; do
        printf '%s|%s|%s\n' "$schema" "$name" "$type"
    done > "$WORK/all.txt"

    sort -o "$WORK/one.txt" "$WORK/one.txt"
    sort -o "$WORK/all.txt" "$WORK/all.txt"
    if diff -u "$WORK/one.txt" "$WORK/all.txt" > "$WORK/diff.txt"; then
        echo "rung $rung: $(wc -l < "$WORK/all.txt" | tr -d ' ') tables, listings agree"
    else
        echo "FAIL rung $rung: per-schema (-) and all-schema (+) listings differ" >&2
        cat "$WORK/diff.txt" >&2
        FAILURES=$((FAILURES + 1))
    fi
done

for expected in "attendance|timesheet|BASE TABLE" "attendance|time.sheet|BASE TABLE" "Attendance|TimeSheet|BASE TABLE" "my.schema|orders|BASE TABLE"; do
    grep -qxF "$expected" "$WORK/all.txt" || {
        echo "FAIL: the all-schema listing is missing $expected" >&2
        FAILURES=$((FAILURES + 1))
    }
done
if grep -q '^locked|' "$WORK/all.txt"; then
    echo "FAIL: the all-schema listing shows a schema the role cannot use" >&2
    FAILURES=$((FAILURES + 1))
fi

[ "$FAILURES" -eq 0 ] || exit 1
echo "PASS"
