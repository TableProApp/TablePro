#!/usr/bin/env bash
#
# Check the Table Health queries against real PostgreSQL, MySQL and MariaDB servers.
#
# The report reads pg_stat_user_tables, pg_stat_user_indexes and the catalogs on PostgreSQL, and the
# performance_schema and information_schema on MySQL and MariaDB. Each query is read out of the provider
# source, so the probe and the app cannot drift. The probe builds a database with one table per
# finding and one per near miss (a unique index, a foreign key an index covers in another order, a
# partial index), runs every query, checks which objects come back, then runs the fix the report
# would preview and checks the finding goes away.
#
# Usage:
#   scripts/probes/check-table-health-catalogs.sh postgres <host> <port> <user>
#   scripts/probes/check-table-health-catalogs.sh mysql <host> <port> <user>
#
# Passwords come from PGPASSWORD and MYSQL_PWD. Needs psql or mysql on PATH, and a user that may
# create and drop a database. Exits non-zero on a disagreement, 3 when it cannot run.

set -uo pipefail

ENGINE="${1:-}"
HOST="${2:-127.0.0.1}"
PORT="${3:-}"
USER_NAME="${4:-}"
SOURCES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/TablePro/Core/TableHealth"
DATABASE="tablepro_health_check"
FAILURES=0

# Prints the body of `static let <name> = """ ... """` from a provider file.
swift_literal() {
    awk -v name="$2" '
        $0 ~ "static let " name " = \"\"\"$" { inside = 1; next }
        inside && $0 ~ /^[[:space:]]*"""[[:space:]]*$/ { exit }
        inside { print }
    ' "$1"
}

swift_line_literal() {
    sed -n "s/^[[:space:]]*static let $2 = \"\\(.*\\)\"\$/\\1/p" "$1"
}

expect() {
    local label="$1" output="$2" needle="$3" wanted="$4"
    if grep -qF -- "$needle" <<< "$output"; then found=yes; else found=no; fi
    if [ "$found" = "$wanted" ]; then
        echo "ok    $label"
    else
        echo "FAIL  $label: expected '$needle' present=$wanted" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

query_of() {
    local text
    text="$(swift_literal "$1" "$2")"
    [ -n "$text" ] || {
        echo "FAIL: $2 not found in $1" >&2
        exit 1
    }
    printf '%s' "$text"
}

check_postgres() {
    local source="$SOURCES/PostgreSQLTableHealthProvider.swift"
    command -v psql > /dev/null || { echo "psql not found" >&2; exit 3; }
    export PGOPTIONS="-c client_min_messages=warning"
    pg() { psql -X -q -A -t -F '|' -h "$HOST" -p "$PORT" -U "$USER_NAME" -v ON_ERROR_STOP=1 "$@"; }
    pg -d postgres -c "SELECT 1" > /dev/null 2>&1 || { echo "no PostgreSQL at $HOST:$PORT" >&2; exit 3; }

    echo "PostgreSQL $(pg -d postgres -c 'SHOW server_version') at $HOST:$PORT"
    pg -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" > /dev/null
    pg -d postgres -c "CREATE DATABASE $DATABASE" > /dev/null
    trap 'psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE IF EXISTS '"$DATABASE"'" > /dev/null 2>&1' EXIT

    pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE parent (id int PRIMARY KEY, code int UNIQUE);
CREATE TABLE child_unindexed (id int PRIMARY KEY, parent_id int REFERENCES parent (id));
CREATE TABLE child_indexed (id int PRIMARY KEY, parent_id int REFERENCES parent (id));
CREATE INDEX ON child_indexed (parent_id);
CREATE TABLE pair (x int, y int, PRIMARY KEY (x, y));
CREATE TABLE child_pair (id int PRIMARY KEY, x int, y int, CONSTRAINT child_pair_fk FOREIGN KEY (x, y) REFERENCES pair (x, y));
CREATE INDEX ON child_pair (y, x);
CREATE TABLE child_pair_unindexed (id int PRIMARY KEY, x int, y int, CONSTRAINT child_pair_unindexed_fk FOREIGN KEY (y, x) REFERENCES pair (y, x));
CREATE TABLE child_partial (id int PRIMARY KEY, parent_id int REFERENCES parent (id));
CREATE INDEX ON child_partial (parent_id) WHERE parent_id > 0;
CREATE TABLE child_second (id int PRIMARY KEY, other int, parent_id int REFERENCES parent (id));
CREATE INDEX ON child_second (other, parent_id);
CREATE TABLE child_include (id int PRIMARY KEY, x int, y int, CONSTRAINT child_include_fk FOREIGN KEY (x, y) REFERENCES pair (x, y));
CREATE TABLE no_pk (v int);
CREATE INDEX no_pk_unused_idx ON no_pk (v);
CREATE UNIQUE INDEX no_pk_unique_idx ON no_pk ((v + 1));
CREATE TABLE "Odd ""Name""" (v int);
CREATE TABLE bloated (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = false);
INSERT INTO bloated SELECT g, g FROM generate_series(1, 5000) g;
DELETE FROM bloated WHERE id <= 3000;
CREATE TABLE healthy (id int PRIMARY KEY) WITH (autovacuum_enabled = false);
INSERT INTO healthy SELECT g FROM generate_series(1, 5000) g;
DELETE FROM healthy WHERE id <= 10;
SQL

    local bloat="" attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        bloat="$(pg -d "$DATABASE" -c "$(query_of "$source" bloatQuery)")"
        grep -qF "bloated" <<< "$bloat" && break
        sleep 1
    done
    expect "bloat lists a table with 60% dead rows" "$bloat" "public|bloated|2000|3000|" yes
    expect "bloat skips a table with few dead rows" "$bloat" "|healthy|" no

    local unused
    unused="$(pg -d "$DATABASE" -c "$(query_of "$source" unusedIndexQuery)")"
    expect "unused index lists a plain index" "$unused" "|no_pk_unused_idx|" yes
    expect "unused index skips a unique index" "$unused" "no_pk_unique_idx" no
    expect "unused index skips a primary key" "$unused" "parent_pkey" no
    expect "unused index skips a unique constraint" "$unused" "parent_code_key" no

    local nopk
    nopk="$(pg -d "$DATABASE" -c "$(query_of "$source" missingPrimaryKeyQuery)")"
    expect "missing primary key lists a heap" "$nopk" "public|no_pk" yes
    expect "missing primary key lists a quoted name" "$nopk" 'public|Odd "Name"' yes
    expect "missing primary key skips a keyed table" "$nopk" "|parent" no
    expect "missing primary key skips the system catalogs" "$nopk" "pg_catalog" no

    local fk
    fk="$(pg -d "$DATABASE" -c "$(query_of "$source" unindexedForeignKeyQuery)")"
    expect "foreign key without an index" "$fk" "child_unindexed_parent_id_fkey|parent_id" yes
    expect "foreign key behind a partial index" "$fk" "child_partial_parent_id_fkey" yes
    expect "foreign key on an index's second column" "$fk" "child_second_parent_id_fkey" yes
    expect "composite key columns in key order" "$fk" "child_pair_unindexed_fk|y" yes
    expect "foreign key with an index" "$fk" "child_indexed_parent_id_fkey" no
    if [ "$(pg -d "$DATABASE" -c 'SHOW server_version_num')" -ge 110000 ]; then
        pg -d "$DATABASE" -c 'CREATE INDEX ON child_include (x) INCLUDE (y)' > /dev/null
        fk="$(pg -d "$DATABASE" -c "$(query_of "$source" unindexedForeignKeyQuery)")"
        expect "an INCLUDE column does not cover a key column" "$fk" "child_include_fk" yes
        pg -d "$DATABASE" -c 'CREATE INDEX ON child_include (y, x)' > /dev/null
        fk="$(pg -d "$DATABASE" -c "$(query_of "$source" unindexedForeignKeyQuery)")"
        expect "key columns in an index cover the key" "$fk" "child_include_fk" no
    fi
    expect "composite key an index covers in another order" "$fk" "child_pair_fk|" no

    local name
    name="$(pg -d "$DATABASE" -c "$(swift_line_literal "$source" databaseNameQuery)")"
    expect "the database name query names this database" "$name" "$DATABASE" yes

    local stats
    stats="$(pg -d "$DATABASE" -c "$(query_of "$source" statisticsResetQuery)")"
    echo "ok    statistics reset query ran: '${stats}'"

    # The fixes exactly as PostgreSQLTableHealthProviderTests pins them.
    pg -d "$DATABASE" -c 'CREATE INDEX CONCURRENTLY ON "public"."child_unindexed" ("parent_id");' > /dev/null
    pg -d "$DATABASE" -c 'VACUUM (ANALYZE) "public"."bloated";' > /dev/null
    pg -d "$DATABASE" -c 'DROP INDEX CONCURRENTLY "public"."no_pk_unused_idx";' > /dev/null
    pg -d "$DATABASE" -c 'ALTER TABLE "public"."no_pk" ADD PRIMARY KEY (v);' > /dev/null

    fk="$(pg -d "$DATABASE" -c "$(query_of "$source" unindexedForeignKeyQuery)")"
    expect "the previewed index clears its finding" "$fk" "child_unindexed_parent_id_fkey" no
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        bloat="$(pg -d "$DATABASE" -c "$(query_of "$source" bloatQuery)")"
        grep -qF "bloated" <<< "$bloat" || break
        sleep 1
    done
    expect "the previewed vacuum clears its finding" "$bloat" "bloated" no
    unused="$(pg -d "$DATABASE" -c "$(query_of "$source" unusedIndexQuery)")"
    expect "the previewed drop clears its finding" "$unused" "no_pk_unused_idx" no
    nopk="$(pg -d "$DATABASE" -c "$(query_of "$source" missingPrimaryKeyQuery)")"
    expect "the previewed primary key clears its finding" "$nopk" "public|no_pk" no
}

check_mysql() {
    local source="$SOURCES/MySQLTableHealthProvider.swift"
    command -v mysql > /dev/null || { echo "mysql not found" >&2; exit 3; }
    # MariaDB's client warns on stderr about a passwordless certificate check, which would land in captured output.
    local tls=()
    mysql --help 2>/dev/null | grep -q -- "--ssl-verify-server-cert" && tls=(--disable-ssl-verify-server-cert)
    my() { mysql --protocol=TCP -h "$HOST" -P "$PORT" -u "$USER_NAME" "${tls[@]}" -N -B "$@"; }
    my -e "SELECT 1" > /dev/null 2>&1 || { echo "no MySQL at $HOST:$PORT" >&2; exit 3; }

    echo "$(my -e 'SELECT VERSION()') at $HOST:$PORT"
    my -e "DROP DATABASE IF EXISTS $DATABASE; CREATE DATABASE $DATABASE"
    trap 'mysql --protocol=TCP -h "$HOST" -P "$PORT" -u "$USER_NAME" -e "DROP DATABASE IF EXISTS '"$DATABASE"'" > /dev/null 2>&1' EXIT

    my "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE parent (id INT PRIMARY KEY);
CREATE TABLE no_pk (a INT, b INT, KEY no_pk_a_idx (a), KEY no_pk_ab_idx (a, b), UNIQUE KEY no_pk_b_uniq (b));
CREATE TABLE `odd``name` (v INT);
CREATE TABLE healthy (id INT PRIMARY KEY, v INT, KEY healthy_v_idx (v));
INSERT INTO healthy VALUES (1, 1), (2, 2), (3, 3);
INSERT INTO no_pk VALUES (1, 1), (2, 2);
SELECT COUNT(*) FROM healthy FORCE INDEX (healthy_v_idx) WHERE v = 2;
SQL
    [ $? -eq 0 ] || exit 1

    local ps
    ps="$(my -e "$(swift_line_literal "$source" performanceSchemaQuery)")"
    echo "ok    performance_schema = $ps"
    local uptime
    uptime="$(my -e "$(swift_line_literal "$source" uptimeQuery)")"
    expect "uptime reads as Uptime and a value" "$uptime" "Uptime" yes

    local unused
    unused="$(my -e "$(query_of "$source" unusedIndexQuery)")"
    if [ "$ps" = "1" ]; then
        expect "unused index lists a plain index" "$unused" "no_pk_a_idx" yes
        expect "unused index skips a unique index" "$unused" "no_pk_b_uniq" no
        expect "unused index skips an index a query read" "$unused" "healthy_v_idx" no
    else
        echo "note  performance_schema is off, so the unused index list is empty: '$unused'"
    fi

    # The prefix comparison runs in Swift (MySQLTableHealthProviderTests); here the rows it reads.
    local redundant
    redundant="$(my -e "$(query_of "$source" redundantIndexQuery)")"
    expect "index rows carry the first key column" "$redundant" "$DATABASE	no_pk	no_pk_ab_idx	1	BTREE	a	" yes
    expect "index rows carry the second key column" "$redundant" "$DATABASE	no_pk	no_pk_ab_idx	1	BTREE	b	" yes
    expect "index rows mark a unique index" "$redundant" "$DATABASE	no_pk	no_pk_b_uniq	0	BTREE	b	" yes
    expect "index rows skip the system schemas" "$redundant" "mysql	" no

    local nopk
    nopk="$(my -e "$(query_of "$source" missingPrimaryKeyQuery)")"
    expect "missing primary key lists a heap" "$nopk" "$DATABASE	no_pk" yes
    expect "missing primary key lists a quoted name" "$nopk" "odd\`name" yes
    expect "missing primary key skips a keyed table" "$nopk" "	parent" no
    expect "missing primary key skips the system schemas" "$nopk" "mysql	" no

    # The fixes exactly as MySQLTableHealthProviderTests pins them.
    my -e "ALTER TABLE \`$DATABASE\`.\`no_pk\` DROP INDEX \`no_pk_a_idx\`;"
    my -e "ALTER TABLE \`$DATABASE\`.\`odd\`\`name\` ADD PRIMARY KEY (v);"
    nopk="$(my -e "$(query_of "$source" missingPrimaryKeyQuery)")"
    expect "the previewed primary key clears its finding" "$nopk" "odd\`name" no
    redundant="$(my -e "$(query_of "$source" redundantIndexQuery)")"
    expect "the previewed drop clears its finding" "$redundant" "no_pk_a_idx" no
}

case "$ENGINE" in
    postgres) check_postgres ;;
    mysql) check_mysql ;;
    *)
        echo "usage: $0 postgres|mysql <host> <port> <user>" >&2
        exit 3
        ;;
esac

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed" >&2
    exit 1
fi
echo "PASS"
