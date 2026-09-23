#!/usr/bin/env bash
#
# Check the PostgreSQL table and index DDL against pg_dump on a real server.
#
# A PostgreSQL dump writes a table's constraints inside its CREATE TABLE and every other index as a
# CREATE INDEX of its own. Both halves are catalog predicates copied by hand from pg_dump's
# getIndexes and getConstraints, and they have to agree with it and with each other: an invalid
# index a failed CREATE INDEX CONCURRENTLY left behind made the restore fail on its duplicates, a
# unique index a foreign key depends on went missing, and an exclusion constraint was in neither
# half.
#
# This builds every one of those shapes, asks the same predicates the plugin uses, runs pg_dump -s
# on each table, and compares the index names and the constraint names on both sides.
#
# Usage:
#   scripts/check-postgres-index-dump-parity.sh [host] [port] [user]
#
# Needs psql, pg_dump at least as new as the server, and a PostgreSQL 11 or newer the user may
# create a database on. Takes about ten seconds, most of it waiting out two cancelled concurrent
# builds. Exits non-zero on a disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
USER_NAME="${3:-postgres}"
PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Plugins/PostgreSQLDriverPlugin"
INDEX_SOURCE="$PLUGIN/PostgreSQLIndexQueries.swift"
CONSTRAINT_SOURCE="$PLUGIN/PostgreSQLSchemaQueries.swift"
DATABASE="tablepro_index_dump_parity_check"

for tool in psql pg_dump; do
    command -v "$tool" > /dev/null || {
        echo "$tool not found" >&2
        exit 3
    }
done
for source in "$INDEX_SOURCE" "$CONSTRAINT_SOURCE"; do
    [ -f "$source" ] || {
        echo "not found: $source" >&2
        exit 3
    }
done

export PGOPTIONS="-c client_min_messages=warning"

psql_do() {
    psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$1" -v ON_ERROR_STOP=1 "${@:2}"
}

if ! psql_do postgres -Atc "SELECT 1" > /dev/null 2>&1; then
    echo "no PostgreSQL at $HOST:$PORT as $USER_NAME" >&2
    exit 3
fi

# The predicates as the plugin builds them, read out of the source so the two cannot drift. The
# Swift side interpolates the schema and the table; here they are bound per table instead.
RESTORABLE="(ix.indisvalid OR t.relkind = 'p') AND ix.indisready"
check_fragment() {
    grep -qF "$2" "$1" || {
        echo "FAIL: $1 no longer holds $2; update this script with the predicate" >&2
        exit 1
    }
}
check_fragment "$INDEX_SOURCE" "$RESTORABLE"
check_fragment "$INDEX_SOURCE" "con.conrelid = ix.indrelid"
check_fragment "$INDEX_SOURCE" "con.conindid = ix.indexrelid"
check_fragment "$INDEX_SOURCE" "con.contype IN ('p', 'u', 'x')"
check_fragment "$CONSTRAINT_SOURCE" "con.contype IN ('p', 'u', 'c', 'x')"

VERSION="$(psql_do postgres -Atc "SHOW server_version")"
echo "Checking table and index DDL against $(pg_dump --version) and PostgreSQL $VERSION at $HOST:$PORT"

psql_do postgres -c "DROP DATABASE IF EXISTS $DATABASE" > /dev/null
psql_do postgres -c "CREATE DATABASE $DATABASE" > /dev/null
trap 'psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" > /dev/null 2>&1' EXIT

psql_do "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE t (id int PRIMARY KEY, email text, code int);
INSERT INTO t VALUES (1, 'a@x', 1), (2, 'a@x', 2), (3, 'b@x', 3);
CREATE INDEX t_code_idx ON t (code);

CREATE TABLE parent (id int, code int);
CREATE UNIQUE INDEX parent_code_idx ON parent (code);
CREATE TABLE child (code int REFERENCES parent (code));

CREATE TABLE s (id int, v int CONSTRAINT s_v_idx CHECK (v > 0), w int UNIQUE);
CREATE INDEX s_v_idx ON s (v);

CREATE TABLE ex (r int4range, EXCLUDE USING gist (r WITH &&));

CREATE TABLE p (a int, b int) PARTITION BY RANGE (a);
CREATE TABLE p1 PARTITION OF p FOR VALUES FROM (0) TO (10);
CREATE TABLE p2 PARTITION OF p FOR VALUES FROM (10) TO (20);
CREATE INDEX p_a_idx ON ONLY p (a);
CREATE INDEX p1_a_idx ON p1 (a);
ALTER INDEX p_a_idx ATTACH PARTITION p1_a_idx;
CREATE INDEX p_b_idx ON p (b);
SQL

# A unique build over duplicate rows fails and leaves an index that is neither valid nor ready.
psql_do "$DATABASE" -c "CREATE UNIQUE INDEX CONCURRENTLY t_email_key ON t (email)" > /dev/null 2>&1

# A concurrent build or rebuild cancelled while it waits out an older snapshot leaves an index
# that is ready but not valid.
cancel_while_waiting() {
    psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" \
        -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT 1; SELECT pg_sleep(4); COMMIT;" > /dev/null 2>&1 &
    local holder=$!
    sleep 1
    psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" \
        -c "SET statement_timeout = '1500ms'" -c "$1" > /dev/null 2>&1
    wait "$holder"
}
cancel_while_waiting "CREATE UNIQUE INDEX CONCURRENTLY t_code_key ON t (code)"
cancel_while_waiting "REINDEX INDEX CONCURRENTLY t_code_idx"

INVALID="$(psql_do "$DATABASE" -Atc "
    SELECT string_agg(i.relname, ' ' ORDER BY i.relname)
    FROM pg_catalog.pg_index ix
    JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
    WHERE NOT ix.indisvalid")"
for expected in t_email_key t_code_key t_code_idx_ccnew p_a_idx; do
    case " $INVALID " in
    *" $expected "*) ;;
    *)
        echo "setup did not leave $expected invalid (invalid: $INVALID), so this run proves nothing" >&2
        exit 2
        ;;
    esac
done

plugin_indexes() {
    psql_do "$DATABASE" -Atc "
        SELECT i.relname
        FROM pg_catalog.pg_index ix
        JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
        JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public'
          AND t.relname = '$1'
          AND NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_constraint con
            WHERE con.conrelid = ix.indrelid
              AND con.conindid = ix.indexrelid
              AND con.contype IN ('p', 'u', 'x')
          )
          AND ($RESTORABLE)"
}

plugin_constraints() {
    psql_do "$DATABASE" -Atc "
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = '$1'
          AND n.nspname = 'public'
          AND con.contype IN ('p', 'u', 'c', 'x')"
}

dump_of() {
    pg_dump -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" -s -t "public.$1"
}

dump_indexes() {
    dump_of "$1" | sed -nE 's/^CREATE (UNIQUE )?INDEX ([^ ]+) ON .*/\2/p' | sort
}

dump_constraints() {
    dump_of "$1" \
        | sed -nE '/FOREIGN KEY/d; s/^ +ADD CONSTRAINT ([^ ]+) .*/\1/p; s/^ +CONSTRAINT ([^ ]+) CHECK .*/\1/p' \
        | sort
}

TABLES="$(psql_do "$DATABASE" -Atc "
    SELECT c.relname
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
    ORDER BY 1")"

failures=0
compare() {
    local table="$1" kind="$2" plugin="$3" dump="$4"
    if [ "$plugin" = "$dump" ]; then
        printf 'ok   %-7s %-11s %s\n' "$table" "$kind" "${plugin//$'\n'/ }"
    else
        printf 'FAIL %-7s %-11s plugin=[%s] pg_dump=[%s]\n' "$table" "$kind" "${plugin//$'\n'/ }" "${dump//$'\n'/ }"
        failures=$((failures + 1))
    fi
}
for table in $TABLES; do
    compare "$table" indexes "$(plugin_indexes "$table" | sort)" "$(dump_indexes "$table")"
    compare "$table" constraints "$(plugin_constraints "$table" | sort)" "$(dump_constraints "$table")"
done

if [ "$failures" -gt 0 ]; then
    echo "$failures comparison(s) disagree with pg_dump" >&2
    exit 1
fi

echo "The table and index DDL agree with pg_dump on every shape."
