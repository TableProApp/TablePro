#!/usr/bin/env bash
#
# Check the server facts the PostgreSQL driver and SQL export rely on for text encoding.
#
# The macOS and iOS drivers put client_encoding=UTF8 in the libpq connection string instead of
# running SET client_encoding after connect, because a value from the startup packet is the
# session's reset value and survives RESET ALL and DISCARD ALL, while a SET does not. SQL export
# opens a PostgreSQL-family dump with SET client_encoding = 'UTF8', which only helps if the engine
# accepts that statement. This asks a real server both questions, then restores a UTF-8 dump into
# LATIN1 and EUC_JP databases through psql reading stdin, where psql leaves the client encoding at
# the database's own, and checks the bytes that were stored.
#
# Usage:
#   scripts/check-postgres-client-encoding.sh [host] [port] [user] [database]
#
# Needs psql. The password, if any, comes from PGPASSWORD. Point it at CockroachDB, PGlite or any
# other PostgreSQL-compatible engine to check the first two facts there; the restore check is
# skipped on an engine that cannot create and connect to a LATIN1 or EUC_JP database, which
# includes both of those. Exits non-zero on a failure.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
USER_NAME="${3:-postgres}"
DATABASE="${4:-postgres}"

command -v psql > /dev/null || {
    echo "psql not found" >&2
    exit 3
}

unset PGCLIENTENCODING
BASE="host=$HOST port=$PORT user=$USER_NAME sslmode=prefer connect_timeout=10"
PSQL=(psql -X -A -t -v ON_ERROR_STOP=1)

if ! "${PSQL[@]}" "$BASE dbname=$DATABASE" -c "SELECT 1" > /dev/null 2>&1; then
    echo "no PostgreSQL at $HOST:$PORT for $USER_NAME" >&2
    exit 3
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
    local label=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        echo "ok    $label"
    else
        echo "FAIL  $label: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

pinned="$BASE dbname=$DATABASE client_encoding=UTF8"
check "startup client_encoding=UTF8" "UTF8" "$("${PSQL[@]}" "$pinned" -c "SHOW client_encoding" 2>&1)"
check "UTF8 after RESET ALL" "UTF8" "$("${PSQL[@]}" "$pinned" -c "RESET ALL" -c "SHOW client_encoding" 2>&1 | tail -1)"
check "UTF8 after DISCARD ALL" "UTF8" "$("${PSQL[@]}" "$pinned" -c "DISCARD ALL" -c "SHOW client_encoding" 2>&1 | tail -1)"
check "SET client_encoding = 'UTF8' accepted" "SET" \
    "$(psql -X -v ON_ERROR_STOP=1 "$BASE dbname=$DATABASE" -c "SET client_encoding = 'UTF8'" 2>&1)"

restore_check() {
    local encoding=$1 text=$2 expected_hex=$3 db
    db="tablepro_encoding_probe_$(echo "$encoding" | tr '[:upper:]' '[:lower:]')"
    "${PSQL[@]}" "$BASE dbname=$DATABASE" -c "DROP DATABASE IF EXISTS $db" > /dev/null 2>&1
    if ! "${PSQL[@]}" "$BASE dbname=$DATABASE" \
        -c "CREATE DATABASE $db ENCODING '$encoding' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0" \
        > /dev/null 2>&1; then
        echo "skip  $encoding restore: the server cannot create a $encoding database"
        return
    fi
    local reached
    reached=$("${PSQL[@]}" "$BASE dbname=$db" -c "SHOW server_encoding" 2>&1)
    if [ "$reached" != "$encoding" ]; then
        echo "skip  $encoding restore: connecting to $db reached a $reached database"
        "${PSQL[@]}" "$BASE dbname=$DATABASE" -c "DROP DATABASE IF EXISTS $db" > /dev/null 2>&1
        return
    fi

    printf "SET client_encoding = 'UTF8';\n\nCREATE TABLE t (v text);\nINSERT INTO t VALUES ('%s');\n" "$text" \
        > "$WORK/dump.sql"
    local output
    output=$("${PSQL[@]}" "$BASE dbname=$db" < "$WORK/dump.sql" 2>&1)
    local stored
    stored=$("${PSQL[@]}" "$BASE dbname=$db" -c "SELECT encode(convert_to(v, '$encoding'), 'hex') FROM t" 2>&1)
    check "$encoding restore of a UTF-8 dump through stdin" "$expected_hex" "${stored:-$output}"

    local session
    session=$("${PSQL[@]}" "$BASE dbname=$db client_encoding=UTF8" -c "RESET ALL" -c "SELECT v FROM t" 2>&1 | tail -1)
    check "$encoding read through a UTF8-pinned session after RESET ALL" "$text" "$session"

    "${PSQL[@]}" "$BASE dbname=$DATABASE" -c "DROP DATABASE IF EXISTS $db" > /dev/null 2>&1
}

restore_check LATIN1 "café" "636166e9"
restore_check EUC_JP "メール" "a5e1a1bca5eb"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
