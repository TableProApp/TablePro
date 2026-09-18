#!/usr/bin/env bash
#
# Compare the curated MySQL autocommit-only variable table against a real server.
#
# MySQLAutocommitOnlyVariables lists the system variables MySQL and MariaDB refuse to set while a
# transaction is open, keyed by scope. A batch holding one of those statements runs without the
# app's transaction; a variable missing from the table leaves the batch wrapped and the statement
# fails with ERROR 1694, 1766, 1192 or 1179. The table is hand written and nothing at runtime
# checks it, which is how seven MySQL 8.4 variables went missing at once.
#
# This asks the server for every variable it has, tries each one twice (once in autocommit, once
# inside a transaction) and reports both directions: a variable the server refuses that the table
# does not list, and a variable the table lists that the server takes. A variable the server
# refuses in both runs is not a transaction rule at all (read only, wrong scope, no privilege) and
# is skipped.
#
# The table is the union of what MySQL and MariaDB refuse, and one server can only answer for
# itself: measured on MariaDB 12.3.3, explicit_defaults_for_timestamp and pseudo_slave_mode are
# taken inside a transaction, while MySQL 8.4.11 answers ERROR 1766 for both. So check a reported
# entry against the other engine before removing it, and run this with an account that holds
# SYSTEM_VARIABLES_ADMIN (or MariaDB's BINLOG ADMIN and REPLICATION SLAVE ADMIN), or every binlog
# and GTID variable is refused for want of a privilege and measures nothing.
#
# Usage:
#   scripts/check-mysql-autocommit-only-variables.sh [host] [port] [user]
#
# Needs the mysql client and a MySQL 8 or MariaDB 10.5+ server. The password, if any, comes from
# MYSQL_PWD. Point it at a scratch server: each probe assigns a variable its own current value, at
# global scope as well as session scope. Exits non-zero on a disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-root}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/TablePro/Core/Services/Execution/MySQLAutocommitOnlyVariables.swift"
BLOCK_LINES=5

command -v mysql > /dev/null || {
    echo "mysql client not found" >&2
    exit 3
}

[ -f "$SOURCE" ] || {
    echo "no curated table at $SOURCE" >&2
    exit 3
}

MYSQL=(mysql --no-defaults -h "$HOST" -P "$PORT" -u "$USER_NAME" -N -B -r --default-character-set=utf8mb4)
if ! "${MYSQL[@]}" -e "SELECT 1" > /dev/null 2>&1; then
    echo "no MySQL at $HOST:$PORT for $USER_NAME" >&2
    exit 3
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The curated table, one "name<TAB>scope" line per entry, lowercased to match the server.
sed -n 's/^ *"\([A-Z0-9_]*\)": \[\([^]]*\)\].*$/\1 \2/p' "$SOURCE" | tr -d ',' |
    while read -r NAME SCOPES; do
        for SCOPE in $SCOPES; do
            printf '%s\t%s\n' "$NAME" "${SCOPE#.}"
        done
    done | tr '[:upper:]' '[:lower:]' | sort > "$WORK/curated.tsv"

[ -s "$WORK/curated.tsv" ] || {
    echo "the curated table parsed to nothing: check the literal in $SOURCE" >&2
    exit 3
}

# A server with performance_schema turned off answers the modern table with no rows and no error,
# so the fallback has to key off the rows rather than off the exit status.
variables_in() {
    local table="$1"
    local legacy names
    legacy="$(echo "$table" | tr '[:lower:]' '[:upper:]')"
    names="$("${MYSQL[@]}" -e "SELECT LOWER(VARIABLE_NAME) FROM performance_schema.$table" 2> /dev/null)"
    [ -n "$names" ] ||
        names="$("${MYSQL[@]}" -e "SELECT LOWER(VARIABLE_NAME) FROM information_schema.$legacy" 2> /dev/null)"
    printf '%s\n' "$names"
}

: > "$WORK/pairs.tsv"
for SCOPE in session global; do
    VARIABLES="$(variables_in "${SCOPE}_variables")"
    [ -n "$VARIABLES" ] || {
        echo "the server listed no $SCOPE variables" >&2
        exit 3
    }
    while read -r NAME; do
        [ -n "$NAME" ] || continue
        printf '%s\t%s\n' "$NAME" "$SCOPE" >> "$WORK/pairs.tsv"
    done <<< "$VARIABLES"
done

# Five lines per pair: the autocommit probe, then the same assignment inside a transaction. An
# error on the first line means the server refuses the assignment whatever the transaction is
# doing, which is not what this table is about.
: > "$WORK/probe.sql"
while IFS=$'\t' read -r NAME SCOPE; do
    {
        echo "SET @@$SCOPE.$NAME = @@$SCOPE.$NAME;"
        echo "START TRANSACTION;"
        echo "DO 1;"
        echo "SET @@$SCOPE.$NAME = @@$SCOPE.$NAME;"
        echo "ROLLBACK;"
    } >> "$WORK/probe.sql"
done < "$WORK/pairs.tsv"

"${MYSQL[@]}" --force < "$WORK/probe.sql" > /dev/null 2> "$WORK/errors.txt"

# "ERROR 1766 (HY000) at line 4: ..." -> "4 1766"
sed -n 's/^ERROR \([0-9]*\) ([^)]*) at line \([0-9]*\):.*$/\2 \1/p' "$WORK/errors.txt" | sort -n -u > "$WORK/errors.tsv"

awk -v blockLines="$BLOCK_LINES" '
    NR == FNR { failed[$1] = $2; next }
    {
        first = (FNR - 1) * blockLines + 1
        inTransaction = first + 3
        state = "allowed"
        if (inTransaction in failed) {
            state = (first in failed) ? "skipped" : "refused"
        }
        printf "%s\t%s\t%s\n", $1, $2, state
    }
' "$WORK/errors.tsv" "$WORK/pairs.tsv" | sort > "$WORK/probed.tsv"

awk -F'\t' '$3 == "refused" { print $1 "\t" $2 }' "$WORK/probed.tsv" | sort > "$WORK/refused.tsv"
awk -F'\t' '$3 == "allowed" { print $1 "\t" $2 }' "$WORK/probed.tsv" | sort > "$WORK/allowed.tsv"
cut -f1,2 "$WORK/probed.tsv" | sort > "$WORK/known.tsv"

comm -23 "$WORK/refused.tsv" "$WORK/curated.tsv" > "$WORK/missing.tsv"
comm -12 "$WORK/curated.tsv" "$WORK/allowed.tsv" > "$WORK/stale.tsv"
comm -23 "$WORK/curated.tsv" "$WORK/known.tsv" > "$WORK/absent.tsv"

while IFS=$'\t' read -r NAME SCOPE; do
    [ -n "$NAME" ] && echo "not on this server, so unchecked: $NAME $SCOPE"
done < "$WORK/absent.tsv"

FAILURES=0
while IFS=$'\t' read -r NAME SCOPE; do
    [ -n "$NAME" ] || continue
    echo "missing from the table: $NAME $SCOPE is refused inside a transaction"
    FAILURES=$((FAILURES + 1))
done < "$WORK/missing.tsv"

while IFS=$'\t' read -r NAME SCOPE; do
    [ -n "$NAME" ] || continue
    echo "stale in the table: $NAME $SCOPE is allowed inside a transaction on this server"
    FAILURES=$((FAILURES + 1))
done < "$WORK/stale.tsv"

echo "probed $(wc -l < "$WORK/pairs.tsv" | tr -d ' ') variable scopes, $(wc -l < "$WORK/refused.tsv" | tr -d ' ') refused"
[ "$FAILURES" -eq 0 ] && echo "OK" || echo "$FAILURES disagreements"
exit $((FAILURES == 0 ? 0 : 1))
