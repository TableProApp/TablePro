#!/usr/bin/env bash
#
# Check the Databend tokenizer facts the Mac app writes names and bound values for, SQLQuoting.databendIdentifier
# and DatabendLiteral, and reads statements by in Safe Mode, DatabendTokenizer.
#
# Usage:
#   scripts/probes/check-databend-lexing.sh [port] [user]
#
# Runs against a throwaway server on this Mac only, since the client connects without TLS. Needs the mysql or mariadb
# client. The password, if any, comes from DATABEND_PASSWORD. Everything it creates lives in a database of its own,
# dropped on exit. The server's version picks the expectation for the rules that changed: `SETTINGS` runs the statement
# after it from 1.2.652, a block comment ends at its first `*/` from 1.2.884, a keyword ends where a non-ASCII name
# starts from 1.2.888, and a backtick name reads a doubled backtick from 1.2.945. Exits 0 when the server reads
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

# Whether a text drops a table: Safe Mode reads each of these as a DROP wherever the server runs one.
dropped() {
    ask 'CREATE TABLE IF NOT EXISTS tp_victim (v INT)' > /dev/null
    ask "$1" > /dev/null
    case "$(ask "SELECT count(*) FROM system.tables WHERE database = database() AND name = 'tp_victim'")" in
        0) echo dropped ;;
        1) echo kept ;;
        *) echo unknown ;;
    esac
}
report "quote in a skipped hint" "$(dropped "/*+ ' */ SELECT 1 -- ' */ DROP TABLE tp_victim")" dropped
report "stage name in a skipped hint" "$(dropped '/*+ @x*/ SELECT 1 */ DROP TABLE tp_victim')" dropped
report "\$\$ in a skipped hint" "$(dropped '/*+ $$ */ SELECT $$ */ DROP TABLE tp_victim')" dropped
report "hint skipped inside a skipped hint" "$(dropped '/*+ /*+ */ SELECT 1 */ DROP TABLE tp_victim')" dropped
if [ "$BUILD" -ge 884 ]; then paired=kept; else paired=dropped; fi
report "comment ending in **/ before a DROP" "$(dropped '/** x **/ SELECT 1 /* */ DROP TABLE tp_victim')" "$paired"
report "empty comment /**/ before a DROP" "$(dropped '/**/ SELECT 1 /* */ DROP TABLE tp_victim')" "$paired"
report "carriage return in a line comment" "$(dropped "$(printf 'SELECT 1 -- x\rDROP TABLE tp_victim')")" kept
ask 'CREATE TABLE tp_rows (v INT)' > /dev/null
ask "INSERT INTO tp_rows SELECT 1 \$\$" > /dev/null
report "INSERT before text the tokenizer refuses" "$(ask 'SELECT count(*) FROM tp_rows')" 1
if [ "$BUILD" -ge 652 ]; then wrapped=dropped; else wrapped=kept; fi
report "DROP under SETTINGS" "$(dropped 'SETTINGS (max_threads=1) DROP TABLE tp_victim')" "$wrapped"
report "DROP under SETTINGS with no list" "$(dropped 'SETTINGS DROP TABLE tp_victim')" "$wrapped"

# From 1.2.888 a keyword ends where a non-ASCII name starts, so TABLE中tp is TABLE and then 中tp.
ask 'CREATE OR REPLACE TABLE `中tp` (v INT)' > /dev/null
ask 'INSERT INTO `中tp` VALUES (1)' > /dev/null
ask 'CREATE OR REPLACE TABLE中tp (v INT)' > /dev/null
if [ "$BUILD" -ge 888 ]; then replaced=0; else replaced=1; fi
report "keyword before a non-ASCII name" "$(ask 'SELECT count(*) FROM `中tp`')" "$replaced"
before="$(ask 'SELECT count(*) FROM `中tp`')"
ask "/*+ ' */ SELECT 1 -- ' */ REPLACE中tp ON (v) SELECT 4 'x" > /dev/null
if [ "$BUILD" -ge 888 ]; then added=1; else added=0; fi
report "REPLACE before a non-ASCII name and untokenizable text" "$(($(ask 'SELECT count(*) FROM `中tp`') - before))" "$added"

exit "$STATUS"
