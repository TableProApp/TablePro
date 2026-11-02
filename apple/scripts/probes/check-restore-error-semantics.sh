#!/usr/bin/env bash
#
# Check what a restore keeps when the dump meets objects that already exist or an error, with the
# flags NativeDumpRegistry passes. RestoreConfirmationText states these facts for each engine.
#
# - sqlite3 -safe -bail: stops at the first error. A `.dump` is one transaction, so nothing of it is
#   kept; a dump without a transaction keeps what ran before the error. `.dump` writes
#   CREATE TABLE IF NOT EXISTS for a table whose name is quoted, so such a table that already
#   exists gets the dump's rows added when no key collides.
# - mysql or mariadb without --force: a dump from the matching dump tool drops and recreates each
#   table it names; the client stops at the first error and keeps what ran before it.
# - pg_restore without --exit-on-error: existing tables are kept and get the dump's rows unless a
#   key collides, and the run carries on past errors and exits 1.
#
# Usage:
#   apple/scripts/probes/check-restore-error-semantics.sh
#   MYSQL_PROBE_ARGS="--protocol=TCP -h 127.0.0.1 -P 3306 -u root" PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres \
#       apple/scripts/probes/check-restore-error-semantics.sh
#
# sqlite3 needs no server. The mysql family runs when the client on PATH can connect with
# MYSQL_PROBE_ARGS (default: none, the local socket) and create a scratch database, PostgreSQL when
# psql can create one with the libpq environment. Each skips otherwise. Exits 1 when a fact differs.

set -uo pipefail

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-restore-errors.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

expect() {
    if [ "$2" = "$3" ]; then
        echo "  ok $1"
    else
        echo "FAIL: $1: expected '$3', got '$2'" >&2
        failures=$((failures + 1))
    fi
}

SQLITE="$(command -v sqlite3 || true)"
if [ -n "$SQLITE" ]; then
    echo "checking $SQLITE ($("$SQLITE" --version | cut -d' ' -f1))"
    sq() { "$SQLITE" "$@" 2>/dev/null; }
    restore() { "$SQLITE" -safe -bail "$1" < "$2" > /dev/null 2>&1; echo $?; }
    tables() { sq "$1" "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name)"; }

    sq "$WORK/src.db" "CREATE TABLE plain(id INTEGER PRIMARY KEY); INSERT INTO plain VALUES (1);
        CREATE TABLE \"quoted\"(id INTEGER PRIMARY KEY); INSERT INTO quoted VALUES (1);
        CREATE TABLE \"keyless\"(v TEXT); INSERT INTO keyless VALUES ('dump');
        CREATE TABLE later(v INT); INSERT INTO later VALUES (1);"
    "$SQLITE" -safe "$WORK/src.db" .dump > "$WORK/dump.sql"
    expect ".dump opens one transaction" "$(grep -c '^BEGIN TRANSACTION;$' "$WORK/dump.sql")" "1"

    sq "$WORK/existing.db" "CREATE TABLE plain(id INTEGER PRIMARY KEY); INSERT INTO plain VALUES (9);"
    expect "an existing table stops the restore" "$(restore "$WORK/existing.db" "$WORK/dump.sql")" "1"
    expect "and keeps none of the dump" "$(tables "$WORK/existing.db"),$(sq "$WORK/existing.db" 'SELECT id FROM plain')" "plain,9"

    sq "$WORK/collision.db" "CREATE TABLE \"quoted\"(id INTEGER PRIMARY KEY); INSERT INTO quoted VALUES (1);"
    expect "a key collision stops the restore" "$(restore "$WORK/collision.db" "$WORK/dump.sql")" "1"
    expect "and keeps none of the dump" "$(tables "$WORK/collision.db")" "quoted"

    sq "$WORK/keyless.db" "CREATE TABLE \"keyless\"(v TEXT); INSERT INTO keyless VALUES ('own');"
    expect "an existing quoted table without a key takes the dump" "$(restore "$WORK/keyless.db" "$WORK/dump.sql")" "0"
    expect "and keeps its own rows beside the dump's" "$(sq "$WORK/keyless.db" "SELECT group_concat(v) FROM keyless")" "own,dump"

    printf 'CREATE TABLE first(v INT);\nINSERT INTO first VALUES (1);\nCREATE TABLE plain(id INT);\nCREATE TABLE second(v INT);\n' \
        > "$WORK/foreign.sql"
    sq "$WORK/foreign.db" "CREATE TABLE plain(id INTEGER PRIMARY KEY);"
    expect "a dump without a transaction stops at the error" "$(restore "$WORK/foreign.db" "$WORK/foreign.sql")" "1"
    expect "and keeps what ran before it" "$(tables "$WORK/foreign.db")" "first,plain"
else
    echo "no sqlite3 on PATH; skipping"
fi

MYSQL="$(command -v mysql || command -v mariadb || true)"
DUMP="$(command -v mysqldump || command -v mariadb-dump || true)"
read -r -a PROBE_ARGS <<< "${MYSQL_PROBE_ARGS:-}"
DB="tablepro_restore_errors_$$"
my() { "$MYSQL" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} "$@" 2>/dev/null; }
if [ -n "$MYSQL" ] && [ -n "$DUMP" ] && my -e "CREATE DATABASE ${DB}_src; CREATE DATABASE $DB" > /dev/null; then
    banner="$("$MYSQL" --version)"
    case "$banner" in
        *MariaDB* | *mariadb*) switch="--sandbox" ;;
        *) switch="--skip-system-command" ;;
    esac
    echo "checking $MYSQL and $DUMP ($banner)"
    restore() {
        "$MYSQL" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} --binary-mode --local-infile=0 "$switch" \
            --default-character-set=utf8mb4 -- "$DB" < "$1" > /dev/null 2>&1
        echo $?
    }
    rows() { my -N "$DB" -e "SELECT IFNULL(group_concat(id ORDER BY id), '') FROM $1" || echo "missing"; }
    reset() { my -e "DROP DATABASE $DB; CREATE DATABASE $DB" > /dev/null; my "$DB" -e "$1" > /dev/null; }

    my "${DB}_src" -e "CREATE TABLE a(id INT PRIMARY KEY); INSERT INTO a VALUES (1), (2);
        CREATE TABLE b(id INT PRIMARY KEY); INSERT INTO b VALUES (1);" > /dev/null
    "$DUMP" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} --single-transaction --routines --triggers --events \
        --default-character-set=utf8mb4 -- "${DB}_src" > "$WORK/my.sql" 2>/dev/null

    reset "CREATE TABLE a(id INT PRIMARY KEY, extra INT); INSERT INTO a VALUES (9, 9); CREATE TABLE c(id INT);"
    expect "a dump over existing tables restores" "$(restore "$WORK/my.sql")" "0"
    expect "and overwrites the table it names" "$(rows a)" "1,2"
    expect "and leaves a table it does not name" "$(rows c)" ""

    # A two-value row in b's INSERT fails with 1136 after a was replaced; MariaDB breaks the line after VALUES.
    sed 's/^INSERT INTO `b` VALUES/INSERT INTO `b` VALUES (1, 2),/' "$WORK/my.sql" > "$WORK/my-broken.sql"
    reset "CREATE TABLE a(id INT PRIMARY KEY); INSERT INTO a VALUES (9);"
    expect "an error stops the restore" "$(restore "$WORK/my-broken.sql")" "1"
    expect "and keeps the table replaced before it" "$(rows a)" "1,2"

    printf 'CREATE TABLE first(id INT);\nINSERT INTO first VALUES (1);\nCREATE TABLE b(id INT);\nCREATE TABLE second(id INT);\n' \
        > "$WORK/my-foreign.sql"
    reset "CREATE TABLE b(id INT PRIMARY KEY);"
    expect "a dump without DROP stops at an existing table" "$(restore "$WORK/my-foreign.sql")" "1"
    expect "and keeps what ran before it" "$(rows first),$(rows second)" "1,missing"

    my -e "DROP DATABASE $DB; DROP DATABASE ${DB}_src" > /dev/null
else
    echo "no mysql-family client and dump tool that can create a scratch database; skipping"
fi

PSQL="$(command -v psql || true)"
if [ -n "$PSQL" ] && command -v pg_dump > /dev/null && command -v pg_restore > /dev/null \
    && "$PSQL" -qX -d postgres -c "CREATE DATABASE ${DB}_src" -c "CREATE DATABASE $DB" > /dev/null 2>&1; then
    echo "checking $(command -v pg_restore) ($(pg_restore --version))"
    pq() { "$PSQL" -qXAt -d "$@" 2>/dev/null; }
    pq "${DB}_src" -c "CREATE TABLE keyed(id int PRIMARY KEY); INSERT INTO keyed VALUES (1);
        CREATE TABLE keyless(v int); INSERT INTO keyless VALUES (1);
        CREATE TABLE fresh(v int); INSERT INTO fresh VALUES (1);"
    pq "$DB" -c "CREATE TABLE keyed(id int PRIMARY KEY, extra int); INSERT INTO keyed VALUES (1, 9);
        CREATE TABLE keyless(v int); INSERT INTO keyless VALUES (7);"
    pg_dump -Fc -d "${DB}_src" -f "$WORK/pg.dump"
    pg_restore --no-owner --no-acl -d "$DB" "$WORK/pg.dump" > /dev/null 2>&1
    expect "pg_restore carries on past errors and exits 1" "$?" "1"
    expect "and keeps an existing table as it was" "$(pq "$DB" -c "SELECT string_agg(row(t.*)::text, ' ') FROM keyed t")" "(1,9)"
    expect "and adds the dump's rows to a table without a key" "$(pq "$DB" -c "SELECT string_agg(v::text, ',' ORDER BY v) FROM keyless")" "1,7"
    expect "and restores the rest" "$(pq "$DB" -c "SELECT count(*) FROM fresh")" "1"
    "$PSQL" -qX -d postgres -c "DROP DATABASE $DB" -c "DROP DATABASE ${DB}_src" > /dev/null 2>&1
else
    echo "no psql, pg_dump and pg_restore that can create a scratch database; skipping"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures restore fact(s) differ from what RestoreConfirmationText says" >&2
    exit 1
fi
echo "restore clients keep what RestoreConfirmationText says"
