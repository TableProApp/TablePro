#!/usr/bin/env bash
#
# Check the server facts ClickHouseRowWrites rests on: how a grid edit or delete reaches exactly the row it was
# made on (#3776).
#
# A ClickHouse table has no key that names a row: the primary key is the sorting key and repeats. The writer matches
# every value the grid loaded, a lookup right before the write has to find exactly that many rows, the write is
# pinned to the parts they were found in, and a check after it finds a write that landed nowhere. This runs the
# statements in the shapes ClickHouseDMLStatementTests pins, on a throwaway MergeTree table, with the driver's
# {pN:String} parameters.
#
# Usage:
#   scripts/probes/check-clickhouse-row-identity.sh [url] [user]
#
# Needs curl 7.87 or later. The password, if any, comes from CLICKHOUSE_PASSWORD. Exits 0 when the server behaves as
# the writer expects, 1 when it does not, and 3 when the check could not run.

set -uo pipefail

URL="${1:-http://127.0.0.1:8123}"
USER_NAME="${2:-default}"
TABLE="tablepro_probe_row_identity"

CREDENTIALS="$USER_NAME:${CLICKHOUSE_PASSWORD:-}"
CREDENTIALS="${CREDENTIALS//\\/\\\\}"
CREDENTIALS="${CREDENTIALS//\"/\\\"}"

# ask SQL [value...]: the values bind to {p1:String}, {p2:String}, ... in order.
ask() {
    local sql="$1" index=0 value
    shift
    local query=()
    for value in "$@"; do
        index=$((index + 1))
        query+=(--url-query "param_p$index=$value")
    done
    printf 'user = "%s"\n' "$CREDENTIALS" | curl -sS --max-time 120 --config - "$URL/" ${query[@]+"${query[@]}"} --data-binary "$sql"
}

VERSION="$(ask "SELECT version()")" || {
    echo "no ClickHouse at $URL for $USER_NAME" >&2
    exit 3
}

cleanup() {
    ask "DROP TABLE IF EXISTS $TABLE" > /dev/null 2>&1
}
trap cleanup EXIT
cleanup

ask "CREATE TABLE $TABLE (d Date, id UInt32, v String, doc JSON, f Float64) ENGINE = MergeTree ORDER BY d" > /dev/null || exit 3

reset() {
    ask "TRUNCATE TABLE $TABLE" > /dev/null
    ask "INSERT INTO $TABLE VALUES ('2026-01-01', 1, 'a', '{\"k\":1}', 0.1), ('2026-01-01', 2, 'b', '{}', nan)" > /dev/null
    ask "INSERT INTO $TABLE VALUES ('2026-01-01', 3, 'c', '{}', 1), ('2026-01-01', 3, 'c', '{}', 1)" > /dev/null
}

MATCH='`d` = {p1:String} AND `id` = {p2:String} AND `v` = {p3:String} AND toString(`doc`) = {p4:String} AND toString(`f`) = {p5:String}'
ROW_ONE=(2026-01-01 1 a '{"k":1}' 0.1)
ROW_TWIN=(2026-01-01 3 c '{}' 1)
STATUS=0
report() {
    echo "$1: $2 (writer expects $3)"
    [ "$2" = "$3" ] || STATUS=1
}

reset
report "lookup for a row sharing its sorting key with others" \
    "$(ask "SELECT count() FROM (SELECT _part FROM $TABLE WHERE $MATCH LIMIT 2)" "${ROW_ONE[@]}")" 1
report "lookup for one of two identical rows" \
    "$(ask "SELECT count() FROM (SELECT _part FROM $TABLE WHERE $MATCH LIMIT 2)" "${ROW_TWIN[@]}")" 2
report "row with NaN found by its text" \
    "$(ask "SELECT count() FROM $TABLE WHERE id = 2 AND toString(f) = {p1:String}" nan)/$(ask "SELECT count() FROM $TABLE WHERE id = 2 AND f = {p1:String}" nan)" 1/0
report "row with JSON found by its text" \
    "$(ask "SELECT count() FROM $TABLE WHERE id = 1 AND toString(doc) = {p1:String}" '{"k":1}')/$(ask "SELECT count() FROM $TABLE WHERE id = 1 AND doc = {p1:String}" '{"k":1}')" 1/0

PART="$(ask "SELECT _part FROM $TABLE WHERE $MATCH LIMIT 2" "${ROW_ONE[@]}")"
ask "ALTER TABLE $TABLE UPDATE \`v\` = {p6:String} WHERE $MATCH AND _part IN ({p7:String}) SETTINGS mutations_sync = 1" \
    "${ROW_ONE[@]}" z "$PART" > /dev/null
report "rows changed by a pinned update, by id" "$(ask "SELECT groupArray(id) FROM (SELECT id FROM $TABLE WHERE v = 'z' ORDER BY id)")" "[1]"
report "check after that update" \
    "$(ask "SELECT count() FROM $TABLE WHERE $MATCH AND NOT ifNull(\`v\` = {p6:String}, 0)" "${ROW_ONE[@]}" z)" 0
report "the part row 1 was found in still names it after the update" \
    "$(ask "SELECT _part = {p1:String} FROM $TABLE WHERE id = 1" "$PART")" 0

PARTS=()
while IFS= read -r part; do PARTS+=("$part"); done < <(ask "SELECT _part FROM $TABLE WHERE $MATCH LIMIT 3" "${ROW_TWIN[@]}")
report "lookup for both identical rows, asking for one more" "${#PARTS[@]}" 2
ask "ALTER TABLE $TABLE DELETE WHERE $MATCH AND _part IN ({p6:String}, {p7:String}) SETTINGS mutations_sync = 1" \
    "${ROW_TWIN[@]}" "${PARTS[@]}" > /dev/null
report "rows left after deleting both identical rows, by id" "$(ask "SELECT groupArray(id) FROM (SELECT id FROM $TABLE ORDER BY id)")" "[1,2]"

reset
ask "INSERT INTO $TABLE VALUES ('2026-02-02', 9, 'q', '{}', 2)" > /dev/null
ROW_NINE=(2026-02-02 9 q '{}' 2)
PART="$(ask "SELECT _part FROM $TABLE WHERE $MATCH LIMIT 2" "${ROW_NINE[@]}")"
ask "OPTIMIZE TABLE $TABLE FINAL" > /dev/null
ask "ALTER TABLE $TABLE UPDATE \`v\` = {p6:String} WHERE $MATCH AND _part IN ({p7:String}) SETTINGS mutations_sync = 1" \
    "${ROW_NINE[@]}" moved "$PART" > /dev/null
report "update pinned to a part a merge replaced, rows changed" "$(ask "SELECT count() FROM $TABLE WHERE v = 'moved'")" 0
report "check after that update" \
    "$(ask "SELECT count() FROM $TABLE WHERE $MATCH AND NOT ifNull(\`v\` = {p6:String}, 0)" "${ROW_NINE[@]}" moved)" 1

PART="$(ask "SELECT _part FROM $TABLE WHERE $MATCH LIMIT 2" "${ROW_NINE[@]}")"
ask "DELETE FROM $TABLE WHERE $MATCH AND _part IN ({p6:String})" "${ROW_NINE[@]}" "$PART" > /dev/null
report "rows left after a pinned lightweight delete" "$(ask "SELECT count() FROM $TABLE")" 4

echo "server: $VERSION"
exit "$STATUS"
