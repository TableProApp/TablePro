#!/usr/bin/env bash
#
# Check that the MySQL driver's catalog statements still reach another database.
#
# Every metadata read in MySQLPluginDriver names the database the caller asked for rather than
# letting the name resolve against whatever database the connection is on, because an unqualified
# name silently answers about a same-named table in the session's database. Which qualifier form
# each statement takes is not uniform and is transcribed by hand: SHOW FULL COLUMNS, SHOW INDEX,
# SHOW CREATE TABLE, SHOW CREATE VIEW and DROP TRIGGER take a dotted name, while SHOW TABLE STATUS
# takes a FROM clause of its own. Emitting both forms is worse than emitting neither: the trailing
# FROM silently overrides the dotted qualifier and answers about the wrong database.
#
# This builds two databases holding same-named tables with different columns, runs each statement
# from a session on the wrong one, and fails if any of them answers about the session's database
# or stops accepting the form the driver emits. Run it against any MySQL-protocol engine the
# plugin claims to support before trusting a new flavor: MySQL, MariaDB, TiDB, OceanBase.
#
# Usage:
#   scripts/check-mysql-cross-database-catalog.sh [host] [port] [user]
#
# Needs the mysql client and an account that can create and drop databases. The password, if any,
# comes from MYSQL_PWD. Exits non-zero on a disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-root}"

# Fixed names would let this drop somebody's existing database, and two runs would delete each
# other's fixtures, so each run takes names nothing else holds and arms the cleanup only once the
# CREATE has succeeded. CREATE DATABASE without IF NOT EXISTS makes a collision an error rather
# than an adoption.
SUFFIX="$$_${RANDOM}"
REF_DB="tp_xdb_referenced_$SUFFIX"
SESSION_DB="tp_xdb_session_$SUFFIX"

command -v mysql > /dev/null || {
    echo "mysql client not found" >&2
    exit 3
}

MYSQL=(mysql --no-defaults -h "$HOST" -P "$PORT" -u "$USER_NAME" -N -B -r --default-character-set=utf8mb4)
if ! "${MYSQL[@]}" -e "SELECT 1" > /dev/null 2>&1; then
    echo "no MySQL-protocol server at $HOST:$PORT for $USER_NAME" >&2
    exit 3
fi

"${MYSQL[@]}" -e "CREATE DATABASE \`$REF_DB\`; CREATE DATABASE \`$SESSION_DB\`;" || {
    echo "could not create the scratch databases" >&2
    exit 3
}
drop_fixture() {
    "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`$REF_DB\`; DROP DATABASE IF EXISTS \`$SESSION_DB\`;" > /dev/null 2>&1
}
trap drop_fixture EXIT

# Every fixture carries a marker only its own database has, including the index name and the table
# comment: without those, SHOW INDEX and SHOW TABLE STATUS answer identically for both databases
# and their checks would pass through a regression in the qualifier.
"${MYSQL[@]}" <<SQL || exit 3
CREATE TABLE \`$REF_DB\`.customers (
    id INT PRIMARY KEY, referenced_only VARCHAR(8),
    UNIQUE KEY idx_referenced_only (referenced_only)
) COMMENT = 'referenced_comment';
CREATE TABLE \`$SESSION_DB\`.customers (
    id INT PRIMARY KEY, session_only VARCHAR(8),
    UNIQUE KEY idx_session_only (session_only)
) COMMENT = 'session_comment';
CREATE VIEW \`$REF_DB\`.customer_view AS SELECT id FROM \`$REF_DB\`.customers;
CREATE VIEW \`$SESSION_DB\`.customer_view AS SELECT id FROM \`$SESSION_DB\`.customers;
SQL

FAILURES=0

# Every statement runs from a session on SESSION_DB and must answer about REF_DB. The marker
# column exists only in REF_DB, so its absence means the statement resolved against the session.
check() {
    local label="$1" statement="$2" marker="$3"
    local output
    if ! output="$("${MYSQL[@]}" -D "$SESSION_DB" -e "$statement" 2>&1)"; then
        echo "FAIL $label: the server rejected the statement"
        echo "     $statement"
        echo "     ${output//$'\n'/$'\n'     }"
        FAILURES=$((FAILURES + 1))
        return
    fi
    if ! grep -q -- "$marker" <<< "$output"; then
        echo "FAIL $label: answered about $SESSION_DB, not $REF_DB"
        echo "     $statement"
        FAILURES=$((FAILURES + 1))
        return
    fi
    echo "ok   $label"
}

check "SHOW FULL COLUMNS" \
    "SHOW FULL COLUMNS FROM \`$REF_DB\`.\`customers\`" referenced_only
check "SHOW INDEX" \
    "SHOW INDEX FROM \`$REF_DB\`.\`customers\`" idx_referenced_only
check "SHOW CREATE TABLE" \
    "SHOW CREATE TABLE \`$REF_DB\`.\`customers\`" referenced_only
check "SHOW CREATE VIEW" \
    "SHOW CREATE VIEW \`$REF_DB\`.\`customer_view\`" "$REF_DB"
check "SHOW TABLE STATUS" \
    "SHOW TABLE STATUS FROM \`$REF_DB\` WHERE Name = 'customers'" referenced_comment
check "INFORMATION_SCHEMA.COLUMNS" \
    "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = '$REF_DB' AND TABLE_NAME = 'customers'" \
    referenced_only

# The trap the driver must never spring: both qualifier forms at once. The trailing FROM wins, so
# a statement carrying both answers about the session's database while looking correct.
BOTH="$("${MYSQL[@]}" -D "$SESSION_DB" \
    -e "SHOW FULL COLUMNS FROM \`$REF_DB\`.\`customers\` FROM \`$SESSION_DB\`" 2>&1)"
if grep -q -- referenced_only <<< "$BOTH"; then
    echo "note two qualifier forms no longer conflict on this server; the driver still emits one"
else
    echo "ok   two qualifier forms conflict, as the driver assumes: the trailing FROM wins"
fi

if [ "$FAILURES" -ne 0 ]; then
    echo
    echo "$FAILURES catalog statement(s) do not reach another database on this server." >&2
    echo "MySQLPluginDriver+Schema.swift and MySQLObjectQueries.swift assume they do." >&2
    exit 1
fi

echo
echo "every catalog statement reached $REF_DB from a session on $SESSION_DB"
