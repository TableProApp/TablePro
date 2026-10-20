#!/usr/bin/env bash
#
# Check that a grid save writes ENUM and SET values to a live MySQL or MariaDB server and that they read back.
#
# The save sends what SQLStatementGenerator writes for MySQL, `UPDATE `t` SET `c` = ? WHERE `id` = ?` on a keyed
# table and a match on every column on a keyless one, as a prepared statement whose values are bound as text
# (MariaDBPluginConnection binds MYSQL_TYPE_STRING). This runs the same statements through PREPARE and EXECUTE
# USING, then reads each cell back: one ENUM value, several SET members, an empty SET, NULL, and a value with a
# quote. The SET editor commits its members comma-joined in declared order, and an empty selection as ''.
#
# Usage:
#   scripts/probes/check-mysql-enum-set-save.sh [host] [port] [user]
#
# Needs the mysql client and an account that may create and drop a database. The password, if any, comes from
# MYSQL_PWD. Exits non-zero on a disagreement and 3 when no server answers.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-root}"
DATABASE="tablepro_enum_set_check_$$"

command -v mysql > /dev/null || {
    echo "mysql client not found" >&2
    exit 3
}

MYSQL=(mysql --no-defaults -h "$HOST" -P "$PORT" -u "$USER_NAME" -N -B --default-character-set=utf8mb4)
VERSION="$("${MYSQL[@]}" -e "SELECT VERSION()" 2> /dev/null)" || {
    echo "no MySQL at $HOST:$PORT for $USER_NAME" >&2
    exit 3
}
echo "server $VERSION"

"${MYSQL[@]}" -e "CREATE DATABASE \`$DATABASE\`" || exit 3
trap '"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`$DATABASE\`"' EXIT

"${MYSQL[@]}" "$DATABASE" -e "
    CREATE TABLE keyed (
        id INT PRIMARY KEY,
        e ENUM('small', 'large', 'it''s') NULL,
        s SET('red', 'green', 'blue', 'it''s') NULL
    );
    CREATE TABLE keyless (
        e ENUM('small', 'large', 'it''s') NULL,
        s SET('red', 'green', 'blue', 'it''s') NULL
    );
    INSERT INTO keyed VALUES (1, 'small', 'red');" || exit 1

failures=0

report() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok    $label"
    else
        echo "FAIL  $label: expected $expected, got $actual"
        failures=$((failures + 1))
    fi
}

hex() {
    printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F'
}

# A bound value as a user variable: NULL stays SQL NULL, text becomes a literal with its quotes doubled.
bind() {
    local quote="'"
    if [ "$1" = NULL ]; then
        printf 'NULL'
    else
        printf "'%s'" "${1//$quote/$quote$quote}"
    fi
}

expected_cell() {
    if [ "$1" = NULL ]; then printf 'SQL-NULL'; else hex "$1"; fi
}

# The statements run in one session, as the save runs them, and ROW_COUNT() reports what EXECUTE matched.
run() {
    "${MYSQL[@]}" "$DATABASE" -e "$1"
}

read_keyed() {
    run "SELECT CONCAT(IFNULL(HEX(e), 'SQL-NULL'), ' ', IFNULL(HEX(s), 'SQL-NULL')) FROM keyed WHERE id = 1"
}

keyed_update() {
    local label="$1" enum_value="$2" set_value="$3" stored_set="$4"
    run "SET @e = $(bind "$enum_value"), @s = $(bind "$set_value"), @id = 1;
         PREPARE w FROM 'UPDATE \`keyed\` SET \`e\` = ?, \`s\` = ? WHERE \`id\` = ?';
         EXECUTE w USING @e, @s, @id;" > /dev/null 2>&1 || {
        report "$label" "saved" "refused"
        return
    }
    report "$label" "$(expected_cell "$enum_value") $(expected_cell "$stored_set")" "$(read_keyed)"
}

keyed_update "one ENUM value and one SET member" large green green
keyed_update "several SET members in declared order" small 'red,blue' 'red,blue'
keyed_update "SET members typed out of order are stored in declared order" small 'blue,red' 'red,blue'
keyed_update "an empty SET is an empty string, not NULL" large '' ''
keyed_update "NULL in both" NULL NULL NULL
keyed_update "a value with a quote" "it's" "red,it's" "red,it's"

undeclared="$(run "SET @e = 'purple', @id = 1;
    PREPARE w FROM 'UPDATE \`keyed\` SET \`e\` = ? WHERE \`id\` = ?';
    EXECUTE w USING @e, @id;" 2>&1)"
case "$undeclared" in
    *1265*) report "an undeclared ENUM value is refused, not stored as ''" refused refused ;;
    *) report "an undeclared ENUM value is refused, not stored as ''" refused "${undeclared:-saved}" ;;
esac

# A keyless row is matched on every column, `IS NULL` for a NULL, and held to one row.
keyless_case() {
    local label="$1" enum_value="$2" set_value="$3"
    run "DELETE FROM keyless; INSERT INTO keyless VALUES ($(bind "$enum_value"), $(bind "$set_value"))" > /dev/null
    local e_match="\`e\` = ?" s_match="\`s\` = ?" using=()
    if [ "$enum_value" = NULL ]; then e_match="\`e\` IS NULL"; else using+=("@oe"); fi
    if [ "$set_value" = NULL ]; then s_match="\`s\` IS NULL"; else using+=("@os"); fi
    local update_using="@n" delete_using=""
    for variable in ${using[@]+"${using[@]}"}; do
        update_using="$update_using, $variable"
        delete_using="${delete_using:+$delete_using, }$variable"
    done
    local prefix="SET @n = 'large', @oe = $(bind "$enum_value"), @os = $(bind "$set_value");"
    local updated deleted
    updated="$(run "$prefix
        PREPARE w FROM 'UPDATE \`keyless\` SET \`e\` = ? WHERE $e_match AND $s_match';
        EXECUTE w USING $update_using; SELECT ROW_COUNT();")"
    report "$label: the update finds the row" 1 "$updated"
    run "UPDATE keyless SET e = $(bind "$enum_value")" > /dev/null
    if [ -n "$delete_using" ]; then
        deleted="$(run "$prefix
            PREPARE d FROM 'DELETE FROM \`keyless\` WHERE ($e_match AND $s_match)';
            EXECUTE d USING $delete_using; SELECT ROW_COUNT();")"
    else
        deleted="$(run "DELETE FROM \`keyless\` WHERE ($e_match AND $s_match); SELECT ROW_COUNT();")"
    fi
    report "$label: the delete finds the row" 1 "$deleted"
}

keyless_case "keyless, one value each" small green
keyless_case "keyless, several SET members" small 'red,blue'
keyless_case "keyless, an empty SET" small ''
keyless_case "keyless, NULL" NULL NULL
keyless_case "keyless, a value with a quote" "it's" "it's"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
