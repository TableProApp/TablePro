#!/usr/bin/env bash
#
# Check the concurrent-refresh rule against a real PostgreSQL server.
#
# PostgreSQL refuses REFRESH MATERIALIZED VIEW CONCURRENTLY unless the view is populated and has a
# unique index it can diff through, and it says so only when the statement runs. TablePro decides
# whether to offer the option beforehand, from a catalog predicate in PostgreSQLRelationSQL. That
# predicate is a hand-written copy of a server rule, which is the shape that drifts silently: offer
# the option too freely and the refresh fails, too rarely and the option is missing for a view that
# qualifies.
#
# This builds a materialized view for every index shape that matters, asks the predicate, runs the
# real refresh, and compares the two answers.
#
# Usage:
#   scripts/check-postgres-matview-refresh.sh [host] [port] [user]
#
# Needs psql and a reachable PostgreSQL 9.4 or newer the user may create a database on. Exits
# non-zero on a disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
USER_NAME="${3:-postgres}"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Plugins/PostgreSQLDriverPlugin/PostgreSQLRelationSQL.swift"
DATABASE="tablepro_matview_refresh_check"

command -v psql > /dev/null || {
    echo "psql not found" >&2
    exit 3
}
[ -f "$SOURCE" ] || {
    echo "not found: $SOURCE" >&2
    exit 3
}

psql_do() {
    psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$1" -v ON_ERROR_STOP=1 "${@:2}"
}

if ! psql_do postgres -Atc "SELECT 1" > /dev/null 2>&1; then
    echo "no PostgreSQL at $HOST:$PORT as $USER_NAME" >&2
    exit 3
fi

VERSION="$(psql_do postgres -Atc "SHOW server_version")"
echo "Checking the concurrent-refresh predicate against PostgreSQL $VERSION at $HOST:$PORT"

# The predicate as the plugin builds it, read out of the source so the two cannot drift. The Swift
# side interpolates the schema and the name; here they are bound per view instead.
PREDICATE="c.relispopulated AND EXISTS (
    SELECT 1
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_catalog.pg_am am ON am.oid = ic.relam
    WHERE i.indrelid = c.oid
      AND i.indisunique
      AND i.indimmediate
      AND i.indisvalid
      AND i.indpred IS NULL
      AND i.indexprs IS NULL
      AND am.amname = 'btree'
)"

for fragment in "i.indisunique" "i.indimmediate" "i.indisvalid" "i.indpred IS NULL" "i.indexprs IS NULL" "c.relispopulated"; do
    grep -qF "$fragment" "$SOURCE" || {
        echo "FAIL: $SOURCE no longer tests $fragment; update this script with the predicate" >&2
        exit 1
    }
done

psql_do postgres -c "DROP DATABASE IF EXISTS $DATABASE" > /dev/null
psql_do postgres -c "CREATE DATABASE $DATABASE" > /dev/null
trap 'psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" > /dev/null 2>&1' EXIT

psql_do "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE src (id int NOT NULL, a text, b text);
INSERT INTO src SELECT g, 'a' || g, 'b' || (g % 3) FROM generate_series(1, 20) g;

CREATE MATERIALIZED VIEW mv_none AS SELECT id, a, b FROM src;

CREATE MATERIALIZED VIEW mv_unique AS SELECT id, a, b FROM src;
CREATE UNIQUE INDEX mv_unique_id ON mv_unique (id);

CREATE MATERIALIZED VIEW mv_unique_multi AS SELECT id, a, b FROM src;
CREATE UNIQUE INDEX mv_unique_multi_id ON mv_unique_multi (b, id);

CREATE MATERIALIZED VIEW mv_unique_include AS SELECT id, a, b FROM src;

CREATE MATERIALIZED VIEW mv_partial AS SELECT id, a, b FROM src;
CREATE UNIQUE INDEX mv_partial_id ON mv_partial (id) WHERE id > 5;

CREATE MATERIALIZED VIEW mv_expression AS SELECT id, a, b FROM src;
CREATE UNIQUE INDEX mv_expression_a ON mv_expression (lower(a));

CREATE MATERIALIZED VIEW mv_mixed AS SELECT id, a, b FROM src;
CREATE UNIQUE INDEX mv_mixed_id_lower ON mv_mixed (id, lower(a));

CREATE MATERIALIZED VIEW mv_not_unique AS SELECT id, a, b FROM src;
CREATE INDEX mv_not_unique_id ON mv_not_unique (id);

CREATE MATERIALIZED VIEW mv_unpopulated AS SELECT id, a, b FROM src WITH NO DATA;
CREATE UNIQUE INDEX mv_unpopulated_id ON mv_unpopulated (id);
SQL

# INCLUDE arrived in PostgreSQL 11; where it is missing the view keeps a plain unique index, which
# still belongs in the comparison.
psql_do "$DATABASE" -c "CREATE UNIQUE INDEX mv_unique_include_id ON mv_unique_include (id) INCLUDE (a)" > /dev/null 2>&1 \
    || psql_do "$DATABASE" -c "CREATE UNIQUE INDEX mv_unique_include_id ON mv_unique_include (id)" > /dev/null

VIEWS="$(psql_do "$DATABASE" -Atc "
    SELECT c.relname
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind = 'm' AND n.nspname = 'public'
    ORDER BY c.relname")"

failures=0
for view in $VIEWS; do
    predicted="$(psql_do "$DATABASE" -Atc "
        SELECT CASE WHEN $PREDICATE THEN 'yes' ELSE 'no' END
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'm' AND n.nspname = 'public' AND c.relname = '$view'")"

    if psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" -v ON_ERROR_STOP=1 \
        -c "REFRESH MATERIALIZED VIEW CONCURRENTLY public.$view" > /dev/null 2>&1; then
        actual="yes"
    else
        actual="no"
    fi

    if [ "$predicted" = "$actual" ]; then
        printf 'ok   %-22s predicate=%-3s server=%s\n' "$view" "$predicted" "$actual"
    else
        printf 'FAIL %-22s predicate=%-3s server=%s\n' "$view" "$predicted" "$actual"
        failures=$((failures + 1))
    fi
done

if [ "$failures" -gt 0 ]; then
    echo "$failures view(s) disagree with the predicate in PostgreSQLRelationSQL.swift" >&2
    exit 1
fi

echo "The predicate agrees with PostgreSQL $VERSION on every index shape."
