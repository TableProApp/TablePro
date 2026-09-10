#!/usr/bin/env bash
#
# Check that SQL_SELECT_LIMIT still means what the MySQL driver assumes it means.
#
# The driver caps a query-tab read by setting the session variable SQL_SELECT_LIMIT to one row past
# the cap, instead of stopping the read on the client and then killing the statement from a second
# connection. That is only safe because of a handful of server behaviours that no test in the repo
# can reach: the variable must bound the outermost result and nothing else, an explicit LIMIT in the
# statement must win, DML that carries a SELECT must copy every row, and DEFAULT must restore. If a
# server release changed any of those, a capped read would silently return wrong data rather than
# fewer rows, so this re-measures them against a live server.
#
# Verified against MariaDB 12.3.2 and MySQL 8.4.11.
#
# Usage:
#   MYSQL_PWD=secret scripts/check-mysql-select-limit.sh [host] [port] [user]
#
# The password is read from MYSQL_PWD only. It is never taken as an argument, because an argument
# lands in this script's own argv and usually in shell history too.
#
# TLS is negotiated normally. Pass --insecure to turn it off, which is refused for anything but a
# loopback host.
#
# Needs a mysql or mariadb client and an account that can create a database. It creates a scratch
# database of its own and drops only that one. Exits non-zero on a disagreement.

set -uo pipefail

INSECURE=0
args=()
for arg in "$@"; do
    case "$arg" in
        --insecure) INSECURE=1 ;;
        *) args+=("$arg") ;;
    esac
done
set -- ${args[@]+"${args[@]}"}

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER="${3:-root}"
ROWS=5000
CAP=5

if [ "$INSECURE" = "1" ]; then
    case "$HOST" in
        127.0.0.1 | ::1 | localhost) ;;
        *)
            echo "--insecure is only allowed against a loopback host, not $HOST" >&2
            exit 2
            ;;
    esac
fi

CLIENT=""
for candidate in mariadb mysql; do
    if command -v "$candidate" > /dev/null 2>&1; then
        CLIENT="$candidate"
        break
    fi
done
[ -n "$CLIENT" ] || {
    echo "neither mariadb nor mysql client found" >&2
    exit 2
}

client_args=(-h "$HOST" -P "$PORT" -u "$USER")
[ "$INSECURE" = "1" ] && client_args+=(--skip-ssl)

run() { "$CLIENT" "${client_args[@]}" -N -B -e "$1" 2> /dev/null; }
run_db() { "$CLIENT" "${client_args[@]}" -N -B "$DB" -e "$1" 2> /dev/null; }

run "SELECT 1" > /dev/null || {
    echo "cannot reach $USER@$HOST:$PORT" >&2
    exit 2
}

SERVER="$(run 'SELECT VERSION()')"
echo "server: $SERVER"

# A fixed name would let this drop somebody's existing database, so it takes a name nothing else
# holds and arms the cleanup only once the CREATE has succeeded. CREATE DATABASE without IF NOT
# EXISTS is what makes the collision an error rather than an adoption.
DB="tablepro_select_limit_check_$$_${RANDOM}"
run "CREATE DATABASE \`$DB\`" > /dev/null
[ "$(run "SELECT COUNT(*) FROM information_schema.schemata WHERE SCHEMA_NAME = '$DB'")" = "1" ] || {
    echo "could not create the scratch database $DB" >&2
    exit 2
}
cleanup() { run "DROP DATABASE IF EXISTS \`$DB\`" > /dev/null; }
trap cleanup EXIT
# Doubling beats a recursive CTE here: MySQL caps one with cte_max_recursion_depth and MariaDB with
# max_recursive_iterations, and neither server knows the other's name for it.
run_db "
CREATE TABLE big (id INT PRIMARY KEY AUTO_INCREMENT, note VARCHAR(32));
CREATE TABLE dest (id INT, note VARCHAR(32));
INSERT INTO big (note) VALUES ('r'),('r'),('r'),('r'),('r'),('r'),('r'),('r'),('r'),('r');
" > /dev/null
while [ "$(run_db 'SELECT COUNT(*) FROM big')" -lt "$ROWS" ] 2> /dev/null; do
    run_db "INSERT INTO big (note) SELECT note FROM big" > /dev/null || break
done

ROWS="$(run_db 'SELECT COUNT(*) FROM big')"
[ -n "$ROWS" ] && [ "$ROWS" -ge 100 ] 2> /dev/null || {
    echo "could not seed the scratch table (got ${ROWS:-none} rows)" >&2
    exit 2
}
echo "seeded $ROWS rows"

failures=0

expect_rows() {
    local label="$1" expected="$2" sql="$3"
    local actual
    actual="$(run_db "SET SQL_SELECT_LIMIT=$CAP; $sql" | wc -l | tr -d ' ')"
    if [ "$actual" = "$expected" ]; then
        printf '  ok    %-52s %s rows\n' "$label" "$actual"
    else
        printf '  FAIL  %-52s expected %s rows, got %s\n' "$label" "$expected" "$actual"
        failures=$((failures + 1))
    fi
}

expect_value() {
    local label="$1" expected="$2" sql="$3"
    local actual
    actual="$(run_db "$sql")"
    if [ "$actual" = "$expected" ]; then
        printf '  ok    %-52s %s\n' "$label" "$actual"
    else
        printf '  FAIL  %-52s expected %s, got %s\n' "$label" "$expected" "${actual:-none}"
        failures=$((failures + 1))
    fi
}

echo "bounds the outermost result (SQL_SELECT_LIMIT=$CAP):"
expect_rows "plain SELECT" "$CAP" "SELECT id FROM big"
expect_rows "UNION ALL" "$CAP" "SELECT id FROM big UNION ALL SELECT id FROM big"
expect_rows "parenthesised UNION ALL" "$CAP" "(SELECT id FROM big) UNION ALL (SELECT id FROM big)"
expect_rows "information_schema SELECT" "$CAP" "SELECT TABLE_NAME FROM information_schema.columns"

echo "an explicit LIMIT wins, in both directions:"
expect_rows "LIMIT below the session value" 3 "SELECT id FROM big LIMIT 3"
expect_rows "LIMIT above the session value" 50 "SELECT id FROM big LIMIT 50"

echo "leaves everything that is not the outermost result alone:"
expect_value "scalar subquery" "$ROWS" \
    "SET SQL_SELECT_LIMIT=$CAP; SELECT (SELECT COUNT(*) FROM big)"
expect_value "derived table" "$ROWS" \
    "SET SQL_SELECT_LIMIT=$CAP; SELECT COUNT(*) FROM (SELECT * FROM big) t"
expect_value "common table expression" "$ROWS" \
    "SET SQL_SELECT_LIMIT=$CAP; SELECT COUNT(*) FROM (WITH x AS (SELECT * FROM big) SELECT * FROM x) y"
expect_value "INSERT ... SELECT copies every row" "$ROWS" \
    "SET SQL_SELECT_LIMIT=$CAP; TRUNCATE dest; INSERT INTO dest SELECT * FROM big; SELECT COUNT(*) FROM dest"
expect_value "REPLACE ... SELECT copies every row" "$ROWS" \
    "SET SQL_SELECT_LIMIT=$CAP; TRUNCATE dest; REPLACE INTO dest SELECT * FROM big; SELECT COUNT(*) FROM dest"
expect_value "CREATE TABLE ... SELECT copies every row" "$ROWS" \
    "SET SQL_SELECT_LIMIT=$CAP; DROP TABLE IF EXISTS ctas; CREATE TABLE ctas AS SELECT * FROM big; SELECT COUNT(*) FROM ctas"

# Counted as rows the client actually received. A COUNT(*) here would pass even if the reset did
# nothing, because the session limit bounds the one-row outer result and not the derived table.
echo "DEFAULT restores the session:"
expect_rows "reset clears the cap" "$ROWS" \
    "SET SQL_SELECT_LIMIT=DEFAULT; SELECT id FROM big"

if [ "$failures" -ne 0 ]; then
    echo
    echo "$failures disagreement(s) against $SERVER." >&2
    echo "MySQLSelectLimitStatement.swift and MariaDBPluginConnection's bounded read rest on these." >&2
    exit 1
fi

echo
echo "all checks agree with $SERVER"
