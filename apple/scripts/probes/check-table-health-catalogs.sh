#!/usr/bin/env bash
#
# Check the Table Health queries against real PostgreSQL, MySQL and MariaDB servers.
#
# Each query is read out of the provider source, so the probe and the app cannot drift. The probe
# builds a database with one object per finding and one per near miss, runs every query, checks
# which objects come back, then runs the fix the report would preview and checks the finding goes.
# The MySQL checks that combine rows in Swift (unused minus unique and foreign key indexes,
# redundant indexes) are pinned by MySQLTableHealthProviderTests; here, the rows they read.
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
OTHER_DATABASE="tablepro_health_other"
FAILURES=0

# Prints the body of `static let <name> = """ ... """`, or the text of `static let <name> = "..."`.
query_of() {
    local text
    text="$(awk -v name="$2" '
        $0 ~ "static let " name " = \"\"\"$" { inside = 1; next }
        inside && $0 ~ /^[[:space:]]*"""[[:space:]]*$/ { exit }
        inside { print }
    ' "$1")"
    [ -n "$text" ] || text="$(sed -n "s/^[[:space:]]*static let $2 = \"\\(.*\\)\"\$/\\1/p" "$1")"
    [ -n "$text" ] || {
        echo "FAIL: $2 not found in $1" >&2
        exit 1
    }
    printf '%s' "$text"
}

expect() {
    local label="$1" output="$2" needle="$3" wanted="$4" found=no
    grep -qF -- "$needle" <<< "$output" && found=yes
    if [ "$found" = "$wanted" ]; then
        echo "ok    $label"
    else
        echo "FAIL  $label: expected '$needle' present=$wanted" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

check_postgres() {
    local source="$SOURCES/PostgreSQLTableHealthProvider.swift"
    command -v psql > /dev/null || { echo "psql not found" >&2; exit 3; }
    export PGOPTIONS="-c client_min_messages=warning"
    pg() { psql -X -q -A -t -F '|' -h "$HOST" -p "$PORT" -U "$USER_NAME" -v ON_ERROR_STOP=1 "$@"; }
    pg -d postgres -c "SELECT 1" > /dev/null 2>&1 || { echo "no PostgreSQL at $HOST:$PORT" >&2; exit 3; }
    local version
    version="$(pg -d postgres -c 'SHOW server_version_num')"

    echo "PostgreSQL $(pg -d postgres -c 'SHOW server_version') at $HOST:$PORT"
    pg -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" > /dev/null
    pg -d postgres -c "CREATE DATABASE $DATABASE" > /dev/null
    trap 'psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE IF EXISTS '"$DATABASE"' WITH (FORCE)" > /dev/null 2>&1 || psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE IF EXISTS '"$DATABASE"'" > /dev/null 2>&1' EXIT

    pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE parent (id int PRIMARY KEY, code int UNIQUE);
CREATE TABLE child_unindexed (id int PRIMARY KEY, parent_id int REFERENCES parent (id));
CREATE TABLE child_indexed (id int PRIMARY KEY, parent_id int REFERENCES parent (id));
CREATE INDEX child_indexed_parent_idx ON child_indexed (parent_id);
CREATE TABLE pair (x int, y int, PRIMARY KEY (x, y));
CREATE TABLE child_pair (id int PRIMARY KEY, x int, y int, CONSTRAINT child_pair_fk FOREIGN KEY (x, y) REFERENCES pair (x, y));
CREATE INDEX child_pair_yx_idx ON child_pair (y, x);
CREATE TABLE child_pair_unindexed (id int PRIMARY KEY, x int, y int, CONSTRAINT child_pair_unindexed_fk FOREIGN KEY (y, x) REFERENCES pair (y, x));
CREATE TABLE child_partial (id int PRIMARY KEY, parent_id int REFERENCES parent (id));
CREATE INDEX child_partial_idx ON child_partial (parent_id) WHERE parent_id > 0;
CREATE TABLE child_second (id int PRIMARY KEY, other int, parent_id int REFERENCES parent (id));
CREATE INDEX ON child_second (other, parent_id);
CREATE TABLE child_include (id int PRIMARY KEY, x int, y int, CONSTRAINT child_include_fk FOREIGN KEY (x, y) REFERENCES pair (x, y));
CREATE TABLE no_pk (v int);
CREATE INDEX no_pk_unused_idx ON no_pk (v);
CREATE UNIQUE INDEX no_pk_unique_idx ON no_pk ((v + 1));
CREATE TABLE "Odd ""Name""" (v int);
CREATE MATERIALIZED VIEW stock AS SELECT g AS v FROM generate_series(1, 10) g;
CREATE INDEX stock_v_idx ON stock (v);
CREATE TABLE bloated (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = false);
INSERT INTO bloated SELECT g, g FROM generate_series(1, 5000) g;
DELETE FROM bloated WHERE id <= 3000;
CREATE TABLE healthy (id int PRIMARY KEY) WITH (autovacuum_enabled = false);
INSERT INTO healthy SELECT g FROM generate_series(1, 5000) g;
DELETE FROM healthy WHERE id <= 10;
SQL
    if [ "$version" -ge 110000 ]; then
        pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE events (at date, kind text, parent_id int REFERENCES parent (id)) PARTITION BY RANGE (at);
CREATE TABLE events_2026 PARTITION OF events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE events_2027 PARTITION OF events FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');
CREATE INDEX events_kind_idx ON events (kind);
SQL
    fi

    # Another session's temporary table lives in its own pg_temp schema while that session is open.
    psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" \
        -c "CREATE TEMP TABLE probe_temp (v int)" -c "CREATE INDEX probe_temp_idx ON probe_temp (v)" -c "SELECT pg_sleep(30)" \
        > /dev/null 2>&1 &
    local holder=$! temp_ready=0
    for _ in $(seq 1 20); do
        [ "$(pg -d "$DATABASE" -c "SELECT count(*) FROM pg_class WHERE relname = 'probe_temp_idx'")" = "1" ] && { temp_ready=1; break; }
        sleep 0.5
    done
    [ "$temp_ready" = 1 ] || echo "note  another session's temporary table did not appear; its checks are vacuous" >&2

    local stats
    stats="$(pg -d "$DATABASE" -c "$(query_of "$source" statisticsQuery)")"
    expect "statistics read track_counts" "$stats" "on|" yes
    stats="$(PGOPTIONS="$PGOPTIONS -c track_counts=off" pg -d "$DATABASE" -c "$(query_of "$source" statisticsQuery)")"
    expect "statistics see track_counts off" "$stats" "off|" yes

    local bloat=""
    for _ in $(seq 1 10); do
        bloat="$(pg -d "$DATABASE" -c "$(query_of "$source" bloatQuery)")"
        grep -qF "bloated" <<< "$bloat" && break
        sleep 1
    done
    expect "bloat lists a table with 60% dead rows" "$bloat" "public|bloated|2000|3000|" yes
    expect "bloat skips a table with few dead rows" "$bloat" "|healthy|" no

    local unused
    unused="$(pg -d "$DATABASE" -c "$(query_of "$source" unusedIndexQuery)")"
    expect "unused index lists a plain index" "$unused" "|no_pk_unused_idx|" yes
    expect "unused index lists a partial index, which serves no foreign key" "$unused" "|child_partial_idx|" yes
    expect "unused index skips a unique index" "$unused" "no_pk_unique_idx" no
    expect "unused index skips a primary key" "$unused" "parent_pkey" no
    expect "unused index skips a unique constraint" "$unused" "parent_code_key" no
    expect "unused index skips an index behind a foreign key" "$unused" "child_indexed_parent_idx" no
    expect "unused index skips an index behind a key in another order" "$unused" "child_pair_yx_idx" no
    expect "unused index skips a materialized view's index" "$unused" "stock_v_idx" no
    expect "unused index skips another session's temporary table" "$unused" "probe_temp_idx" no
    if [ "$version" -ge 110000 ]; then
        expect "unused index skips a partition index its parent owns" "$unused" "events_2026_kind_idx" no
    fi

    local nopk
    nopk="$(pg -d "$DATABASE" -c "$(query_of "$source" missingPrimaryKeyQuery)")"
    expect "missing primary key lists a heap" "$nopk" "public|no_pk" yes
    expect "missing primary key lists a quoted name" "$nopk" 'public|Odd "Name"' yes
    expect "missing primary key skips a keyed table" "$nopk" "|parent" no
    expect "missing primary key skips the system catalogs" "$nopk" "pg_catalog" no
    expect "missing primary key skips another session's temporary table" "$nopk" "probe_temp" no
    if [ "$version" -ge 110000 ]; then
        expect "missing primary key lists a partitioned table" "$nopk" "public|events" yes
        expect "missing primary key skips its partitions" "$nopk" "events_2026" no
    fi

    local fk
    fk="$(pg -d "$DATABASE" -c "$(query_of "$source" unindexedForeignKeyQuery)")"
    expect "foreign key without an index" "$fk" "child_unindexed|r|child_unindexed_parent_id_fkey|parent_id" yes
    expect "foreign key behind a partial index" "$fk" "child_partial_parent_id_fkey" yes
    expect "foreign key on an index's second column" "$fk" "child_second_parent_id_fkey" yes
    expect "composite key columns in key order" "$fk" "child_pair_unindexed_fk|y" yes
    expect "foreign key with an index" "$fk" "child_indexed_parent_id_fkey" no
    expect "composite key an index covers in another order" "$fk" "child_pair_fk|" no
    if [ "$version" -ge 110000 ]; then
        expect "a partitioned table's key names the table kind" "$fk" "|events|p|" yes
        expect "a partition's cloned key is left to its parent" "$fk" "events_2026" no
        pg -d "$DATABASE" -c 'CREATE INDEX ON child_include (x) INCLUDE (y)' > /dev/null
        fk="$(pg -d "$DATABASE" -c "$(query_of "$source" unindexedForeignKeyQuery)")"
        expect "an INCLUDE column does not cover a key column" "$fk" "child_include_fk" yes
        pg -d "$DATABASE" -c 'CREATE INDEX ON child_include (y, x)' > /dev/null
        fk="$(pg -d "$DATABASE" -c "$(query_of "$source" unindexedForeignKeyQuery)")"
        expect "key columns in an index cover the key" "$fk" "child_include_fk" no
    fi

    # The fixes exactly as PostgreSQLTableHealthProviderTests pins them.
    pg -d "$DATABASE" -c 'CREATE INDEX CONCURRENTLY ON "public"."child_unindexed" ("parent_id");' > /dev/null
    pg -d "$DATABASE" -c 'VACUUM (ANALYZE) "public"."bloated";' > /dev/null
    pg -d "$DATABASE" -c 'DROP INDEX CONCURRENTLY "public"."no_pk_unused_idx";' > /dev/null
    pg -d "$DATABASE" -c 'ALTER TABLE "public"."no_pk" ADD PRIMARY KEY (v);' > /dev/null
    if [ "$version" -ge 110000 ]; then
        pg -d "$DATABASE" -c 'CREATE INDEX ON "public"."events" ("parent_id");' > /dev/null
    fi

    fk="$(pg -d "$DATABASE" -c "$(query_of "$source" unindexedForeignKeyQuery)")"
    expect "the previewed index clears its finding" "$fk" "child_unindexed_parent_id_fkey" no
    if [ "$version" -ge 110000 ]; then
        expect "the previewed partitioned index clears its finding" "$fk" "|events|" no
    fi
    for _ in $(seq 1 10); do
        bloat="$(pg -d "$DATABASE" -c "$(query_of "$source" bloatQuery)")"
        grep -qF "bloated" <<< "$bloat" || break
        sleep 1
    done
    expect "the previewed vacuum clears its finding" "$bloat" "bloated" no
    unused="$(pg -d "$DATABASE" -c "$(query_of "$source" unusedIndexQuery)")"
    expect "the previewed drop clears its finding" "$unused" "no_pk_unused_idx" no
    nopk="$(pg -d "$DATABASE" -c "$(query_of "$source" missingPrimaryKeyQuery)")"
    expect "the previewed primary key clears its finding" "$nopk" "public|no_pk" no

    kill "$holder" 2> /dev/null
    wait "$holder" 2> /dev/null
}

check_mysql() {
    local source="$SOURCES/MySQLTableHealthProvider.swift"
    command -v mysql > /dev/null || { echo "mysql not found" >&2; exit 3; }
    # MariaDB's client warns on stderr about a passwordless certificate check, which would land in captured output.
    local tls=()
    mysql --help 2> /dev/null | grep -q -- "--ssl-verify-server-cert" && tls=(--disable-ssl-verify-server-cert)
    # bash 3.2 calls an empty "${tls[@]}" unbound under set -u.
    my() { mysql --protocol=TCP -h "$HOST" -P "$PORT" -u "$USER_NAME" ${tls[@]+"${tls[@]}"} -N -B "$@"; }
    my -e "SELECT 1" > /dev/null || { echo "no MySQL at $HOST:$PORT" >&2; exit 3; }

    echo "$(my -e 'SELECT VERSION()') at $HOST:$PORT"
    my -e "DROP DATABASE IF EXISTS $DATABASE; CREATE DATABASE $DATABASE; DROP DATABASE IF EXISTS $OTHER_DATABASE; CREATE DATABASE $OTHER_DATABASE"
    trap 'mysql --protocol=TCP -h "$HOST" -P "$PORT" -u "$USER_NAME" -e "DROP DATABASE IF EXISTS '"$DATABASE"'; DROP DATABASE IF EXISTS '"$OTHER_DATABASE"'; UPDATE performance_schema.setup_instruments SET ENABLED = '"'YES'"' WHERE NAME = '"'wait/io/table/sql/handler'"'; DELETE FROM performance_schema.setup_objects WHERE OBJECT_SCHEMA = '"'$DATABASE'"'" > /dev/null 2>&1' EXIT

    my "$OTHER_DATABASE" -e "CREATE TABLE other_no_pk (v INT, KEY other_v_idx (v)); INSERT INTO other_no_pk VALUES (1)"
    # A table setup_objects leaves out keeps zero-count index rows even after a read through the index.
    my -e "INSERT INTO performance_schema.setup_objects (OBJECT_TYPE, OBJECT_SCHEMA, OBJECT_NAME, ENABLED, TIMED) VALUES ('TABLE', '$DATABASE', 'uncounted', 'NO', 'NO')" 2> /dev/null
    my "$DATABASE" > /dev/null <<'SQL' || exit 1
CREATE TABLE parent (id INT PRIMARY KEY);
CREATE TABLE child (id INT PRIMARY KEY, parent_id INT, note INT, CONSTRAINT child_fk FOREIGN KEY (parent_id) REFERENCES parent (id), KEY child_note_idx (note));
CREATE TABLE no_pk (a INT, b INT, KEY no_pk_a_idx (a), KEY no_pk_ab_idx (a, b), UNIQUE KEY no_pk_b_uniq (b));
CREATE TABLE `odd``name` (v INT);
CREATE TABLE healthy (id INT PRIMARY KEY, v INT, KEY healthy_v_idx (v));
CREATE TABLE uncounted (id INT PRIMARY KEY, v INT, KEY uncounted_v_idx (v));
INSERT INTO uncounted VALUES (1, 1), (2, 2);
FLUSH TABLES;
SELECT COUNT(*) FROM uncounted FORCE INDEX (uncounted_v_idx) WHERE v = 2;
INSERT INTO parent VALUES (1);
INSERT INTO child VALUES (1, 1, 1);
INSERT INTO healthy VALUES (1, 1), (2, 2), (3, 3);
INSERT INTO no_pk VALUES (1, 1), (2, 2);
SELECT COUNT(*) FROM healthy FORCE INDEX (healthy_v_idx) WHERE v = 2;
SQL

    local ps
    ps="$(my "$DATABASE" -e "$(query_of "$source" performanceSchemaQuery)")"
    echo "ok    performance_schema = $ps"
    local uptime
    uptime="$(my "$DATABASE" -e "$(query_of "$source" uptimeQuery)")"
    expect "uptime reads as Uptime and a value" "$uptime" "Uptime" yes

    local counting
    counting="$(my "$DATABASE" -e "$(query_of "$source" usageCountingQuery)")"
    if [ "$ps" = "1" ]; then
        expect "the handler instrument and global consumer read as enabled" "$counting" "YES	YES	" yes
        expect "this database has counted table I/O" "$counting" "	0" no
        my -e "UPDATE performance_schema.setup_instruments SET ENABLED = 'NO' WHERE NAME = 'wait/io/table/sql/handler'"
        counting="$(my "$DATABASE" -e "$(query_of "$source" usageCountingQuery)")"
        my -e "UPDATE performance_schema.setup_instruments SET ENABLED = 'YES' WHERE NAME = 'wait/io/table/sql/handler'"
        expect "a disabled handler instrument reads as NO" "$counting" "NO	YES	" yes
    else
        echo "note  performance_schema is off, so the unused index check is skipped: '$counting'"
    fi

    local unused
    unused="$(my "$DATABASE" -e "$(query_of "$source" unusedIndexQuery)")"
    if [ "$ps" = "1" ]; then
        expect "unused candidates list a plain index" "$unused" "no_pk	no_pk_a_idx" yes
        expect "unused candidates list the foreign key's own index, which InnoDB reads uncounted" "$unused" "child	child_fk" yes
        expect "unused candidates skip an index a query read" "$unused" "healthy_v_idx" no
        expect "unused candidates skip another database" "$unused" "other_v_idx" no
        expect "unused candidates skip a table setup_objects leaves uncounted" "$unused" "uncounted_v_idx" no
    fi
    local drop_fk_index
    drop_fk_index="$(my "$DATABASE" -e 'ALTER TABLE child DROP INDEX child_fk' 2>&1)"
    expect "InnoDB refuses to drop the index a foreign key needs" "$drop_fk_index" "1553" yes

    local indexes
    indexes="$(my "$DATABASE" --column-names -e "$(query_of "$source" indexQuery)")"
    expect "index rows carry NON_UNIQUE, INDEX_TYPE and SUB_PART by name" "$indexes" "NON_UNIQUE" yes
    expect "index rows list a composite index" "$indexes" "no_pk_ab_idx" yes
    expect "index rows skip another database" "$indexes" "other_v_idx" no
    if my -e "SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'information_schema' AND TABLE_NAME = 'STATISTICS' AND COLUMN_NAME = 'IS_VISIBLE'" | grep -q 1; then
        expect "MySQL index rows carry IS_VISIBLE" "$indexes" "IS_VISIBLE" yes
    fi
    if my -e "SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = 'information_schema' AND TABLE_NAME = 'STATISTICS' AND COLUMN_NAME = 'IGNORED'" | grep -q 1; then
        expect "MariaDB index rows carry IGNORED" "$indexes" "IGNORED" yes
    fi

    local keys
    keys="$(my "$DATABASE" -e "$(query_of "$source" foreignKeyQuery)")"
    expect "foreign key rows name both ends" "$keys" "child	child_fk	parent_id	parent	id" yes

    local nopk
    nopk="$(my "$DATABASE" -e "$(query_of "$source" missingPrimaryKeyQuery)")"
    expect "missing primary key lists a heap" "$nopk" "no_pk" yes
    expect "missing primary key lists a quoted name" "$nopk" "odd\`name" yes
    expect "missing primary key skips a keyed table" "$nopk" "parent" no
    expect "missing primary key skips another database" "$nopk" "other_no_pk" no

    # The fixes exactly as MySQLTableHealthProviderTests pins them.
    my -e "ALTER TABLE \`$DATABASE\`.\`no_pk\` DROP INDEX \`no_pk_a_idx\`;"
    my -e "ALTER TABLE \`$DATABASE\`.\`odd\`\`name\` ADD PRIMARY KEY (v);"
    nopk="$(my "$DATABASE" -e "$(query_of "$source" missingPrimaryKeyQuery)")"
    expect "the previewed primary key clears its finding" "$nopk" "odd\`name" no
    indexes="$(my "$DATABASE" -e "$(query_of "$source" indexQuery)")"
    expect "the previewed drop clears its finding" "$indexes" "no_pk_a_idx" no
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
