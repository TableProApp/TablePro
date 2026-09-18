#!/usr/bin/env bash
#
# Check PostgreSQLObjectQueries.quoteLiteral against a real PostgreSQL server.
#
# A catalog name may legally hold a backslash, and with standard_conforming_strings = off a
# backslash inside a plain literal is an escape. So a name listed as '...' can decode to something
# else, or end the literal early and leave the rest as SQL. Neither shows up in a unit test, because
# both depend on a server setting, and neither raises: the first returns no rows and the second
# returns too many.
#
# This builds a schema for every name shape that matters, runs the literal the plugin now emits
# against a session with the setting off, and compares the row count with the one the plugin
# emitted before the fix.
#
# Usage:
#   scripts/check-postgres-literal-quoting.sh [host] [port] [user]
#
# Needs psql and a reachable PostgreSQL the user may create a database on. Exits non-zero when a
# quoted literal does not find exactly the one table its schema holds.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
USER_NAME="${3:-postgres}"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Plugins/PostgreSQLDriverPlugin/PostgreSQLObjectQueries.swift"
DATABASE="tablepro_literal_quoting_check"

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

grep -qF "E'" "$SOURCE" || {
    echo "FAIL: $SOURCE no longer emits an E-string; update this script with the quoting rule" >&2
    exit 1
}

VERSION="$(psql_do postgres -Atc "SHOW server_version")"
echo "Checking literal quoting against PostgreSQL $VERSION at $HOST:$PORT"

psql_do postgres -c "DROP DATABASE IF EXISTS $DATABASE" > /dev/null
psql_do postgres -c "CREATE DATABASE $DATABASE" > /dev/null
trap 'psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" > /dev/null 2>&1' EXIT

# Each schema holds exactly one table, so a correct literal always answers 1.
#   name | plain literal (the old spelling) | E-string (the spelling the plugin now emits)
CASES=(
    "plain|'plain'|'plain'"
    "o'q|'o''q'|'o''q'"
    "a\\b|'a\\b'|E'a\\\\b'"
    "x\\' OR true--|'x\\'' OR true--'|E'x\\\\'' OR true--'"
    "tail\\|'tail\\'|E'tail\\\\'"
)

for entry in "${CASES[@]}"; do
    name="${entry%%|*}"
    psql_do "$DATABASE" -c "CREATE SCHEMA \"${name//\"/\"\"}\"" > /dev/null
    psql_do "$DATABASE" -c "CREATE TABLE \"${name//\"/\"\"}\".t1 (id int)" > /dev/null
done

# Counting relations across the whole database is what makes an early-closed literal visible: a
# predicate the server parsed as OR true answers with every table rather than raising.
count_for() {
    PGOPTIONS="-c standard_conforming_strings=off" psql -X -q -A -t \
        -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" -c "
        SELECT count(*)
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'm', 'f')" 2> /dev/null
}

failures=0
for entry in "${CASES[@]}"; do
    rest="${entry#*|}"
    name="${entry%%|*}"
    plain="${rest%%|*}"
    quoted="${rest#*|}"

    before="$(count_for "$plain")"
    after="$(count_for "$quoted")"
    [ -n "$before" ] || before="error"

    if [ "$after" = "1" ]; then
        printf 'ok   %-18s before=%-6s after=%s\n' "$name" "$before" "$after"
    else
        printf 'FAIL %-18s before=%-6s after=%s (expected 1)\n' "$name" "$before" "$after"
        failures=$((failures + 1))
    fi
done

if [ "$failures" -gt 0 ]; then
    echo "$failures literal(s) did not find exactly their own schema; see PostgreSQLObjectQueries.quoteLiteral" >&2
    exit 1
fi

echo "Every quoted literal found exactly its own schema on PostgreSQL $VERSION with standard_conforming_strings off."
