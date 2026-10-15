#!/usr/bin/env bash
#
# Check the PostgreSQL session facts the driver's session scopes rely on (#3414).
#
# TablePro runs an imported SQL file on the user's own editor session. A pg_dump plain file sets
# search_path to '' and a dozen other settings and never puts them back, so after an import the
# editor session resolves no unqualified name. The preserve scope saves those settings from
# pg_settings and, at close, writes back only the ones that changed. An export reads values as text
# in the session's DateStyle, IntervalStyle and extra_float_digits, and some of those texts read
# back as other values. The read scope sets what pg_dump's own reading session sets. This measures
# both on a live server, plus the transaction facts the scope's close depends on.
#
# Usage:
#   scripts/probes/check-postgresql-dump-session.sh [conninfo]
#
# conninfo is a libpq connection string without dbname, default empty (libpq defaults: the local
# socket as the current user). The password, if any, comes from PGPASSWORD. Needs psql and a
# pg_dump no older than the server. Creates and drops two scratch databases named
# zd3414_impl_pg_*, and a NOLOGIN role of the same prefix when the user may create one.
# Exits 0 when every check holds, 1 on a failed check, 3 when psql, pg_dump or the server is
# missing.

set -uo pipefail

BASE="${1:-}"
SUFFIX="$$"
SRC_DB="zd3414_impl_pg_src_$SUFFIX"
DST_DB="zd3414_impl_pg_dst_$SUFFIX"
ROLE="zd3414_impl_pg_role_$SUFFIX"

for tool in psql pg_dump; do
    command -v "$tool" > /dev/null || {
        echo "$tool not found" >&2
        exit 3
    }
done

PSQL=(psql -X -A -t -q -v ON_ERROR_STOP=1)
ADMIN="$BASE dbname=postgres"
SRC="$BASE dbname=$SRC_DB"
DST="$BASE dbname=$DST_DB"

if ! "${PSQL[@]}" -d "$ADMIN" -c "SELECT 1" > /dev/null 2>&1; then
    echo "no PostgreSQL answers '$ADMIN'" >&2
    exit 3
fi

WORK="$(mktemp -d)"
role_created=0
cleanup() {
    "${PSQL[@]}" -d "$ADMIN" -c "DROP DATABASE IF EXISTS $SRC_DB" > /dev/null 2>&1
    "${PSQL[@]}" -d "$ADMIN" -c "DROP DATABASE IF EXISTS $DST_DB" > /dev/null 2>&1
    if [ "$role_created" -eq 1 ]; then
        "${PSQL[@]}" -d "$ADMIN" -c "DROP ROLE IF EXISTS $ROLE" > /dev/null 2>&1
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

failures=0
check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "ok    $label: $actual"
    else
        echo "FAIL  $label: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

q() {
    local conn=$1
    shift
    "${PSQL[@]}" -d "$conn" "$@" 2>&1
}

echo "server: $(q "$ADMIN" -c "SHOW server_version")"
echo "pg_dump: $(pg_dump --version)"

if ! q "$ADMIN" -c "CREATE DATABASE $SRC_DB" > /dev/null || ! q "$ADMIN" -c "CREATE DATABASE $DST_DB" > /dev/null; then
    echo "cannot create the scratch databases" >&2
    exit 3
fi

SETTINGS="'statement_timeout', 'lock_timeout', 'idle_in_transaction_session_timeout', 'transaction_timeout',
    'client_encoding', 'standard_conforming_strings', 'search_path', 'check_function_bodies', 'xmloption',
    'client_min_messages', 'row_security', 'default_tablespace', 'default_table_access_method', 'datestyle',
    'intervalstyle', 'extra_float_digits', 'timezone', 'session_replication_role'"

echo
echo "== pg_dump's settings outlive the import on the session that ran it"

q "$SRC" -c "CREATE TABLE t (id int PRIMARY KEY, d date, i interval, f float8)" \
    -c "INSERT INTO t VALUES (1, make_date(2024, 6, 1), make_interval(days => -1, hours => -2), 0.1::float8 + 0.2::float8)" \
    > /dev/null
if ! pg_dump -d "$SRC" > "$WORK/dump.sql" 2> "$WORK/pg_dump.err"; then
    echo "pg_dump failed: $(cat "$WORK/pg_dump.err")" >&2
    exit 3
fi
check "the dump empties search_path" "1" \
    "$(grep -cF "SELECT pg_catalog.set_config('search_path', '', false);" "$WORK/dump.sql")"

session=$(q "$DST" -v dumpfile="$WORK/dump.sql" <<SQL
SET statement_timeout = 30000;
CREATE TEMP TABLE scope_saved AS
    SELECT name, setting FROM pg_catalog.pg_settings WHERE pg_catalog.lower(name) IN ($SETTINGS);
SELECT pg_catalog.current_setting('search_path') AS before_path \gset
\o /dev/null
\i :dumpfile
\o
SELECT pg_catalog.current_setting('search_path') AS after_path \gset
SELECT COALESCE(pg_catalog.string_agg(s.name, ',' ORDER BY s.name), '') AS changed
    FROM pg_temp.scope_saved s JOIN pg_catalog.pg_settings p ON p.name = s.name
    WHERE p.setting IS DISTINCT FROM s.setting \gset
SELECT pg_catalog.count(pg_catalog.set_config(s.name, s.setting, false)) AS restored
    FROM pg_temp.scope_saved s JOIN pg_catalog.pg_settings p ON p.name = s.name
    WHERE p.setting IS DISTINCT FROM s.setting \gset
SELECT pg_catalog.count(*) AS remaining
    FROM pg_temp.scope_saved s JOIN pg_catalog.pg_settings p ON p.name = s.name
    WHERE p.setting IS DISTINCT FROM s.setting \gset
\echo before=:before_path
\echo after=:after_path
\echo changed=:changed
\echo restored=:restored
\echo remaining=:remaining
SELECT 'restored_path=' || pg_catalog.current_setting('search_path');
SELECT 'rows=' || pg_catalog.count(*) FROM public.t;
SQL
)
field() { printf '%s\n' "$session" | sed -n "s/^$1=//p" | head -1; }
before_path=$(field before)
echo "info  session before the import: search_path $before_path, statement_timeout 30000"
check "search_path after replaying the dump on the same session" "" "$(field after)"
echo "info  settings the dump left changed: $(field changed)"
check "the dump replaced the session's statement_timeout" "1" \
    "$(field changed | tr ',' '\n' | grep -cx statement_timeout)"
echo "info  set_config calls the scope's close makes: $(field restored)"
check "settings still differing after writing back only the changed ones" "0" "$(field remaining)"
check "search_path after the close" "$before_path" "$(field restored_path)"
check "rows the dump loaded" "1" "$(field rows)"

echo
echo "== Text read under the session's settings reads back as another value"

check "float8 0.1+0.2 under extra_float_digits 0" "0.3" \
    "$(q "$SRC" -c "SET extra_float_digits = 0" -c "SELECT f::text FROM t")"
check "  that text reads back as the stored value" "f" \
    "$(q "$SRC" -c "SELECT '0.3'::float8 = f FROM t")"
check "interval under IntervalStyle sql_standard" "-1 2:00:00" \
    "$(q "$SRC" -c "SET IntervalStyle = 'sql_standard'" -c "SELECT i::text FROM t")"
check "  that text read under IntervalStyle postgres" "-1 days +02:00:00" \
    "$(q "$SRC" -c "SET IntervalStyle = 'postgres'" -c "SELECT '-1 2:00:00'::interval::text")"
check "  that text reads back as the stored value" "f" \
    "$(q "$SRC" -c "SET IntervalStyle = 'postgres'" -c "SELECT '-1 2:00:00'::interval = i FROM t")"
check "date under DateStyle 'SQL, DMY'" "01/06/2024" \
    "$(q "$SRC" -c "SET DateStyle = 'SQL, DMY'" -c "SELECT d::text FROM t")"
check "  that text stored by an 'ISO, MDY' session" "2024-01-06" \
    "$(q "$SRC" -c "SET DateStyle = 'ISO, MDY'" -c "SELECT '01/06/2024'::date::text")"

echo
echo "== The read scope's settings make the text read back the same under any settings"

read_scope="SELECT pg_catalog.set_config('DateStyle', 'ISO', false), pg_catalog.set_config('IntervalStyle', 'postgres', false), pg_catalog.set_config('extra_float_digits', '3', false)"
hostile=(-c "SET DateStyle = 'SQL, DMY'" -c "SET IntervalStyle = 'sql_standard'" -c "SET extra_float_digits = 0")
check "the scope's one statement from a hostile session" "ISO, DMY|postgres|3" \
    "$(q "$SRC" "${hostile[@]}" -c "$read_scope")"
read_row=$(q "$SRC" "${hostile[@]}" -c "$read_scope" -c "SELECT d::text || '|' || i::text || '|' || f::text FROM t" | tail -1)
check "values read under the scope" "2024-06-01|-1 days -02:00:00|0.30000000000000004" "$read_row"
IFS='|' read -r read_date read_interval read_float <<< "$read_row"
for target in "'ISO, MDY'|postgres|1" "'SQL, DMY'|sql_standard|0" "'German'|iso_8601|-15"; do
    IFS='|' read -r datestyle intervalstyle digits <<< "$target"
    check "  they read back unchanged under DateStyle $datestyle, IntervalStyle $intervalstyle, extra_float_digits $digits" "t" \
        "$(q "$SRC" -c "SET DateStyle = $datestyle" -c "SET IntervalStyle = '$intervalstyle'" -c "SET extra_float_digits = $digits" \
            -c "SELECT '$read_date'::date = d AND '$read_interval'::interval = i AND '$read_float'::float8 = f FROM t")"
done

echo
echo "== Transaction facts the scope's statements depend on"

check "one statement setting two values applies neither when one is refused" "1" \
    "$(q "$SRC" -v ON_ERROR_STOP=0 -c "SET extra_float_digits = 1" \
        -c "SELECT pg_catalog.set_config('extra_float_digits', '3', false), pg_catalog.set_config('IntervalStyle', 'bogus', false)" \
        -c "SHOW extra_float_digits" | tail -1)"

savepoint=$(q "$SRC" -v ON_ERROR_STOP=0 <<'SQL'
SET extra_float_digits = 1;
BEGIN;
SAVEPOINT tablepro_session_setting;
SELECT pg_catalog.set_config('IntervalStyle', 'bogus', false);
ROLLBACK TO SAVEPOINT tablepro_session_setting; RELEASE SAVEPOINT tablepro_session_setting;
SELECT 'usable=' || pg_catalog.count(*) FROM t;
SAVEPOINT tablepro_session_setting;
SELECT pg_catalog.set_config('extra_float_digits', '3', false);
RELEASE SAVEPOINT tablepro_session_setting;
COMMIT;
SELECT 'kept=' || pg_catalog.current_setting('extra_float_digits');
SQL
)
check "a refused set inside a savepoint leaves the user's transaction usable" "usable=1" \
    "$(printf '%s\n' "$savepoint" | grep '^usable=')"
check "a set inside a released savepoint outlives the commit" "kept=3" \
    "$(printf '%s\n' "$savepoint" | grep '^kept=')"

set_local=$(q "$SRC" <<'SQL'
SET extra_float_digits = 1;
BEGIN;
SET LOCAL extra_float_digits = 0;
SELECT 'captured=' || setting FROM pg_catalog.pg_settings WHERE name = 'extra_float_digits';
SAVEPOINT tablepro_session_setting;
SELECT pg_catalog.set_config('extra_float_digits', '3', false);
RELEASE SAVEPOINT tablepro_session_setting;
SAVEPOINT tablepro_session_setting;
SELECT pg_catalog.set_config('extra_float_digits', '0', false);
RELEASE SAVEPOINT tablepro_session_setting;
COMMIT;
SELECT 'after=' || pg_catalog.current_setting('extra_float_digits');
SQL
)
check "a capture inside a transaction reads a SET LOCAL value" "captured=0" \
    "$(printf '%s\n' "$set_local" | grep '^captured=')"
check "  writing it back session-wide replaces the session's 1 after COMMIT" "after=0" \
    "$(printf '%s\n' "$set_local" | grep '^after=')"

aborted=$(q "$SRC" -v ON_ERROR_STOP=0 <<'SQL'
\set VERBOSITY sqlstate
SET extra_float_digits = 2;
SELECT pg_catalog.set_config('search_path', '', false);
BEGIN;
SET extra_float_digits = 3;
SELECT 1/0;
SELECT pg_catalog.set_config('search_path', 'public', false);
ROLLBACK;
SELECT 'after=' || pg_catalog.current_setting('extra_float_digits') || '|' || pg_catalog.current_setting('search_path');
SQL
)
check "a set_config inside an aborted transaction" "ERROR:  25P02" \
    "$(printf '%s\n' "$aborted" | grep -F '25P02' | head -1)"
check "its rollback reverts the transaction's set, not the one before BEGIN" "after=2|" \
    "$(printf '%s\n' "$aborted" | grep '^after=')"

echo
echo "== session_replication_role needs its privilege even to keep its value"

if q "$ADMIN" -c "CREATE ROLE $ROLE NOLOGIN" > /dev/null; then
    role_created=1
    check "set_config to the current value as a role without it" "ERROR:  42501" \
        "$(q "$SRC" -v ON_ERROR_STOP=0 -c "\\set VERBOSITY sqlstate" -c "SET ROLE $ROLE" \
            -c "SELECT pg_catalog.set_config('session_replication_role', pg_catalog.current_setting('session_replication_role'), false)" \
            | grep -F 'ERROR' | head -1)"
else
    echo "skip  this user cannot create a role"
fi

echo
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
