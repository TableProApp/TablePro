#!/usr/bin/env bash
#
# Check the row update form the ClickHouse driver writes for an import, a data sync and Copy as UPDATE.
#
# ClickHousePluginDriver.rowUpdateStatement writes `ALTER TABLE ... UPDATE ... WHERE ...` with
# `SETTINGS mutations_sync = 1`, because a plain `UPDATE ... SET` needs a table with lightweight
# updates enabled, and a mutation sent without the setting returns before it applies, so the next
# read sees the old row and a failure stays queued with nothing reported. This checks all three on
# a throwaway MergeTree table.
#
# Usage:
#   scripts/probes/check-clickhouse-row-updates.sh [url] [user]
#
# Needs curl. The password, if any, comes from CLICKHOUSE_PASSWORD. Exits 0 when the server behaves
# as the driver expects, 1 when it does not, and 3 when the check could not run.

set -uo pipefail

URL="${1:-http://127.0.0.1:8123}"
USER_NAME="${2:-default}"
TABLE="tablepro_probe_row_updates"

CREDENTIALS="$USER_NAME:${CLICKHOUSE_PASSWORD:-}"
CREDENTIALS="${CREDENTIALS//\\/\\\\}"
CREDENTIALS="${CREDENTIALS//\"/\\\"}"
ask() {
    printf 'user = "%s"\n' "$CREDENTIALS" | curl -sS --max-time 120 --config - "$@"
}

VERSION="$(ask "$URL/" --data-binary "SELECT version()")" || {
    echo "no ClickHouse at $URL for $USER_NAME" >&2
    exit 3
}

cleanup() {
    ask "$URL/" --data-binary "KILL MUTATION WHERE database = currentDatabase() AND table = '$TABLE' SYNC" > /dev/null 2>&1
    ask "$URL/" --data-binary "DROP TABLE IF EXISTS $TABLE" > /dev/null 2>&1
}
trap cleanup EXIT
cleanup

# A wide enough table that a mutation does not finish before the next request.
ask "$URL/" --data-binary "CREATE TABLE $TABLE (id UInt64, name String, n UInt8, pad String) ENGINE = MergeTree ORDER BY id" > /dev/null || exit 3
ask "$URL/" --data-binary "INSERT INTO $TABLE SELECT number, 'a', 0, randomPrintableASCII(100) FROM numbers(5000000)" > /dev/null || exit 3

name_of() {
    ask "$URL/" --data-binary "SELECT name FROM $TABLE WHERE id = $1"
}

PLAIN="$(ask "$URL/" --data-binary "UPDATE $TABLE SET name = 'b' WHERE id = 1" 2>&1)"
case "$PLAIN" in
    *"Code: "*) PLAIN_RESULT="refused" ;;
    *) PLAIN_RESULT="accepted" ;;
esac

ask "$URL/" --data-binary "ALTER TABLE $TABLE UPDATE name = 'c' WHERE id = 2" > /dev/null
UNWAITED="$(name_of 2)"

ask "$URL/" --data-binary "ALTER TABLE $TABLE UPDATE name = 'd' WHERE id = 3 SETTINGS mutations_sync = 1" > /dev/null
WAITED="$(name_of 3)"

# toUInt8(name) fails only while the mutation runs, so the ALTER itself is accepted.
FAILED="$(ask "$URL/" --data-binary "ALTER TABLE $TABLE UPDATE n = toUInt8(name) WHERE id = 4 SETTINGS mutations_sync = 1" 2>&1)"
case "$FAILED" in
    *"Code: 341"*) FAILED_RESULT="reported" ;;
    *) FAILED_RESULT="silent" ;;
esac

echo "server: $VERSION"
echo "plain UPDATE on a MergeTree table: $PLAIN_RESULT (driver expects refused)"
echo "row read right after an unwaited mutation: $UNWAITED (driver expects a, the old value)"
echo "row read right after a waited mutation: $WAITED (driver expects d)"
echo "waited mutation that fails: $FAILED_RESULT (driver expects reported)"

STATUS=0
[ "$PLAIN_RESULT" = "refused" ] || STATUS=1
[ "$WAITED" = "d" ] || STATUS=1
[ "$FAILED_RESULT" = "reported" ] || STATUS=1
exit "$STATUS"
