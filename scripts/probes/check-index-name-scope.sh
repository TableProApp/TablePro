#!/bin/bash
#
# Re-checks which engines keep one namespace of index names per schema.
#
# ObjectCopyIndexNames renames the indexes a copy creates only where the target refuses a second
# index of the same name on another table. MySQL, MariaDB and SQL Server scope a name to its table,
# so a shop copied from MariaDB carries a `user_id` index on several tables. This asserts that
# PostgreSQL, SQLite and DuckDB each refuse the second one, that PostgreSQL and SQLite also refuse an
# index named like a table while DuckDB accepts it, and that PostgreSQL truncates a name past 63 bytes
# rather than refusing it.
#
# Each engine is skipped when its shell is missing. PostgreSQL is reached through psql with the
# usual PG* environment variables, and the probe works in a schema of its own that it drops.
#
# Usage: scripts/probes/check-index-name-scope.sh [path-to-sqlite3] [path-to-duckdb]

set -uo pipefail

SQLITE="${1:-sqlite3}"
DUCKDB="${2:-duckdb}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
skip() { printf '  skip  %s\n' "$1"; }

TWO_TABLES="CREATE TABLE a(user_id INT); CREATE TABLE b(user_id INT); CREATE INDEX user_id ON a(user_id);"
SECOND_INDEX="CREATE INDEX user_id ON b(user_id);"

printf 'SQLite\n'
if command -v "$SQLITE" > /dev/null; then
    "$SQLITE" "$WORK/scope.db" "$TWO_TABLES"
    if "$SQLITE" "$WORK/scope.db" "$SECOND_INDEX" 2> /dev/null; then
        fail "a second index named user_id on another table is accepted"
    else
        pass "a second index named user_id on another table is refused"
    fi
    if "$SQLITE" "$WORK/scope.db" "CREATE INDEX a ON b(user_id);" 2> /dev/null; then
        fail "an index named like a table is accepted"
    else
        pass "an index named like a table is refused"
    fi
else
    skip "$SQLITE not found"
fi

printf 'DuckDB\n'
if command -v "$DUCKDB" > /dev/null; then
    "$DUCKDB" "$WORK/scope.duckdb" -c "$TWO_TABLES"
    output="$("$DUCKDB" "$WORK/scope.duckdb" -c "$SECOND_INDEX" 2>&1)"
    if grep -q 'already exists' <<< "$output"; then
        pass "a second index named user_id on another table is refused"
    else
        fail "a second index named user_id on another table is accepted"
    fi
    output="$("$DUCKDB" "$WORK/scope.duckdb" -c "CREATE INDEX a ON b(user_id);" 2>&1)"
    if [ -z "$output" ]; then
        pass "an index named like a table is accepted"
    else
        fail "an index named like a table is refused"
    fi
else
    skip "$DUCKDB not found"
fi

printf 'PostgreSQL\n'
if command -v psql > /dev/null && psql -X -q -c 'SELECT 1' > /dev/null 2>&1; then
    schema="tablepro_probe_$$"
    run() { psql -X -q -v ON_ERROR_STOP=1 -c "SET search_path = $schema; $1" 2>&1; }
    psql -X -q -c "CREATE SCHEMA $schema" > /dev/null
    run "$TWO_TABLES" > /dev/null
    output="$(run "$SECOND_INDEX")"
    if grep -q 'already exists' <<< "$output"; then
        pass "a second index named user_id on another table is refused"
    else
        fail "a second index named user_id on another table is accepted"
    fi
    output="$(run "CREATE INDEX a ON b(user_id);")"
    if grep -q 'already exists' <<< "$output"; then
        pass "an index named like a table is refused"
    else
        fail "an index named like a table is accepted"
    fi
    long="customer_subscription_billing_history_idx_subscription_customer_id"
    run "CREATE INDEX $long ON a(user_id);" > /dev/null
    length="$(psql -X -At -c "SELECT max(length(indexname)) FROM pg_indexes WHERE schemaname = '$schema'")"
    if [ "$length" = "63" ]; then
        pass "a 66-byte index name is truncated to 63 bytes"
    else
        fail "the longest index name is $length bytes, not 63"
    fi
    psql -X -q -c "DROP SCHEMA $schema CASCADE" > /dev/null 2>&1
else
    skip "no PostgreSQL server reachable through psql"
fi

printf '\n'
if [ "$failures" -gt 0 ]; then
    printf '%d check(s) failed. ObjectCopyIndexNames.sharesOneNamespace or sharesNamesWithRelations may need to change.\n' "$failures"
    exit 1
fi
printf 'All checks passed.\n'
