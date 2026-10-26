#!/usr/bin/env bash
#
# Check the routine and event catalog reads the MySQL driver emits.
#
# MySQL 5.7 and earlier and MariaDB fill information_schema.ROUTINES, PARAMETERS and EVENTS from every
# database and compare the schema name case-insensitively, so under lower_case_table_names = 0 a read
# of `tp_rc_x` also answers about `TP_RC_X`. The driver adds a byte comparison there
# (MySQLObjectQueries.schemaMatch). MariaDB also lists a package as PACKAGE and PACKAGE BODY rows,
# which the routine list leaves out. This builds both cases and fails if a read the driver emits
# answers about another database or lists a package.
#
# Usage:
#   scripts/probes/check-mysql-routine-catalog.sh [host] [port] [user]
#
# Needs the mysql client and an account that can create and drop databases. The password, if any,
# comes from MYSQL_PWD. Exits non-zero on a disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-root}"

SUFFIX="$$_${RANDOM}"
LOWER_DB="tp_rc_$SUFFIX"
UPPER_DB="TP_RC_$SUFFIX"

command -v mysql > /dev/null || {
    echo "mysql client not found" >&2
    exit 3
}

MYSQL=(mysql --no-defaults -h "$HOST" -P "$PORT" -u "$USER_NAME" -N -B -r --default-character-set=utf8mb4)
if ! "${MYSQL[@]}" -e "SELECT 1" > /dev/null 2>&1; then
    echo "no MySQL-protocol server at $HOST:$PORT for $USER_NAME" >&2
    exit 3
fi

LCTN=$("${MYSQL[@]}" -e "SELECT @@lower_case_table_names")
echo "server: $("${MYSQL[@]}" -e "SELECT VERSION()"), lower_case_table_names = $LCTN"

"${MYSQL[@]}" -e "CREATE DATABASE \`$LOWER_DB\`" || {
    echo "could not create the scratch database" >&2
    exit 3
}
DATABASES=("$LOWER_DB")
drop_fixture() {
    for db in "${DATABASES[@]}"; do
        "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS \`$db\`" > /dev/null 2>&1
    done
}
trap drop_fixture EXIT

"${MYSQL[@]}" -e "
    CREATE PROCEDURE \`$LOWER_DB\`.only_lower(IN a INT) BEGIN END;
    CREATE PROCEDURE \`$LOWER_DB\`.shared(IN a INT) BEGIN END;
" || exit 3

if [[ "$LCTN" == "0" ]]; then
    "${MYSQL[@]}" -e "CREATE DATABASE \`$UPPER_DB\`" || exit 3
    DATABASES+=("$UPPER_DB")
    "${MYSQL[@]}" -e "
        CREATE PROCEDURE \`$UPPER_DB\`.shared(IN z DATE, IN y DATE) BEGIN END;
        CREATE PROCEDURE \`$UPPER_DB\`.only_upper(IN z DATE) BEGIN END;
        CREATE EVENT \`$UPPER_DB\`.ev_upper ON SCHEDULE EVERY 1 DAY DISABLE DO SELECT 1;
    " || exit 3
fi

PACKAGE_MADE=0
if "${MYSQL[@]}" -e "
    SET SESSION sql_mode = 'ORACLE';
    DELIMITER \$\$
    CREATE PACKAGE \`$LOWER_DB\`.pkg AS PROCEDURE p(b INT); END\$\$
" > /dev/null 2>&1; then
    PACKAGE_MADE=1
fi

# The byte comparison is added only where the server keeps the two spellings apart.
schema_match() {
    local column="$1"
    if [[ "$LCTN" == "0" ]]; then
        echo "$column = '$LOWER_DB' AND CAST($column AS BINARY) = CAST('$LOWER_DB' AS BINARY)"
    else
        echo "$column = '$LOWER_DB'"
    fi
}

failures=0
expect() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        echo "ok    $label"
    else
        echo "FAIL  $label: expected [$want], got [$got]"
        failures=$((failures + 1))
    fi
}

routines=$("${MYSQL[@]}" -e "
    SELECT ROUTINE_NAME FROM information_schema.ROUTINES
    WHERE $(schema_match ROUTINE_SCHEMA) AND ROUTINE_TYPE IN ('PROCEDURE', 'FUNCTION')
    ORDER BY ROUTINE_TYPE, ROUTINE_NAME" | paste -sd, -)
expect "routine list names only its own database's routines" "only_lower,shared" "$routines"

parameters=$("${MYSQL[@]}" -e "
    SELECT CONCAT(SPECIFIC_NAME, ' ', PARAMETER_NAME) FROM information_schema.PARAMETERS
    WHERE $(schema_match SPECIFIC_SCHEMA) AND ORDINAL_POSITION > 0
    ORDER BY SPECIFIC_SCHEMA, ROUTINE_TYPE, SPECIFIC_NAME, ORDINAL_POSITION" | paste -sd, -)
expect "parameter read names only its own database's parameters" "only_lower a,shared a" "$parameters"

events=$("${MYSQL[@]}" -e "
    SELECT COUNT(*) FROM information_schema.EVENTS WHERE $(schema_match EVENT_SCHEMA)")
expect "event list names only its own database's events" "0" "$events"

if [[ "$LCTN" == "0" ]]; then
    folded=$("${MYSQL[@]}" -e "
        SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$LOWER_DB'")
    echo "note  without the byte comparison the routine catalog answers $folded rows for 2 routines"
fi

if [[ "$PACKAGE_MADE" == "1" ]]; then
    packages=$("${MYSQL[@]}" -e "
        SELECT COUNT(*) FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA = '$LOWER_DB' AND ROUTINE_TYPE LIKE 'PACKAGE%'")
    expect "the catalog lists the package as its own rows" "1" "$packages"
else
    echo "note  no CREATE PACKAGE on this server, package check skipped"
fi

exit $((failures > 0))
