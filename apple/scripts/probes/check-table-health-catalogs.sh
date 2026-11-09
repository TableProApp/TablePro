#!/usr/bin/env bash
#
# Check the Table Health queries against real PostgreSQL, MySQL and MariaDB servers.
#
# Each query is read out of the provider source, so the probe and the app cannot drift. The probe
# builds a database with one object per finding and one per near miss, runs every query, checks
# which objects come back, then runs the fix the report would preview and checks the finding goes.
# The checks that combine rows in Swift (MySQL unused minus unique and foreign key indexes, redundant
# indexes on both engines) are pinned by MySQLTableHealthProviderTests and PostgreSQLIndexShapeTests;
# here, the rows they read.
#
# Usage:
#   scripts/probes/check-table-health-catalogs.sh postgres <host> <port> <user>
#   scripts/probes/check-table-health-catalogs.sh mysql <host> <port> <user>
#
# TABLEPRO_PROBE_RECLAIMABLE=1 adds the MySQL reclaimable space case, about 1 GB of writes.
#
# Passwords come from PGPASSWORD and MYSQL_PWD. Needs psql or mysql on PATH, and a user that may
# create and drop a database; on PostgreSQL also a role, for the unreadable sequence case. Exits non-zero
# on a disagreement, 3 when it cannot run. MySQL also takes a user, for the PROCESS refusal. Every
# PostgreSQL query also runs while another session holds ACCESS EXCLUSIVE on a table it lists and on one
# it does not, and must answer without waiting. PostgreSQL takes about a minute: the invalid index and
# transaction ID cases wait on held snapshots.

set -uo pipefail

ENGINE="${1:-}"
HOST="${2:-127.0.0.1}"
PORT="${3:-}"
USER_NAME="${4:-}"
SOURCES="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/TablePro/Core/TableHealth"
DATABASE="tablepro_health_check"
OTHER_DATABASE="tablepro_health_other"
READER_ROLE="tablepro_health_reader"
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

expect_pattern() {
    local label="$1" output="$2" pattern="$3"
    if grep -qE -- "$pattern" <<< "$output"; then
        echo "ok    $label"
    else
        echo "FAIL  $label: expected a match for '$pattern'" >&2
        FAILURES=$((FAILURES + 1))
    fi
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
    trap cleanup_postgres EXIT

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
    PGAPPNAME=tablepro_health_temp psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" \
        -c "CREATE TEMP TABLE probe_temp (v int)" -c "CREATE INDEX probe_temp_idx ON probe_temp (v)" \
        -c "CREATE TEMP SEQUENCE probe_temp_seq MAXVALUE 100" -c "SELECT setval('probe_temp_seq', 90)" -c "SELECT pg_sleep(30)" \
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

    local shape
    shape="$(pg -d "$DATABASE" -c "$(query_of "$source" redundantIndexQuery)")"
    expect "index shape skips another session's temporary table" "$shape" "probe_temp_idx" no
    expect "index shape reads a primary key as protected" "$shape" "public|parent|r|parent_pkey|btree|t|t|t|false|t|" yes
    if [ "$version" -ge 100000 ]; then
        local sequences
        sequences="$(pg -d "$DATABASE" -c "$(query_of "$source" nearLimitQuery)")"
        expect "sequences skip another session's temporary sequence without reading it" "$sequences" "probe_temp_seq" no
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

    terminate tablepro_health_temp
    kill "$holder" 2> /dev/null
    wait "$holder" 2> /dev/null

    check_postgres_extension_members
    check_postgres_redundant_indexes
    check_postgres_invalid_indexes
    if [ "$version" -ge 100000 ]; then
        check_postgres_sequences
    else
        echo "note  PostgreSQL $version has no pg_sequence, so the sequence check is skipped there"
    fi
    check_postgres_stale_statistics
    check_postgres_transaction_id_age
    check_postgres_locks
    check_postgres_standbys
}

# Every query must answer while another session holds ACCESS EXCLUSIVE on a table: a size or a definition read
# from the relation itself would wait until that transaction ends. An open TRUNCATE locks the table, its TOAST
# table and every index; an open ALTER SEQUENCE blocks reading the sequence. lock_timeout in the probe's own
# session turns a wait into an error.
check_postgres_locks() {
    pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE lk_other (id int PRIMARY KEY);
INSERT INTO lk_other SELECT g FROM generate_series(1, 10) g;
CREATE TABLE lk_listed (id serial PRIMARY KEY, v int, w int, note text);
INSERT INTO lk_listed (v, w, note) SELECT g % 3, g, repeat('x', 3000) FROM generate_series(1, 10) g;
CREATE INDEX lk_listed_v_idx ON lk_listed (v);
CREATE INDEX lk_listed_vw_idx ON lk_listed (v, w);
SELECT setval('lk_listed_id_seq', 1700000000);
CREATE TABLE lk_nopk (v int);
CREATE TABLE lk_parent (id int PRIMARY KEY);
CREATE TABLE lk_child (id int PRIMARY KEY, parent_id int REFERENCES lk_parent (id));
CREATE TABLE lk_bloat (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = false);
INSERT INTO lk_bloat SELECT g, g FROM generate_series(1, 5000) g;
DELETE FROM lk_bloat WHERE id <= 3000;
SQL
    pg -d "$DATABASE" -c "CREATE UNIQUE INDEX CONCURRENTLY lk_listed_v_uniq ON lk_listed (v)" > /dev/null 2>&1
    for _ in $(seq 1 10); do
        [ "$(pg -d "$DATABASE" -c "SELECT count(*) FROM pg_stat_user_tables WHERE relname IN ('lk_bloat', 'lk_listed') AND n_live_tup > 0")" = "2" ] && break
        sleep 1
    done

    local invalid=invalidIndexBefore12Query
    [ "$version" -ge 120000 ] && invalid=invalidIndexQuery
    # Query, then what it must still list while lk_listed and its neighbours are locked.
    local cases=(
        "statisticsQuery|"
        "bloatQuery||lk_bloat|"
        "unusedIndexQuery|lk_listed_v_idx"
        "redundantIndexQuery||lk_listed|r|lk_listed_v_idx|"
        "$invalid|public|lk_listed|lk_listed_v_uniq|t|f|"
        "missingPrimaryKeyQuery|public|lk_nopk"
        "unindexedForeignKeyQuery|lk_child_parent_id_fkey"
        "staleStatisticsQuery|public|lk_listed|r|"
        "transactionIdAgeQuery|"
    )
    [ "$version" -ge 100000 ] && cases+=("nearLimitQuery|")

    # A table never vacuumed or analyzed has no pages recorded, so no size rather than 0.
    local output
    output="$(pg -d "$DATABASE" -c "$(query_of "$source" missingPrimaryKeyQuery)")"
    expect_pattern "a table with no pages recorded has no size" "$output" "^public\|lk_nopk\|0\|$"

    local entry query listed
    # $1 says which lock is held; with $2 = listed, each query must still list what the lock covers.
    run_lock_cases() {
        for entry in "${cases[@]}"; do
            query="${entry%%|*}"
            listed="${entry#*|}"
            output="$(pg -d "$DATABASE" -c "SET lock_timeout = '5s'" -c "$(query_of "$source" "$query")" 2>&1)"
            expect "$query answers while $1" "$output" "lock timeout" no
            if [ "$2" = listed ] && [ -n "$listed" ]; then
                expect "$query still lists the locked table while $1" "$output" "$listed" yes
            fi
        done
        [ "$2" = listed ] || return
        output="$(pg -d "$DATABASE" -c "SET lock_timeout = '5s'" -c "$(query_of "$source" "$invalid")" 2>&1)"
        expect_pattern "an invalid index comes back without the definition that would wait while $1" "$output" \
            "lk_listed_v_uniq\|t\|f\|[0-9]*\|$"
        if [ "$version" -ge 100000 ]; then
            output="$(pg -d "$DATABASE" -c "SET lock_timeout = '5s'" -c "$(query_of "$source" nearLimitQuery)" 2>&1)"
            expect "a sequence comes back unread and marked locked while $1" "$output" \
                "public|lk_listed_id_seq|integer|1|1|2147483647||1|2147483647||t|t|" yes
        fi
    }

    hold_lock tablepro_health_other_lock "LOCK TABLE lk_other IN ACCESS EXCLUSIVE MODE"
    run_lock_cases "a table it does not list is locked" unlisted
    terminate tablepro_health_other_lock

    local sequence_lock=""
    [ "$version" -ge 100000 ] && sequence_lock="; ALTER SEQUENCE lk_listed_id_seq MAXVALUE 2147483647"
    hold_lock tablepro_health_listed_lock "TRUNCATE lk_listed, lk_nopk, lk_child, lk_bloat$sequence_lock"
    run_lock_cases "an open transaction locks the tables it lists, their indexes and TOAST tables" listed
    terminate tablepro_health_listed_lock

    # A prepared transaction keeps its locks with no backend, so pg_locks shows them with a NULL pid.
    if [ "$(pg -d "$DATABASE" -c "SHOW max_prepared_transactions")" -gt 0 ]; then
        local prepared=(-c "BEGIN" -c "TRUNCATE lk_listed, lk_nopk, lk_child, lk_bloat")
        [ "$version" -ge 100000 ] && prepared+=(-c "ALTER SEQUENCE lk_listed_id_seq MAXVALUE 2147483647")
        pg -d "$DATABASE" "${prepared[@]}" -c "PREPARE TRANSACTION 'tablepro_health_lock'" > /dev/null
        run_lock_cases "a prepared transaction locks the tables it lists" listed
        pg -d "$DATABASE" -c "ROLLBACK PREPARED 'tablepro_health_lock'" > /dev/null
    else
        echo "note  max_prepared_transactions is 0, so the prepared transaction lock case is skipped"
    fi
}

# Only a physical standby runs queries whose index scans this server does not count: a logical walsender feeds a
# subscriber or a CDC reader, and a base backup runs no queries.
check_postgres_standbys() {
    local stats appeared=0
    PGAPPNAME=tablepro_health_logical psql -X -q "host=$HOST port=$PORT user=$USER_NAME dbname=$DATABASE replication=database" \
        -c "SELECT pg_sleep(30)" > /dev/null 2>&1 &
    for _ in $(seq 1 20); do
        [ "$(pg -d postgres -c "SELECT count(*) FROM pg_stat_replication WHERE application_name = 'tablepro_health_logical'")" = "1" ] \
            && { appeared=1; break; }
        sleep 0.25
    done
    if [ "$appeared" = 1 ]; then
        stats="$(pg -d "$DATABASE" -c "$(query_of "$source" statisticsQuery)")"
        expect_pattern "a logical walsender is not counted as a standby" "$stats" "\|0$"
    else
        echo "note  no logical walsender appeared, so that standby case is skipped"
    fi
    terminate tablepro_health_logical

    command -v pg_receivewal > /dev/null || { echo "note  pg_receivewal not found, so the physical standby case is skipped"; return; }
    local wal receiver
    wal="$(mktemp -d)"
    PGAPPNAME=tablepro_health_physical pg_receivewal -h "$HOST" -p "$PORT" -U "$USER_NAME" -D "$wal" --no-sync > /dev/null 2>&1 &
    receiver=$!
    appeared=0
    for _ in $(seq 1 20); do
        [ "$(pg -d postgres -c "SELECT count(*) FROM pg_stat_replication WHERE application_name = 'tablepro_health_physical'")" = "1" ] \
            && { appeared=1; break; }
        sleep 0.25
    done
    if [ "$appeared" = 1 ]; then
        stats="$(pg -d "$DATABASE" -c "$(query_of "$source" statisticsQuery)")"
        expect_pattern "a physical walsender is counted as a standby" "$stats" "\|1$"
    else
        echo "note  pg_receivewal could not stream (a replication line in pg_hba.conf is needed), so the physical standby case is skipped"
    fi
    kill "$receiver" 2> /dev/null
    wait "$receiver" 2> /dev/null
    rm -rf "$wal"
}

cleanup_postgres() {
    local admin=(psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres)
    # A prepared transaction left by an interrupted run would block the drop; it ends only from its own database.
    psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" \
        -c "ROLLBACK PREPARED 'tablepro_health_lock'" > /dev/null 2>&1
    "${admin[@]}" -c "SELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity WHERE datname = '$DATABASE' AND pid <> pg_catalog.pg_backend_pid()" > /dev/null 2>&1
    "${admin[@]}" -c "DROP DATABASE IF EXISTS $DATABASE" > /dev/null 2>&1
    "${admin[@]}" -c "DROP ROLE IF EXISTS $READER_ROLE" > /dev/null 2>&1
}

# Ends the sessions a background psql opened under this application name. Killing psql alone leaves the
# server running the statement, and the snapshot it holds, until the statement ends.
terminate() {
    pg -d postgres -c "SELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity WHERE application_name = '$1'" > /dev/null
}

# Runs $2 in a background transaction under application name $1 and holds its locks until terminated, once the
# server shows one of them granted.
hold_lock() {
    PGAPPNAME="$1" psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" \
        -c "BEGIN; $2; SELECT pg_sleep(120); COMMIT;" > /dev/null 2>&1 &
    for _ in $(seq 1 20); do
        [ "$(pg -d postgres -c "SELECT count(*) > 0 FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid WHERE a.application_name = '$1' AND l.mode = 'AccessExclusiveLock' AND l.granted")" = "t" ] && return
        sleep 0.25
    done
    echo "note  the locks held as $1 did not appear" >&2
}

# Holds a REPEATABLE READ snapshot in the background under application name $1 for $2 seconds, and waits
# until the server shows it.
hold_snapshot() {
    PGAPPNAME="$1" psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" \
        -c "BEGIN ISOLATION LEVEL REPEATABLE READ; SELECT 1; SELECT pg_sleep($2); COMMIT;" > /dev/null 2>&1 &
    for _ in $(seq 1 20); do
        [ "$(pg -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$1' AND backend_xmin IS NOT NULL")" = "1" ] && return
        sleep 0.25
    done
    echo "note  the snapshot held as $1 did not appear" >&2
}

# An extension's own table, and a table in an extension's schema the way TimescaleDB keeps its chunks, each
# with what every check would list: no primary key, a duplicate index, rows never analyzed, a low freeze age.
check_postgres_extension_members() {
    if ! pg -d "$DATABASE" -c "CREATE EXTENSION IF NOT EXISTS btree_gist" > /dev/null 2>&1; then
        echo "note  btree_gist is not available, so the extension member cases are skipped"
        return
    fi
    pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE ext_owned (a int) WITH (autovacuum_enabled = false, autovacuum_freeze_max_age = 100000);
CREATE INDEX ext_owned_a1 ON ext_owned (a);
CREATE INDEX ext_owned_a2 ON ext_owned (a);
INSERT INTO ext_owned SELECT g FROM generate_series(1, 100) g;
ALTER EXTENSION btree_gist ADD TABLE ext_owned;
CREATE SCHEMA ext_schema;
ALTER EXTENSION btree_gist ADD SCHEMA ext_schema;
CREATE TABLE ext_schema.chunk (a int) WITH (autovacuum_enabled = false, autovacuum_freeze_max_age = 100000);
CREATE INDEX chunk_a1 ON ext_schema.chunk (a);
CREATE INDEX chunk_a2 ON ext_schema.chunk (a);
INSERT INTO ext_schema.chunk SELECT g FROM generate_series(1, 100) g;
SQL
    local query output
    for query in bloatQuery unusedIndexQuery redundantIndexQuery missingPrimaryKeyQuery unindexedForeignKeyQuery \
        invalidIndexQuery invalidIndexBefore12Query staleStatisticsQuery transactionIdAgeQuery; do
        output="$(pg -d "$DATABASE" -c "$(query_of "$source" "$query")")"
        expect "$query skips an extension's table" "$output" "ext_owned" no
        expect "$query skips a table in an extension's schema" "$output" "ext_schema" no
    done
    if [ "$version" -ge 100000 ]; then
        pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE SEQUENCE ext_owned_seq AS smallint;
SELECT setval('ext_owned_seq', 32000);
ALTER EXTENSION btree_gist ADD SEQUENCE ext_owned_seq;
CREATE SEQUENCE ext_schema.chunk_seq AS smallint;
SELECT setval('ext_schema.chunk_seq', 32000);
SQL
        output="$(pg -d "$DATABASE" -c "$(query_of "$source" nearLimitQuery)")"
        expect "nearLimitQuery skips an extension's sequence" "$output" "ext_owned_seq" no
        expect "nearLimitQuery skips a sequence in an extension's schema" "$output" "ext_schema" no
    fi
}

check_postgres_redundant_indexes() {
    pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE ri (id int PRIMARY KEY, a int, b int, c int, email text, code text, note text);
CREATE INDEX r_a ON ri (a);
CREATE INDEX k_ab ON ri (a, b);
CREATE INDEX r_ab_dup ON ri (a, b);
CREATE INDEX k_a_desc ON ri (a DESC);
CREATE INDEX k_ba ON ri (b, a);
CREATE INDEX k_a_partial ON ri (a) WHERE a > 0;
CREATE INDEX k_a_partial_twin_b ON ri (a, b) WHERE a > 0;
CREATE INDEX r_a_partial_dup ON ri (a) WHERE a > 0;
CREATE INDEX k_lower_email ON ri (lower(email));
CREATE INDEX r_lower_email_dup ON ri (lower(email));
CREATE INDEX k_upper_email ON ri (upper(email));
CREATE INDEX k_code_pattern ON ri (code text_pattern_ops);
CREATE INDEX k_code ON ri (code);
CREATE INDEX k_code_c ON ri (code COLLATE "C");
CREATE INDEX k_hash_a ON ri USING hash (a);
CREATE UNIQUE INDEX k_uniq_c ON ri (c);
CREATE INDEX k_cb ON ri (c, b);
CREATE INDEX r_c_plain ON ri (c);
CREATE UNIQUE INDEX r_id_uniq ON ri (id);
CREATE INDEX k_note_gin ON ri USING gin (to_tsvector('simple', note));
CREATE INDEX k_note_gin_2 ON ri USING gin (to_tsvector('english', note));
CREATE TABLE rc (id int PRIMARY KEY, x int, CONSTRAINT k_rc_x_key UNIQUE (x));
CREATE UNIQUE INDEX r_rc_x_uidx ON rc (x);
CREATE INDEX r_rc_x_plain ON rc (x);
CREATE TABLE rk (id int PRIMARY KEY, z int);
CREATE UNIQUE INDEX k_rk_z_fkref ON rk (z);
CREATE UNIQUE INDEX r_rk_z_twin ON rk (z);
CREATE TABLE rk_child (id int PRIMARY KEY, z int REFERENCES rk (z));
CREATE TABLE rd (id int PRIMARY KEY, v int, CONSTRAINT k_rd_v_deferrable UNIQUE (v) DEFERRABLE INITIALLY DEFERRED);
CREATE UNIQUE INDEX k_rd_v_immediate ON rd (v);
CREATE TABLE rr (id int PRIMARY KEY, k int NOT NULL);
CREATE UNIQUE INDEX rr_zz_replident ON rr (k);
ALTER TABLE rr REPLICA IDENTITY USING INDEX rr_zz_replident;
CREATE UNIQUE INDEX rr_aa_twin ON rr (k);
CREATE MATERIALIZED VIEW rmv AS SELECT g AS a, g AS b FROM generate_series(1, 10) g;
CREATE INDEX k_rmv_ab ON rmv (a, b);
CREATE INDEX r_rmv_a ON rmv (a);
SQL
    if [ "$version" -ge 110000 ]; then
        pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE ri_incl (id int PRIMARY KEY, a int, b int, c int);
CREATE INDEX k_a_incl_c ON ri_incl (a) INCLUDE (c);
CREATE INDEX k_ab2 ON ri_incl (a, b);
CREATE INDEX k_abc_incl ON ri_incl (a, b) INCLUDE (c);
CREATE INDEX r_a_only ON ri_incl (a);
CREATE TABLE rp (id int, at date, k int) PARTITION BY RANGE (at);
CREATE TABLE rp_2026 PARTITION OF rp FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE INDEX k_rp_k_at ON rp (k, at);
CREATE INDEX r_rp_k ON rp (k);
CREATE INDEX r_rp_2026_k_standalone ON rp_2026 (k);
SQL
    fi
    if [ "$version" -ge 150000 ]; then
        pg -d "$DATABASE" -c "CREATE UNIQUE INDEX k_nd ON ri (b)" -c "CREATE UNIQUE INDEX k_nnd ON ri (b) NULLS NOT DISTINCT" \
            -c "CREATE INDEX r_b_plain ON ri (b)" > /dev/null
    fi
    if pg -d "$DATABASE" -c "CREATE EXTENSION IF NOT EXISTS btree_gist" > /dev/null 2>&1; then
        pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE rx (id int PRIMARY KEY, room int, during tsrange, EXCLUDE USING gist (room WITH =, during WITH &&));
CREATE INDEX k_rx_room_gist ON rx USING gist (room);
SQL
    fi

    local shape
    shape="$(pg -d "$DATABASE" -c "$(query_of "$source" redundantIndexQuery)")"
    expect "index shape reads a unique constraint's index as protected" "$shape" "public|rc|r|k_rc_x_key|btree|t|f|t|false|t|" yes
    expect "index shape reads a plain unique index as unprotected" "$shape" "public|rc|r|r_rc_x_uidx|btree|t|f|t|false|f|" yes
    expect "index shape reads an index a foreign key uses as protected" "$shape" "public|rk|r|k_rk_z_fkref|btree|t|f|t|false|t|" yes
    expect "index shape reads a deferrable constraint as not immediate" "$shape" "public|rd|r|k_rd_v_deferrable|btree|t|f|f|false|t|" yes
    expect "index shape reads the replica identity index as protected" "$shape" "public|rr|r|rr_zz_replident|btree|t|f|t|false|t|" yes
    expect "index shape reads a predicate as node text" "$shape" "public|ri|r|r_a_partial_dup|btree|f|f|t|false|f|{OPEXPR :opno 521 " yes
    expect "index shape reads an expression key as node text in its index's list" "$shape" "|k_lower_email|btree|f|f|t|false|f||({FUNCEXPR :funcid 870 " yes
    expect "index shape gives an expression key attnum 0 and no column" "$shape" "|1|1|0||3126|100|0" yes
    expect "index shape drops the :location offsets that differ with where a statement wrote an expression" "$shape" ":location" no
    expect "index shape reads a descending key's column and sort flags" "$shape" "|1|1|2|a|1978|0|3" yes
    expect "index shape reads a materialized view's index" "$shape" "public|rmv|m|r_rmv_a|btree|" yes
    expect "index shape reads a GIN index's method" "$shape" "public|ri|r|k_note_gin|gin|" yes
    if [ "$version" -ge 110000 ]; then
        expect "index shape reads an INCLUDE column after the key count" "$shape" "k_a_incl_c|btree|f|f|t|false|f|||8192|1|2|4|c|||" yes
        expect "index shape reads an attached partition index as protected" "$shape" "public|rp_2026|r|rp_2026_k_at_idx|btree|f|f|t|false|t|" yes
        expect "index shape reads a partitioned table's index, which has no pages and so no size" "$shape" "public|rp|p|r_rp_k|btree|f|f|t|false|f||||1|1|" yes
    fi
    if [ "$version" -ge 150000 ]; then
        expect "index shape reads NULLS NOT DISTINCT" "$shape" "public|ri|r|k_nnd|btree|t|f|t|true|f|" yes
    fi

    # The fixes exactly as PostgreSQLIndexShapeTests pins them, and the refusals that make the protected set.
    local refused
    for index in r_a r_ab_dup r_lower_email_dup r_c_plain r_id_uniq r_rc_x_uidx r_rk_z_twin rr_aa_twin r_rmv_a; do
        pg -d "$DATABASE" -c "DROP INDEX CONCURRENTLY \"public\".\"$index\";" > /dev/null
    done
    refused="$(pg -d "$DATABASE" -c 'DROP INDEX CONCURRENTLY "public"."k_rc_x_key";' 2>&1)"
    expect "a unique constraint's index cannot be dropped alone" "$refused" "requires it" yes
    refused="$(pg -d "$DATABASE" -c 'DROP INDEX CONCURRENTLY "public"."k_rk_z_fkref";' 2>&1)"
    expect "an index a foreign key uses cannot be dropped alone" "$refused" "depend on it" yes
    if [ "$version" -ge 110000 ]; then
        refused="$(pg -d "$DATABASE" -c 'DROP INDEX CONCURRENTLY "public"."r_rp_k";' 2>&1)"
        expect "a partitioned table's index cannot be dropped concurrently" "$refused" "concurrently" yes
        refused="$(pg -d "$DATABASE" -c 'DROP INDEX CONCURRENTLY "public"."rp_2026_k_at_idx";' 2>&1)"
        expect "an attached partition index cannot be dropped alone" "$refused" "requires it" yes
        pg -d "$DATABASE" -c 'DROP INDEX "public"."r_rp_k";' > /dev/null
        pg -d "$DATABASE" -c 'DROP INDEX CONCURRENTLY "public"."r_rp_2026_k_standalone";' > /dev/null
    fi
    shape="$(pg -d "$DATABASE" -c "$(query_of "$source" redundantIndexQuery)")"
    expect "the previewed drops clear their findings" "$shape" "|r_ab_dup|" no
    expect "the previewed drop on a materialized view clears its finding" "$shape" "|r_rmv_a|" no
    if [ "$version" -ge 110000 ]; then
        expect "the previewed plain drop clears a partitioned table's finding" "$shape" "|r_rp_k|" no
    fi
}

check_postgres_invalid_indexes() {
    # The provider picks its literal by version: only 12+ has pg_stat_progress_create_index.
    local query=invalidIndexBefore12Query
    [ "$version" -ge 120000 ] && query=invalidIndexQuery
    pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE inv (id int PRIMARY KEY, v int, w int);
INSERT INTO inv SELECT g, g % 10, g FROM generate_series(1, 1000) g;
CREATE INDEX inv_w_idx ON inv (w);
SQL
    local failed
    failed="$(pg -d "$DATABASE" -c "CREATE UNIQUE INDEX CONCURRENTLY inv_v_uniq ON inv (v)" 2>&1)"
    expect "a unique concurrent build over duplicates fails" "$failed" "could not create unique index" yes

    # A concurrent build waits for older snapshots; cancelled while it waits, it leaves its index invalid.
    hold_snapshot tablepro_health_invalid 5
    pg -d "$DATABASE" -c "SET statement_timeout = '1500ms'" -c "CREATE INDEX CONCURRENTLY inv_vw_cancelled ON inv (v, w)" > /dev/null 2>&1
    if [ "$version" -ge 120000 ]; then
        pg -d "$DATABASE" -c "SET statement_timeout = '1500ms'" -c "REINDEX INDEX CONCURRENTLY inv_w_idx" > /dev/null 2>&1
    fi
    terminate tablepro_health_invalid
    if [ "$version" -ge 110000 ]; then
        pg -d "$DATABASE" -c "CREATE INDEX rp_id_only ON ONLY rp (id)" > /dev/null
    fi

    # While a build runs, its table holds SHARE UPDATE EXCLUSIVE and every invalid index on it is left out.
    hold_snapshot tablepro_health_building 4
    PGAPPNAME=tablepro_health_builder psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" \
        -c "CREATE INDEX CONCURRENTLY inv_building ON inv (w, v)" > /dev/null 2>&1 &
    local builder=$!
    for _ in $(seq 1 20); do
        [ "$(pg -d "$DATABASE" -c "SELECT count(*) FROM pg_locks WHERE relation = 'inv'::regclass AND mode = 'ShareUpdateExclusiveLock' AND granted")" = "1" ] && break
        sleep 0.25
    done
    local invalid
    invalid="$(pg -d "$DATABASE" -c "$(query_of "$source" "$query")")"
    expect "invalid indexes leave out a table with a build running" "$invalid" "|inv|" no
    local unused
    unused="$(pg -d "$DATABASE" -c "$(query_of "$source" unusedIndexQuery)")"
    expect "unused indexes skip an index still being built" "$unused" "inv_building" no
    wait "$builder"

    invalid="$(pg -d "$DATABASE" -c "$(query_of "$source" "$query")")"
    expect "invalid indexes list a failed unique build, never ready" "$invalid" "public|inv|inv_v_uniq|t|f|" yes
    expect "invalid indexes list a cancelled build, still updated by writes" "$invalid" "public|inv|inv_vw_cancelled|f|t|" yes
    expect "invalid indexes skip a build that finished" "$invalid" "inv_building" no
    if [ "$version" -ge 120000 ]; then
        expect "invalid indexes list a cancelled REINDEX CONCURRENTLY's new copy" "$invalid" "public|inv|inv_w_idx_ccnew|f|" yes
    fi
    if [ "$version" -ge 110000 ]; then
        expect "invalid indexes skip an index built ON ONLY a partitioned table" "$invalid" "rp_id_only" no
    fi
    local shape
    shape="$(pg -d "$DATABASE" -c "$(query_of "$source" redundantIndexQuery)")"
    expect "index shape skips an invalid index" "$shape" "inv_vw_cancelled" no
    unused="$(pg -d "$DATABASE" -c "$(query_of "$source" unusedIndexQuery)")"
    expect "unused indexes skip an invalid index, which the invalid index check owns" "$unused" "inv_vw_cancelled" no

    # Autovacuum and ANALYZE take the lock a build holds. From 12 on, only a build hides its table's leftovers.
    if [ "$version" -ge 120000 ]; then
        PGAPPNAME=tablepro_health_lock psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DATABASE" \
            -c "BEGIN; LOCK TABLE inv IN SHARE UPDATE EXCLUSIVE MODE; SELECT pg_sleep(30); COMMIT;" > /dev/null 2>&1 &
        local locker=$!
        for _ in $(seq 1 20); do
            [ "$(pg -d "$DATABASE" -c "SELECT count(*) FROM pg_locks WHERE relation = 'inv'::regclass AND mode = 'ShareUpdateExclusiveLock' AND granted")" = "1" ] && break
            sleep 0.25
        done
        invalid="$(pg -d "$DATABASE" -c "$(query_of "$source" invalidIndexQuery)")"
        expect "invalid indexes stay listed while something other than a build holds the table's lock" "$invalid" "public|inv|inv_vw_cancelled|" yes
        invalid="$(pg -d "$DATABASE" -c "$(query_of "$source" invalidIndexBefore12Query)")"
        expect "before 12 the same lock hides them, which is why that query is kept for old servers only" "$invalid" "|inv|" no
        terminate tablepro_health_lock
        wait "$locker" 2> /dev/null
    fi

    # The fixes exactly as PostgreSQLTableHealthProviderTests pins them.
    if [ "$version" -ge 120000 ]; then
        pg -d "$DATABASE" -c 'REINDEX INDEX CONCURRENTLY "public"."inv_vw_cancelled";' > /dev/null
        pg -d "$DATABASE" -c 'DROP INDEX CONCURRENTLY "public"."inv_w_idx_ccnew";' > /dev/null
        failed="$(pg -d "$DATABASE" -c 'REINDEX INDEX CONCURRENTLY "public"."inv_v_uniq";' 2>&1)"
        expect "rebuilding a unique index fails while duplicates remain, as its detail says" "$failed" "could not create unique index" yes
    else
        pg -d "$DATABASE" -c 'DROP INDEX CONCURRENTLY "public"."inv_vw_cancelled";' > /dev/null
        pg -d "$DATABASE" -c 'CREATE INDEX CONCURRENTLY inv_vw_cancelled ON public.inv USING btree (v, w);' > /dev/null
    fi
    invalid="$(pg -d "$DATABASE" -c "$(query_of "$source" "$query")")"
    expect "the previewed rebuild clears its finding" "$invalid" "|inv_vw_cancelled|" no
    expect "the previewed drop of a leftover copy clears its finding" "$invalid" "|inv_w_idx_ccnew|" no
}

check_postgres_sequences() {
    pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE seq_int (id serial PRIMARY KEY, v int);
CREATE TABLE seq_int_child (id int PRIMARY KEY, seq_int_id int REFERENCES seq_int (id));
CREATE TABLE seq_identity (id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, v int);
CREATE TABLE seq_small (id smallserial PRIMARY KEY);
CREATE TABLE seq_bigcol_intseq (id bigint PRIMARY KEY);
CREATE SEQUENCE seq_int_typed AS integer;
ALTER TABLE seq_bigcol_intseq ALTER COLUMN id SET DEFAULT nextval('seq_int_typed');
CREATE TABLE seq_intcol_bigseq (id int PRIMARY KEY);
CREATE SEQUENCE seq_big_for_int;
ALTER TABLE seq_intcol_bigseq ALTER COLUMN id SET DEFAULT nextval('seq_big_for_int');
CREATE TABLE seq_healthy (id serial PRIMARY KEY);
CREATE SEQUENCE seq_standalone_small AS smallint;
CREATE SEQUENCE seq_never_used AS integer;
CREATE SEQUENCE seq_cycle AS smallint CYCLE;
CREATE TABLE seq_desc (id int PRIMARY KEY);
CREATE SEQUENCE seq_desc_s AS integer INCREMENT BY -1;
ALTER TABLE seq_desc ALTER COLUMN id SET DEFAULT nextval('seq_desc_s');
CREATE SEQUENCE seq_explicit AS integer MAXVALUE 1000;
CREATE SEQUENCE seq_secret AS smallint;
SELECT setval('seq_int_id_seq', 1700000000);
SELECT setval('seq_identity_id_seq', 1800000000);
SELECT setval('seq_small_id_seq', 30000);
SELECT setval('seq_int_typed', 2000000000);
SELECT setval('seq_big_for_int', 1700000000);
SELECT nextval('seq_healthy_id_seq');
SELECT setval('seq_standalone_small', 30000);
SELECT setval('seq_cycle', 32000);
SELECT setval('seq_desc_s', -1700000000);
SELECT setval('seq_explicit', 900);
SELECT setval('seq_secret', 32000);
SQL
    local sequences
    sequences="$(pg -d "$DATABASE" -c "$(query_of "$source" nearLimitQuery)")"
    expect "a serial column near its limit, bounded by the column" "$sequences" "public|seq_int_id_seq|integer|1|1|2147483647|1700000000|1|2147483647|" yes
    expect "a serial column names its table, column, type limits and ownership" "$sequences" "|public|seq_int|id|integer|-2147483648|2147483647|owned|" yes
    expect "a serial column names the foreign key column that stays narrow" "$sequences" "|public.seq_int_child.seq_int_id" yes
    expect "an identity column" "$sequences" "|public|seq_identity|id|integer|-2147483648|2147483647|identity|" yes
    expect "a smallserial column" "$sequences" "public|seq_small_id_seq|smallint|1|1|32767|30000|1|32767|" yes
    expect "a bigint sequence is bounded by the integer column it feeds" "$sequences" "public|seq_big_for_int|bigint|1|1|9223372036854775807|1700000000|1|2147483647|" yes
    expect "an integer sequence feeding a bigint column" "$sequences" "|public|seq_bigcol_intseq|id|bigint|||default|" yes
    expect "a sequence no column uses" "$sequences" "public|seq_standalone_small|smallint|1|1|32767|30000|1|32767|" yes
    expect "a descending sequence, bounded below" "$sequences" "public|seq_desc_s|integer|-1|-2147483648|-1|-1700000000|-2147483648|-1|" yes
    expect "a sequence with its own lower maximum" "$sequences" "public|seq_explicit|integer|1|1|1000|900|1|1000|" yes
    expect "sequences skip a cycling sequence" "$sequences" "seq_cycle" no
    expect "sequences skip a sequence never used" "$sequences" "seq_never_used" no
    expect "sequences skip a sequence far from its limit" "$sequences" "seq_healthy" no

    pg -d postgres -c "DROP ROLE IF EXISTS $READER_ROLE" > /dev/null 2>&1
    if pg -d "$DATABASE" -c "CREATE ROLE $READER_ROLE" > /dev/null 2>&1 \
        && pg -d "$DATABASE" -c "SET ROLE $READER_ROLE" > /dev/null 2>&1; then
        pg -d "$DATABASE" -c "GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO $READER_ROLE" \
            -c "REVOKE ALL ON SEQUENCE seq_secret FROM $READER_ROLE" > /dev/null
        local unreadable
        unreadable="$(pg -d "$DATABASE" -c "SET ROLE $READER_ROLE" -c "$(query_of "$source" nearLimitQuery)")"
        expect "a sequence the user cannot read comes back unread, for the check's note" "$unreadable" "public|seq_secret|smallint|1|1|32767||1|32767||f|" yes
        expect "a sequence the user can read still reads" "$unreadable" "public|seq_small_id_seq|smallint|1|1|32767|30000|" yes
    else
        echo "note  this user cannot create a role and take it on, so the unreadable sequence case is skipped"
    fi

    # The fixes exactly as PostgreSQLTableHealthProviderTests pins them.
    pg -d "$DATABASE" > /dev/null <<'SQL'
ALTER TABLE "public"."seq_int" ALTER COLUMN "id" TYPE bigint;
ALTER SEQUENCE "public"."seq_int_id_seq" AS bigint;
ALTER TABLE "public"."seq_identity" ALTER COLUMN "id" TYPE bigint;
ALTER TABLE "public"."seq_small" ALTER COLUMN "id" TYPE bigint;
ALTER SEQUENCE "public"."seq_small_id_seq" AS bigint;
ALTER TABLE "public"."seq_intcol_bigseq" ALTER COLUMN "id" TYPE bigint;
ALTER SEQUENCE "public"."seq_int_typed" AS bigint;
ALTER SEQUENCE "public"."seq_standalone_small" AS bigint;
ALTER TABLE "public"."seq_desc" ALTER COLUMN "id" TYPE bigint;
ALTER SEQUENCE "public"."seq_desc_s" AS bigint;
ALTER SEQUENCE "public"."seq_explicit" AS bigint NO MAXVALUE;
ALTER SEQUENCE "public"."seq_secret" AS bigint;
SQL
    sequences="$(pg -d "$DATABASE" -c "$(query_of "$source" nearLimitQuery)")"
    expect "the previewed fixes clear every sequence finding" "$sequences" "seq_" no
}

check_postgres_stale_statistics() {
    # Insert, analyze and update in separate sessions: inside one session the server counts the rows twice.
    pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE st_never (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = false);
CREATE TABLE st_stale (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = false);
CREATE TABLE st_fresh (id int PRIMARY KEY, v int) WITH (autovacuum_enabled = false);
CREATE TABLE st_empty (id int PRIMARY KEY) WITH (autovacuum_enabled = false);
SQL
    if [ "$version" -ge 100000 ]; then
        pg -d "$DATABASE" -c "CREATE TABLE st_part (id int, at date) PARTITION BY RANGE (at)" \
            -c "CREATE TABLE st_part_2026 PARTITION OF st_part FOR VALUES FROM ('2026-01-01') TO ('2027-01-01') WITH (autovacuum_enabled = false)" \
            > /dev/null
        pg -d "$DATABASE" -c "INSERT INTO st_part SELECT g, '2026-03-01' FROM generate_series(1, 5000) g" > /dev/null
    fi
    pg -d "$DATABASE" -c "INSERT INTO st_never SELECT g, g FROM generate_series(1, 5000) g" \
        -c "INSERT INTO st_stale SELECT g, g FROM generate_series(1, 5000) g" \
        -c "INSERT INTO st_fresh SELECT g, g FROM generate_series(1, 5000) g" > /dev/null
    pg -d "$DATABASE" -c "ANALYZE st_stale" -c "ANALYZE st_fresh" > /dev/null
    pg -d "$DATABASE" -c "UPDATE st_stale SET v = v + 1 WHERE id <= 1000" -c "UPDATE st_fresh SET v = v + 1 WHERE id <= 100" > /dev/null

    local stale=""
    for _ in $(seq 1 10); do
        stale="$(pg -d "$DATABASE" -c "$(query_of "$source" staleStatisticsQuery)")"
        grep -qF "|st_stale|" <<< "$stale" && grep -qF "|st_never|" <<< "$stale" && break
        sleep 1
    done
    expect "stale statistics list a table never analyzed" "$stale" "public|st_never|r|5000|5000|50|t|" yes
    expect "stale statistics list a table modified past 10% plus 50 rows" "$stale" "public|st_stale|r|5000|1000|550|f|" yes
    expect "stale statistics skip a table modified less" "$stale" "st_fresh" no
    expect "stale statistics skip an empty table" "$stale" "st_empty" no
    if [ "$version" -ge 100000 ]; then
        expect "stale statistics list a partitioned table no one analyzed" "$stale" "public|st_part|p|0|0|50|t|" yes
    fi

    # The fixes exactly as PostgreSQLTableHealthProviderTests pins them.
    pg -d "$DATABASE" -c 'ANALYZE "public"."st_never";' -c 'ANALYZE "public"."st_stale";' > /dev/null
    if [ "$version" -ge 100000 ]; then
        pg -d "$DATABASE" -c 'ANALYZE "public"."st_part";' > /dev/null
    fi
    for _ in $(seq 1 10); do
        stale="$(pg -d "$DATABASE" -c "$(query_of "$source" staleStatisticsQuery)")"
        grep -qF "|st_" <<< "$stale" || break
        sleep 1
    done
    expect "the previewed analyze clears its findings" "$stale" "|st_" no

    # A reset, a crash or a failover empties last_analyze with the counters; pg_stats still says the table was analyzed.
    if pg -d "$DATABASE" -c "SELECT pg_catalog.pg_stat_reset()" > /dev/null 2>&1; then
        pg -d "$DATABASE" -c "INSERT INTO st_stale SELECT g, g FROM generate_series(5001, 5100) g" > /dev/null
        for _ in $(seq 1 10); do
            [ "$(pg -d "$DATABASE" -c "SELECT n_live_tup > 0 FROM pg_stat_user_tables WHERE relname = 'st_stale'")" = "t" ] && break
            sleep 1
        done
        stale="$(pg -d "$DATABASE" -c "$(query_of "$source" staleStatisticsQuery)")"
        expect "stale statistics trust pg_stats over counters a reset emptied" "$stale" "|st_stale|" no
        # pg_stats hides a table's rows from a role without SELECT on it, and under row-level security.
        if [ "$(pg -d "$DATABASE" -c "SELECT count(*) FROM pg_roles WHERE rolname = '$READER_ROLE'")" = "1" ]; then
            stale="$(pg -d "$DATABASE" -c "SET ROLE $READER_ROLE" -c "$(query_of "$source" staleStatisticsQuery)")"
            expect_pattern "without SELECT the counters decide, and the row says pg_stats could not be read" "$stale" \
                "\|st_stale\|r\|[0-9]+\|[0-9]+\|[0-9]+\|t\|f\|"
            pg -d "$DATABASE" -c "GRANT SELECT ON st_stale TO $READER_ROLE" -c "ALTER TABLE st_stale ENABLE ROW LEVEL SECURITY" > /dev/null
            stale="$(pg -d "$DATABASE" -c "SET ROLE $READER_ROLE" -c "$(query_of "$source" staleStatisticsQuery)")"
            expect_pattern "under row-level security the counters decide, and the row says pg_stats could not be read" "$stale" \
                "\|st_stale\|r\|[0-9]+\|[0-9]+\|[0-9]+\|t\|f\|"
            pg -d "$DATABASE" -c "ALTER TABLE st_stale DISABLE ROW LEVEL SECURITY" -c "REVOKE SELECT ON st_stale FROM $READER_ROLE" > /dev/null
        fi
    else
        echo "note  this user cannot call pg_stat_reset(), so the emptied counters case is skipped"
    fi
}

check_postgres_transaction_id_age() {
    pg -d "$DATABASE" > /dev/null <<'SQL'
CREATE TABLE xid_old (id int PRIMARY KEY, body text) WITH (autovacuum_enabled = false, autovacuum_freeze_max_age = 100000);
INSERT INTO xid_old SELECT g, repeat('x', 3000) FROM generate_series(1, 20) g;
CREATE TABLE xid_young (id int PRIMARY KEY) WITH (autovacuum_enabled = false);
CREATE TABLE xid_burn (v int);
SQL
    # Autovacuum still freezes a table past its freeze age, autovacuum_enabled or not. A held snapshot keeps
    # any freeze from moving past it, the way a long transaction does on a real server.
    hold_snapshot tablepro_health_xid 120
    pg -d "$DATABASE" -c "DO \$\$ BEGIN FOR i IN 1..120000 LOOP BEGIN INSERT INTO xid_burn VALUES (i); EXCEPTION WHEN OTHERS THEN NULL; END; END LOOP; END \$\$" > /dev/null

    local ages
    ages="$(pg -d "$DATABASE" -c "$(query_of "$source" transactionIdAgeQuery)")"
    expect "transaction ID age lists a table past its own lower freeze age" "$ages" "public|xid_old|" yes
    expect "transaction ID age reads the table's own freeze age" "$ages" "|100000|" yes
    expect "transaction ID age skips a table under the server's freeze age" "$ages" "xid_young" no
    expect "transaction ID age skips an extension's table past its freeze age" "$ages" "ext_owned" no
    expect "transaction ID age skips a table in an extension's schema past its freeze age" "$ages" "ext_schema" no
    hold_lock tablepro_health_xid_lock "LOCK TABLE xid_old IN ACCESS EXCLUSIVE MODE"
    ages="$(pg -d "$DATABASE" -c "SET lock_timeout = '5s'" -c "$(query_of "$source" transactionIdAgeQuery)" 2>&1)"
    expect "transaction ID age answers while the table it lists is locked" "$ages" "lock timeout" no
    expect "transaction ID age still lists the locked table" "$ages" "public|xid_old|" yes
    terminate tablepro_health_xid_lock

    terminate tablepro_health_xid
    # The fix exactly as PostgreSQLTableHealthProviderTests pins it.
    pg -d "$DATABASE" -c 'VACUUM (FREEZE) "public"."xid_old";' > /dev/null
    ages="$(pg -d "$DATABASE" -c "$(query_of "$source" transactionIdAgeQuery)")"
    expect "the previewed freeze clears its finding" "$ages" "xid_old" no
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
    # The other database holds a key into this one, so it is dropped first.
    my -e "DROP DATABASE IF EXISTS $OTHER_DATABASE; DROP DATABASE IF EXISTS $DATABASE; CREATE DATABASE $DATABASE; CREATE DATABASE $OTHER_DATABASE"
    trap cleanup_mysql EXIT

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
    my "$OTHER_DATABASE" -e "CREATE TABLE other_no_pk (v INT, KEY other_v_idx (v)); INSERT INTO other_no_pk VALUES (1)" || exit 1
    my "$OTHER_DATABASE" -e "CREATE TABLE other_child (id INT PRIMARY KEY, parent_id INT, CONSTRAINT other_child_fk FOREIGN KEY (parent_id) REFERENCES \`$DATABASE\`.parent (id))" || exit 1

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
    expect "foreign key rows name both ends of a local key" "$keys" "$DATABASE	child	child_fk	parent_id	parent	id	1	1	1" yes
    expect "foreign key rows include a key from another database into this one" "$keys" "$OTHER_DATABASE	other_child	other_child_fk	parent_id	parent	id	1	0	1" yes

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

    # MySQL 8 caches information_schema.TABLES for information_schema_stats_expiry seconds. The probe's own
    # session reads fresh after its writes; the app never changes it.
    local expiry=""
    my -e "SELECT @@SESSION.information_schema_stats_expiry" > /dev/null 2>&1 && expiry="SET SESSION information_schema_stats_expiry = 0; "
    check_mysql_auto_increment
    check_mysql_process_privilege
    if [ "${TABLEPRO_PROBE_RECLAIMABLE:-}" = "1" ]; then
        check_mysql_reclaimable_space
    else
        echo "note  the reclaimable space case writes about 1 GB; TABLEPRO_PROBE_RECLAIMABLE=1 runs it"
    fi
}

cleanup_mysql() {
    local admin=(mysql --protocol=TCP -h "$HOST" -P "$PORT" -u "$USER_NAME" ${tls[@]+"${tls[@]}"})
    "${admin[@]}" -e "DROP DATABASE IF EXISTS $OTHER_DATABASE; DROP DATABASE IF EXISTS $DATABASE; UPDATE performance_schema.setup_instruments SET ENABLED = 'YES' WHERE NAME = 'wait/io/table/sql/handler'; DELETE FROM performance_schema.setup_objects WHERE OBJECT_SCHEMA = '$DATABASE'" > /dev/null 2>&1
    "${admin[@]}" -e "DROP USER IF EXISTS $READER_ROLE@'%', $READER_ROLE@'localhost'" > /dev/null 2>&1
    if [ -n "${FILE_PER_TABLE:-}" ]; then
        "${admin[@]}" -e "SET GLOBAL innodb_file_per_table = $FILE_PER_TABLE" > /dev/null 2>&1
    fi
}

# One counter per integer type and per flavor quirk: unsigned, a non-key counter with a comment, an invisible
# one with a hostile comment, ZEROFILL, a key a foreign key references, and an unsigned bigint past Int64.
check_mysql_auto_increment() {
    my "$DATABASE" > /dev/null <<'SQL' || exit 1
CREATE TABLE ai_tiny_unsigned (id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY);
INSERT INTO ai_tiny_unsigned VALUES (199);
CREATE TABLE ai_int (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY);
INSERT INTO ai_int VALUES (1700000000);
CREATE TABLE ai_int_unsigned (id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY);
INSERT INTO ai_int_unsigned VALUES (1700000000);
CREATE TABLE ai_healthy (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY);
INSERT INTO ai_healthy VALUES (NULL), (NULL);
CREATE TABLE ai_secondary (id INT NOT NULL, seq SMALLINT NOT NULL AUTO_INCREMENT COMMENT 'row counter', PRIMARY KEY (id), UNIQUE KEY (seq));
INSERT INTO ai_secondary VALUES (1, 30000);
CREATE TABLE ai_zerofill (id INT(5) UNSIGNED ZEROFILL NOT NULL AUTO_INCREMENT PRIMARY KEY);
INSERT INTO ai_zerofill VALUES (4000000000);
CREATE TABLE ai_parent (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY);
INSERT INTO ai_parent VALUES (1800000000);
CREATE TABLE ai_child (id INT NOT NULL PRIMARY KEY, parent_id INT, CONSTRAINT ai_child_fk FOREIGN KEY (parent_id) REFERENCES ai_parent (id));
CREATE TABLE ai_bigint_unsigned (id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY);
INSERT INTO ai_bigint_unsigned VALUES (15000000000000000000);
CREATE TABLE ai_bigint_far (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY);
INSERT INTO ai_bigint_far VALUES (1000000000000000000);
SQL
    # INVISIBLE needs MySQL 8.0.23 or MariaDB 10.3.3.
    local invisible=no
    my "$DATABASE" > /dev/null 2>&1 <<'SQL' && invisible=yes
CREATE TABLE ai_invisible (id INT NOT NULL PRIMARY KEY, seq SMALLINT NOT NULL AUTO_INCREMENT INVISIBLE COMMENT 'it''s a \\ path', UNIQUE KEY (seq));
INSERT INTO ai_invisible (id, seq) VALUES (1, 30000);
SQL
    [ "$invisible" = yes ] || echo "note  this server has no invisible columns, so that case is skipped"

    local counters
    counters="$(my "$DATABASE" -e "$expiry$(query_of "$source" autoIncrementQuery)" 2>&1)"
    expect "AUTO_INCREMENT reads without overflowing next to a large bigint counter" "$counters" "ERROR" no
    expect "AUTO_INCREMENT lists a tinyint unsigned at 78%" "$counters" "ai_tiny_unsigned	id	tinyint	" yes
    expect "AUTO_INCREMENT lists a non-key counter with its comment" "$counters" "ai_secondary	seq	smallint	" yes
    expect "AUTO_INCREMENT reads an unsigned bigint past Int64 exactly" "$counters" "15000000000000000001	18446744073709551615" yes
    expect "AUTO_INCREMENT keeps ZEROFILL in the column type" "$counters" "unsigned zerofill" yes
    expect "AUTO_INCREMENT skips an unsigned int at 40%" "$counters" "ai_int_unsigned" no
    expect "AUTO_INCREMENT skips a bigint at 11%" "$counters" "ai_bigint_far" no
    expect "AUTO_INCREMENT skips a fresh counter" "$counters" "ai_healthy" no
    if [ "$invisible" = yes ]; then
        expect "AUTO_INCREMENT lists an invisible counter" "$counters" "INVISIBLE	30001	32767" yes
    fi

    # The fixes exactly as MySQLTableHealthProviderTests pins them. The bash string 'it''s a \\\\ path'
    # reaches the server as 'it''s a \\ path', the literal the driver's escaping writes.
    my -e "ALTER TABLE \`$DATABASE\`.\`ai_tiny_unsigned\` MODIFY COLUMN \`id\` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT;"
    my -e "ALTER TABLE \`$DATABASE\`.\`ai_secondary\` MODIFY COLUMN \`seq\` BIGINT NOT NULL AUTO_INCREMENT COMMENT 'row counter';"
    my -e "ALTER TABLE \`$DATABASE\`.\`ai_zerofill\` MODIFY COLUMN \`id\` BIGINT(5) UNSIGNED ZEROFILL NOT NULL AUTO_INCREMENT;"
    if [ "$invisible" = yes ]; then
        my -e "ALTER TABLE \`$DATABASE\`.\`ai_invisible\` MODIFY COLUMN \`seq\` BIGINT NOT NULL AUTO_INCREMENT INVISIBLE COMMENT 'it''s a \\\\ path';"
    fi
    local refused
    refused="$(my -e "ALTER TABLE \`$DATABASE\`.\`ai_parent\` MODIFY COLUMN \`id\` BIGINT NOT NULL AUTO_INCREMENT;" 2>&1)"
    expect_pattern "widening a key a foreign key references is refused, as its detail says" "$refused" "3780|1833"

    counters="$(my "$DATABASE" -e "$expiry$(query_of "$source" autoIncrementQuery)" 2>&1)"
    expect "the previewed widening clears an unsigned tinyint counter" "$counters" "ai_tiny_unsigned" no
    expect "the previewed widening clears a non-key counter" "$counters" "ai_secondary" no
    expect "the previewed widening clears a ZEROFILL counter" "$counters" "ai_zerofill" no
    expect "a counter a foreign key holds stays listed" "$counters" "ai_parent" yes
    expect "an unsigned bigint counter has no wider type and stays listed" "$counters" "ai_bigint_unsigned" yes
    if [ "$invisible" = yes ]; then
        expect "the previewed widening clears an invisible counter" "$counters" "ai_invisible" no
    fi

    local restated
    restated="$(my "$DATABASE" -e "SELECT TABLE_NAME, COLUMN_TYPE, EXTRA, COLUMN_COMMENT FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '$DATABASE' AND TABLE_NAME IN ('ai_invisible', 'ai_secondary', 'ai_zerofill') AND EXTRA LIKE '%auto_increment%' ORDER BY 1")"
    expect "the widened counter keeps its comment" "$restated" "auto_increment	row counter" yes
    expect "the widened ZEROFILL counter keeps its width" "$restated" "bigint(5) unsigned zerofill" yes
    if [ "$invisible" = yes ]; then
        expect "the widened counter stays invisible and keeps its hostile comment" "$restated" "INVISIBLE	it's a \\\\ path" yes
    fi
}

check_mysql_process_privilege() {
    local pools
    pools="$(my -e "$(query_of "$source" processPrivilegeQuery)" 2>&1)"
    expect_pattern "the PROCESS probe reads the buffer pools" "$pools" "^[1-9][0-9]*$"

    # Also at localhost: an anonymous ''@'localhost', which some installs create, outranks a named user at '%'.
    my -e "DROP USER IF EXISTS $READER_ROLE@'%', $READER_ROLE@'localhost'" > /dev/null 2>&1
    if my -e "CREATE USER $READER_ROLE@'%' IDENTIFIED BY 'tablepro_health', $READER_ROLE@'localhost' IDENTIFIED BY 'tablepro_health'; GRANT SELECT ON \`$DATABASE\`.* TO $READER_ROLE@'%', $READER_ROLE@'localhost'" > /dev/null 2>&1; then
        local denied
        denied="$(MYSQL_PWD=tablepro_health mysql --protocol=TCP -h "$HOST" -P "$PORT" -u "$READER_ROLE" ${tls[@]+"${tls[@]}"} -N -B \
            -e "$(query_of "$source" processPrivilegeQuery)" 2>&1)"
        expect "without PROCESS the probe is refused" "$denied" "1227" yes
    else
        echo "note  this user cannot create a user, so the PROCESS refusal is skipped"
    fi
}

# A table in its own file, a partitioned one and a MyISAM one with three quarters deleted, and one in the
# system tablespace, whose free space belongs to every table there.
check_mysql_reclaimable_space() {
    local query=reclaimableSpaceQuery
    my -e "SELECT VERSION()" | grep -qi mariadb && query=mariaDBReclaimableSpaceQuery
    my "$DATABASE" > /dev/null <<'SQL' || exit 1
CREATE TABLE fx_own (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, pad VARCHAR(1000) NOT NULL) ENGINE = InnoDB;
INSERT INTO fx_own (pad) VALUES (REPEAT('x', 900));
SQL
    for _ in $(seq 1 18); do
        my "$DATABASE" -e "INSERT INTO fx_own (pad) SELECT pad FROM fx_own" || exit 1
    done
    my "$DATABASE" > /dev/null <<'SQL' || exit 1
CREATE TABLE fx_parts (id INT NOT NULL PRIMARY KEY, pad VARCHAR(1000) NOT NULL) ENGINE = InnoDB PARTITION BY RANGE (id) (PARTITION p0 VALUES LESS THAN (200000), PARTITION p1 VALUES LESS THAN MAXVALUE);
INSERT INTO fx_parts SELECT * FROM fx_own;
CREATE TABLE fx_myisam (id INT NOT NULL PRIMARY KEY, pad VARCHAR(1000) NOT NULL) ENGINE = MyISAM;
INSERT INTO fx_myisam SELECT * FROM fx_own;
SQL
    local system_table="CREATE TABLE fx_sys (id INT NOT NULL PRIMARY KEY, pad VARCHAR(1000) NOT NULL) ENGINE = InnoDB"
    if [ "$query" = mariaDBReclaimableSpaceQuery ]; then
        FILE_PER_TABLE="$(my -e "SELECT @@GLOBAL.innodb_file_per_table")"
        my -e "SET GLOBAL innodb_file_per_table = OFF"
        my "$DATABASE" -e "$system_table"
        my -e "SET GLOBAL innodb_file_per_table = $FILE_PER_TABLE"
        FILE_PER_TABLE=""
    else
        my "$DATABASE" -e "$system_table TABLESPACE innodb_system"
    fi
    my "$DATABASE" > /dev/null <<'SQL' || exit 1
INSERT INTO fx_sys SELECT * FROM fx_own;
DELETE FROM fx_own WHERE id <= 196608;
DELETE FROM fx_parts WHERE id < 200000;
DELETE FROM fx_myisam WHERE id <= 196608;
DELETE FROM fx_sys WHERE id <= 196608;
SQL
    for _ in $(seq 1 120); do
        my -e "SHOW ENGINE INNODB STATUS" | grep -q "History list length 0" && break
        sleep 1
    done

    local frag
    frag="$(my "$DATABASE" -e "$expiry$(query_of "$source" "$query")" 2>&1)"
    expect "reclaimable space lists a table in its own file" "$frag" "fx_own	InnoDB" yes
    expect "reclaimable space lists a partitioned table" "$frag" "fx_parts	InnoDB" yes
    expect "reclaimable space lists a MyISAM table" "$frag" "fx_myisam	MyISAM" yes
    expect "reclaimable space skips a table in the system tablespace" "$frag" "fx_sys" no

    # The fixes exactly as MySQLTableHealthProviderTests pins them.
    for table in fx_own fx_parts fx_myisam; do
        my -e "OPTIMIZE TABLE \`$DATABASE\`.\`$table\`;" > /dev/null
    done
    frag="$(my "$DATABASE" -e "$expiry$(query_of "$source" "$query")" 2>&1)"
    expect "the previewed OPTIMIZE clears its findings" "$frag" "fx_" no
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
