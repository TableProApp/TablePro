#!/usr/bin/env bash
#
# Check the Databend tokenizer facts the Mac app writes names and bound values for: SQLQuoting.databendIdentifier
# and DatabendLiteral.
#
# Usage:
#   scripts/probes/check-databend-lexing.sh [port] [user]
#
# Runs against a throwaway server on this Mac only, since the client connects without TLS. Needs the mysql or mariadb
# client. The password, if any, comes from DATABEND_PASSWORD. Everything it creates lives in a database of its own,
# dropped on exit. The server's version picks the expectation for the rules that changed: a block comment ends at its
# first `*/` from 1.2.884, and a backtick name reads a doubled backtick from 1.2.945. Exits 0 when the server reads
# every text as the app expects, 1 when it does not, and 3 when the check could not run.
#
#   docker run -d --rm --name databend-probe -p 127.0.0.1:3307:3307 datafuselabs/databend:v1.2.880-nightly

# shellcheck disable=SC2016 # Backticks and $$ below are SQL.
set -uo pipefail

HOST=127.0.0.1
PORT="${1:-3307}"
USER_NAME="${2:-root}"
SCRATCH="tp_probe_$$_$RANDOM"
DATABASE=""
CLIENT="$(command -v mysql || command -v mariadb)" || {
    echo "no mysql or mariadb client" >&2
    exit 3
}

# The client strips comments unless told not to, which would hide the very texts this checks.
ask() {
    MYSQL_PWD="${DATABEND_PASSWORD:-}" "$CLIENT" -h"$HOST" -P"$PORT" -u"$USER_NAME" --skip-ssl -N -B --raw \
        --comments ${DATABASE:+-D"$DATABASE"} -e "$1" 2>&1 | tr '\n' ' ' | sed 's/ *$//'
}

VERSION="$(ask "SELECT version()")"
BUILD="$(printf '%s' "$VERSION" | sed -n 's/.*v1\.2\.\([0-9][0-9]*\).*/\1/p')"
[ -n "$BUILD" ] || {
    echo "no Databend 1.2 at $HOST:$PORT: $VERSION" >&2
    exit 3
}
echo "server: $VERSION"

STATUS=0
report() {
    echo "$1: $2 (app expects $3)"
    [ "$2" = "$3" ] || STATUS=1
}
refused() {
    case "$1" in *SyntaxException*) echo refused ;; *) echo "$1" ;; esac
}

CREATED="$(ask "CREATE DATABASE $SCRATCH")"
[ -z "$CREATED" ] || {
    echo "could not create $SCRATCH: $CREATED" >&2
    exit 3
}
trap 'DATABASE=""; ask "DROP DATABASE $SCRATCH" > /dev/null' EXIT
DATABASE="$SCRATCH"
ask 'CREATE TABLE tp_probe (v INT); CREATE TABLE "tp_probe`q" (v INT); CREATE TABLE "tp_probe`\b" (v INT)' > /dev/null
ask 'INSERT INTO tp_probe VALUES (1); INSERT INTO "tp_probe`q" VALUES (2)' > /dev/null

if [ "$BUILD" -ge 945 ]; then doubled=2; else doubled=1; fi
report "doubled backtick" "$(ask 'SELECT v FROM `tp_probe``q`')" "$doubled"
report "double-quoted name holding a backtick" "$(ask 'SELECT v FROM "tp_probe`q"')" 2
report "backslash in a double-quoted name" \
    "$(ask "SELECT hex(name) FROM system.tables WHERE database = database() AND name LIKE 'tp\\_probe\`%b'")" \
    74705f70726f6265605c62

report "octal escape after NUL's \\0" "$(ask "SELECT '\\071f3ac2'")" 9f3ac2
report "NUL as \\x00 before digits" "$(ask "SELECT hex('\\x0071')")" 003731

if [ "$BUILD" -ge 884 ]; then closed=1; else closed=refused; fi
report "block comment ending in **/" "$(refused "$(ask '/** c **/ SELECT 1')")" "$closed"
report "empty block comment /**/" "$(refused "$(ask '/**/ SELECT 1')")" "$closed"
report "block comment /***/" "$(refused "$(ask '/***/ SELECT 1')")" 1

report "form feed ends a line comment" "$(ask "$(printf 'SELECT 1 --x\f, 2')")" $'1\t2'
report "quote inside a hint opens a string" "$(ask "/*+ ' */ SELECT 1 -- ' */ SELECT 2")" 2
report "\$\$ after a name continues it" "$(ask 'SELECT 1 AS a$$, 2 -- $$')" $'1\t2'
report "\$\$ after a number opens a code string" "$(refused "$(ask 'SELECT 1$$, 2 -- $$')")" refused

exit "$STATUS"
