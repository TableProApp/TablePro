#!/usr/bin/env bash
#
# Check how a ClickHouse server takes long values over HTTP, which decides how the driver sends bound values (#3777).
#
# ClickHouseParameterBinding sends short values as `param_` URL items and writes a statement's values into it once
# they no longer fit, cast to String inside INSERT data; the statement travels in the POST body. A `param_` item over
# http_max_field_value_size (128 KiB, counted percent-encoded) is refused, in the URL and in a multipart form alike,
# and both URL limits come from the server's own profile. A value in the statement counts against max_query_size,
# which the driver raises for that request; INSERT data is not parsed against it. In VALUES a bare literal goes to the
# column's own parser, which stores a braced UUID as a different one, so the cast keeps a String parameter's meaning
# there. A `+` left unencoded in the URL arrives as a space. ClickHousePluginDriver.escapeStringLiteral writes only the
# escapes the server decodes. This checks each of those on a throwaway table.
#
# Usage:
#   scripts/probes/check-clickhouse-long-values.sh [url] [user]
#
# Needs curl 7.87 or later. The password, if any, comes from CLICKHOUSE_PASSWORD. Exits 0 when the server behaves as
# the driver expects, 1 when it does not, and 3 when the check could not run.

set -uo pipefail

URL="${1:-http://127.0.0.1:8123}"
USER_NAME="${2:-default}"
TABLE="tablepro_probe_long_values"

CREDENTIALS="$USER_NAME:${CLICKHOUSE_PASSWORD:-}"
CREDENTIALS="${CREDENTIALS//\\/\\\\}"
CREDENTIALS="${CREDENTIALS//\"/\\\"}"
ask() {
    printf 'user = "%s"\n' "$CREDENTIALS" | curl -sS --max-time 120 --config - "$@"
}
status_of() {
    ask -o /dev/null -w '%{http_code}' "$@"
}

VERSION="$(ask "$URL/" --data-binary "SELECT version()")" || {
    echo "no ClickHouse at $URL for $USER_NAME" >&2
    exit 3
}

WORK="$(mktemp -d)" || exit 3
cleanup() {
    ask "$URL/" --data-binary "DROP TABLE IF EXISTS $TABLE" > /dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT
cleanup
mkdir -p "$WORK"

ask "$URL/" --data-binary "CREATE TABLE $TABLE (id UInt8, u UInt64, dt DateTime, arr Array(UInt8), ni Nullable(Int32), s String, uid UUID) ENGINE = MergeTree ORDER BY id" > /dev/null || exit 3

repeat() {
    head -c "$2" /dev/zero | tr '\0' "$1"
}

repeat x 200000 > "$WORK/value"
URL_PARAM="$(status_of -G "$URL/" --data-urlencode "query=SELECT length({v:String})" --data-urlencode "param_v@$WORK/value")"
FORM_PARAM="$(status_of "$URL/?query=SELECT%20length(%7Bv:String%7D)" -F "param_v=<$WORK/value")"

{ printf "INSERT INTO %s (id, s) VALUES (1, '" "$TABLE"; repeat y 2000000; printf "')"; } > "$WORK/insert"
ask "$URL/" --data-binary "@$WORK/insert" > /dev/null
INSERTED="$(ask "$URL/" --data-binary "SELECT length(s) FROM $TABLE WHERE id = 1")"

{ printf "ALTER TABLE %s UPDATE s = '" "$TABLE"; repeat z 300000; printf "' WHERE id = 1 SETTINGS mutations_sync = 1"; } > "$WORK/update"
UPDATE_BYTES="$(wc -c < "$WORK/update" | tr -d ' ')"
DEFAULT_LIMIT="$(status_of "$URL/" --data-binary "@$WORK/update")"
SIZED="$(status_of "$URL/?max_query_size=$UPDATE_BYTES" --data-binary "@$WORK/update")"
ONE_SHORT="$(status_of "$URL/?max_query_size=$((UPDATE_BYTES - 1))" --data-binary "@$WORK/update")"
UPDATED="$(ask "$URL/" --data-binary "SELECT length(s) FROM $TABLE WHERE id = 1")"

SUB_ESCAPE="$(ask "$URL/" --data-binary "SELECT hex('\\Z')")"
ESCAPES="$(ask "$URL/" --data-binary "SELECT hex('a''b\\\\c\\0\\b\\f\\n\\r\\t')")"

cast() {
    printf "CAST('%s' AS String)" "$1"
}
ROW="$(cast 18446744073709551615), $(cast '2024-02-29 12:34:56'), $(cast '[1,2,3]'), $(cast 7), $(cast "it''s")"
ask "$URL/" --data-binary "INSERT INTO $TABLE (id, u, dt, arr, ni, s) VALUES (2, $ROW), (3, $ROW)" > /dev/null
PARAMS="{u:String}, {dt:String}, {arr:String}, {ni:String}, {s:String}"
ask "$URL/" --url-query "param_u=18446744073709551615" --url-query "param_dt=2024-02-29 12:34:56" \
    --url-query "param_arr=[1,2,3]" --url-query "param_ni=7" --url-query "param_s=it's" \
    --data-binary "INSERT INTO $TABLE (id, u, dt, arr, ni, s) VALUES (4, $PARAMS), (5, $PARAMS)" > /dev/null
DISTINCT="$(ask "$URL/" --data-binary "SELECT count(DISTINCT (u, dt, arr, ni, s)), count() FROM $TABLE WHERE id BETWEEN 2 AND 5 FORMAT CSV")"

PLUS_RAW="$(ask "$URL/?param_v=a+b" --data-binary "SELECT {v:String}")"
PLUS_ENCODED="$(ask "$URL/?param_v=a%2Bb" --data-binary "SELECT {v:String}")"
ENCODED_LIMIT="$(status_of "$URL/" --url-query "param_v=$(repeat x 40000 | sed 's/x/€/g')" --data-binary "SELECT length({v:String})")"

BRACED="{6f9619ff-8b86-d011-b42d-00c04fc964ff}"
BARE_UUID="$(status_of "$URL/" --data-binary "INSERT INTO $TABLE (id, uid) VALUES (6, '$BRACED')")"
CAST_UUID="$(status_of "$URL/" --data-binary "INSERT INTO $TABLE (id, uid) VALUES (7, $(cast "$BRACED"))")"
PARAM_UUID="$(status_of "$URL/" --url-query "param_v=$BRACED" --data-binary "INSERT INTO $TABLE (id, uid) VALUES (8, {v:String})")"

echo "server: $VERSION"
echo "200,000-byte param_ in the URL: HTTP $URL_PARAM (driver expects 500, Field value too long)"
echo "200,000-byte param_ as a form field: HTTP $FORM_PARAM (driver expects 500, Field value too long)"
echo "2,000,000-byte literal in INSERT VALUES at the default max_query_size: length $INSERTED (driver expects 2000000)"
echo "$UPDATE_BYTES-byte ALTER UPDATE: default HTTP $DEFAULT_LIMIT, max_query_size=$UPDATE_BYTES HTTP $SIZED, one byte less HTTP $ONE_SHORT (driver expects 400, 200, 400)"
echo "value after the sized update: length $UPDATED (driver expects 300000)"
echo "hex of '\\Z': $SUB_ESCAPE (driver expects 5C5A, no escape)"
echo "hex of the escapes the driver writes: $ESCAPES (driver expects 6127625C6300080C0A0D09)"
echo "cast rows and String parameter rows: distinct,count $DISTINCT (driver expects 1,4)"
echo "param_v=a+b reads back as: $PLUS_RAW; a%2Bb as: $PLUS_ENCODED (driver expects a b and a+b)"
echo "40,000 euro signs (120,000 bytes, 360,000 encoded) as a parameter: HTTP $ENCODED_LIMIT (driver expects 500)"
echo "braced UUID into a UUID column: bare literal HTTP $BARE_UUID, cast HTTP $CAST_UUID, parameter HTTP $PARAM_UUID (driver expects 200, 400, 400)"

STATUS=0
[ "$URL_PARAM" = "500" ] || STATUS=1
[ "$FORM_PARAM" = "500" ] || STATUS=1
[ "$INSERTED" = "2000000" ] || STATUS=1
[ "$DEFAULT_LIMIT" = "400" ] || STATUS=1
[ "$SIZED" = "200" ] || STATUS=1
[ "$ONE_SHORT" = "400" ] || STATUS=1
[ "$UPDATED" = "300000" ] || STATUS=1
[ "$SUB_ESCAPE" = "5C5A" ] || STATUS=1
[ "$ESCAPES" = "6127625C6300080C0A0D09" ] || STATUS=1
[ "$DISTINCT" = "1,4" ] || STATUS=1
[ "$PLUS_RAW" = "a b" ] || STATUS=1
[ "$PLUS_ENCODED" = "a+b" ] || STATUS=1
[ "$ENCODED_LIMIT" = "500" ] || STATUS=1
[ "$CAST_UUID" = "$PARAM_UUID" ] || STATUS=1
[ "$CAST_UUID" = "400" ] || STATUS=1
exit "$STATUS"
