#!/usr/bin/env bash
#
# Check how a live MySQL or MariaDB server reports column defaults against what the driver assumes.
#
# MySQLCatalogDefault.swift decodes a default from the catalog by hand, and each rule in it is a
# transcription of server behaviour nothing at runtime re-checks: that SQL NULL stands for DEFAULT
# NULL on a nullable column, that MariaDB's SHOW FULL COLUMNS never quotes while its
# INFORMATION_SCHEMA does from 10.2.7, and that MySQL backslash-escapes the quotes in an expression
# default. This builds one scratch table in a throwaway database, reads it back both ways, and fails
# on any answer that differs from the one the decoder was written against.
#
# Usage:
#   scripts/check-mysql-column-defaults.sh [host] [port] [user]
#
# Needs the mysql client and an account that may create and drop a database. The password, if any,
# comes from MYSQL_PWD. Set MYSQL_UNIX_PORT to connect through that socket instead of host and port. Exits
# non-zero on a disagreement and 3 when no server answers.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-root}"
DATABASE="tablepro_default_check_$$"

command -v mysql > /dev/null || {
    echo "mysql client not found" >&2
    exit 3
}

MYSQL=(mysql --no-defaults -u "$USER_NAME" -N -B --default-character-set=utf8mb4)
# Both clients pick TCP for a numeric host or a given port, and a socket path does not override
# either, so the socket form names neither.
if [ -n "${MYSQL_UNIX_PORT:-}" ]; then
    MYSQL+=(--protocol=socket -S "$MYSQL_UNIX_PORT")
else
    MYSQL+=(-h "$HOST" -P "$PORT")
fi
VERSION="$("${MYSQL[@]}" -e "SELECT VERSION()" 2> /dev/null)" || {
    echo "no MySQL at $HOST:$PORT for $USER_NAME" >&2
    exit 3
}

IS_MARIADB=0
case "$VERSION" in
    *MariaDB*) IS_MARIADB=1 ;;
esac

IFS=. read -r MAJOR MINOR PATCH <<< "${VERSION%%-*}"
PATCH="${PATCH%%[!0-9]*}"

version_at_least() {
    [ "$MAJOR" -gt "$1" ] && return 0
    [ "$MAJOR" -lt "$1" ] && return 1
    [ "$MINOR" -gt "$2" ] && return 0
    [ "$MINOR" -lt "$2" ] && return 1
    [ "$PATCH" -ge "$3" ]
}

# MySQL takes a general expression default from 8.0.13 and MariaDB from 10.2.1; MariaDB quotes its
# catalog literals from 10.2.7. Below those floors the fixture is left out or the bare form expected.
HAS_EXPRESSION_DEFAULT=0
CATALOG_QUOTES=0
if [ "$IS_MARIADB" = 1 ]; then
    version_at_least 10 2 1 && HAS_EXPRESSION_DEFAULT=1
    version_at_least 10 2 7 && CATALOG_QUOTES=1
else
    version_at_least 8 0 13 && HAS_EXPRESSION_DEFAULT=1
fi

"${MYSQL[@]}" -e "CREATE DATABASE \`$DATABASE\`" || exit 3
trap '"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`$DATABASE\`"' EXIT

if [ "$HAS_EXPRESSION_DEFAULT" = 0 ]; then
    EXPRESSION_DEFAULT="'plain'"
elif [ "$IS_MARIADB" = 1 ]; then
    EXPRESSION_DEFAULT="uuid()"
else
    EXPRESSION_DEFAULT="(concat('a','b'))"
fi

"${MYSQL[@]}" "$DATABASE" -e "
    CREATE TABLE probe (
        implicit_null VARCHAR(10) NULL,
        explicit_null VARCHAR(10) NULL DEFAULT NULL,
        text_null TEXT NULL,
        string_null VARCHAR(10) NULL DEFAULT 'NULL',
        string_abc VARCHAR(10) NULL DEFAULT 'abc',
        string_empty VARCHAR(10) NOT NULL DEFAULT '',
        no_default VARCHAR(10) NOT NULL,
        expression VARCHAR(40) NULL DEFAULT $EXPRESSION_DEFAULT
    )" || exit 1

failures=0

report() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok    $label: $actual"
    else
        echo "FAIL  $label: expected $expected, got $actual"
        failures=$((failures + 1))
    fi
}

hex() {
    printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F'
}

# SQL NULL and the text NULL print the same in batch mode, so the catalog answer is compared as hex
# with SQL NULL spelled out.
catalog_default() {
    "${MYSQL[@]}" -e "
        SELECT IF(COLUMN_DEFAULT IS NULL, 'SQL-NULL', HEX(COLUMN_DEFAULT))
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = '$DATABASE' AND TABLE_NAME = 'probe' AND COLUMN_NAME = '$1'"
}

# SHOW FULL COLUMNS cannot be wrapped in a SELECT, so SQL NULL is read from the XML form's xsi:nil.
show_default() {
    local line
    line="$("${MYSQL[@]}" --xml "$DATABASE" -e "SHOW FULL COLUMNS FROM probe WHERE Field = '$1'" \
        | grep '<field name="Default"')"
    case "$line" in
        *'xsi:nil="true"'*) echo "SQL-NULL" ;;
        *) printf '%s' "$line" | sed -e 's/.*<field name="Default">//' -e 's/<\/field>.*//' ;;
    esac
}

# The expression's DEFAULT operand as SHOW CREATE TABLE prints it, which is what the driver reads for a
# MySQL expression default and for a MariaDB whose catalog does not answer in its quoted form.
create_default() {
    "${MYSQL[@]}" -r "$DATABASE" -e "SHOW CREATE TABLE probe" | cut -f2 \
        | grep "^  \`$1\` " | sed -e 's/.* DEFAULT //' -e 's/,$//'
}

extra_of() {
    "${MYSQL[@]}" -e "
        SELECT EXTRA FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = '$DATABASE' AND TABLE_NAME = 'probe' AND COLUMN_NAME = '$1'"
}

echo "server: $VERSION"

for column in implicit_null explicit_null text_null no_default; do
    report "SHOW $column" "SQL-NULL" "$(show_default "$column")"
done
report "SHOW string_null" "NULL" "$(show_default string_null)"
report "SHOW string_abc" "abc" "$(show_default string_abc)"
report "SHOW string_empty" "" "$(show_default string_empty)"
report "catalog no_default" "SQL-NULL" "$(catalog_default no_default)"

if [ "$CATALOG_QUOTES" = 1 ]; then
    for column in implicit_null explicit_null text_null; do
        report "catalog $column" "$(hex "NULL")" "$(catalog_default "$column")"
    done
    report "catalog string_null" "$(hex "'NULL'")" "$(catalog_default string_null)"
    report "catalog string_abc" "$(hex "'abc'")" "$(catalog_default string_abc)"
    report "catalog string_empty" "$(hex "''")" "$(catalog_default string_empty)"
else
    for column in implicit_null explicit_null text_null; do
        report "catalog $column" "SQL-NULL" "$(catalog_default "$column")"
    done
    report "catalog string_null" "$(hex "NULL")" "$(catalog_default string_null)"
    report "catalog string_abc" "$(hex "abc")" "$(catalog_default string_abc)"
fi

if [ "$HAS_EXPRESSION_DEFAULT" = 0 ]; then
    echo "skip  expression defaults: $VERSION predates them"
elif [ "$IS_MARIADB" = 1 ]; then
    [ "$CATALOG_QUOTES" = 1 ] && report "catalog expression" "$(hex "uuid()")" "$(catalog_default expression)"
    report "SHOW expression" "uuid()" "$(show_default expression)"
    report "extra expression" "" "$(extra_of expression)"
    report "SHOW CREATE expression" "uuid()" "$(create_default expression)"
else
    report "catalog expression" "$(hex "concat(_utf8mb4\\'a\\',_utf8mb4\\'b\\')")" \
        "$(catalog_default expression)"
    report "extra expression" "DEFAULT_GENERATED" "$(extra_of expression)"
    report "SHOW CREATE expression" "(concat(_utf8mb4'a',_utf8mb4'b'))" "$(create_default expression)"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures disagreement(s) with MySQLCatalogDefault.swift"
    exit 1
fi
echo "every answer matches MySQLCatalogDefault.swift"
