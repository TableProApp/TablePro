#!/usr/bin/env bash
#
# Check how a ClickHouse server reports a query that fails partway, against what the driver expects.
#
# A streamed read has had HTTP 200 by then, so the server writes the exception into the body, and
# ClickHouseServerException.swift reads it by shape: raw text before 24.11, an `__exception__`
# marker from 24.11, a block framed by the X-ClickHouse-Exception-Tag header from 25.11. A bounded
# read sends `wait_end_of_query=1`, which the driver relies on to turn the failure into a status.
# Neither shape is announced by the server, so a release that changes one would make the driver
# return the error text as rows. This sends the driver's own URL items and checks both.
#
# Usage:
#   scripts/probes/check-clickhouse-stream-failures.sh [url] [user]
#
# Needs curl. The password, if any, comes from CLICKHOUSE_PASSWORD. Exits 0 when the server matches
# what the driver expects for its version, 1 when it does not, and 3 when the check could not run.

set -uo pipefail

URL="${1:-http://127.0.0.1:8123}"
USER_NAME="${2:-default}"
QUERY="SELECT number, throwIf(number = 100000) FROM numbers(200000) SETTINGS max_block_size = 1000"
STREAM_ITEMS="query_id=probe-stream&default_format=TabSeparatedWithNamesAndTypes"
BOUNDED_ITEMS="query_id=probe-bounded&default_format=TabSeparatedWithNamesAndTypes&wait_end_of_query=1&max_result_rows=200001&result_overflow_mode=break"

# The credentials go through a config on stdin, so they never sit in the process list. A curl
# config string takes backslash escapes.
CREDENTIALS="$USER_NAME:${CLICKHOUSE_PASSWORD:-}"
CREDENTIALS="${CREDENTIALS//\\/\\\\}"
CREDENTIALS="${CREDENTIALS//\"/\\\"}"
ask() {
    printf 'user = "%s"\n' "$CREDENTIALS" | curl -sS --max-time 30 --config - -H 'Accept-Encoding: identity' "$@"
}

VERSION="$(ask "$URL/" --data-binary "SELECT version()")" || {
    echo "no ClickHouse at $URL for $USER_NAME" >&2
    exit 3
}
# The server's text reaches arithmetic only once it is digits: bash evaluates `$(...)` inside an
# array subscript in `$(( ))`.
MAJOR="${VERSION%%.*}"
MINOR="${VERSION#*.}"
MINOR="${MINOR%%.*}"
if [[ ! "$MAJOR" =~ ^[0-9]+$ || ! "$MINOR" =~ ^[0-9]+$ ]]; then
    echo "unreadable version from $URL" >&2
    exit 3
fi
LINE=$((10#$MAJOR * 100 + 10#$MINOR))

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ask -D "$WORK/stream.headers" -o "$WORK/stream.body" "$URL/?$STREAM_ITEMS" --data-binary "$QUERY" 2> /dev/null
TAG="$(tr -d '\r' < "$WORK/stream.headers" | awk -F': ' 'tolower($1) == "x-clickhouse-exception-tag" { print $2 }')"
if [ -n "$TAG" ] && grep -q "__exception__" "$WORK/stream.body" && grep -qF -- "$TAG" "$WORK/stream.body"; then
    SHAPE="tagged"
elif grep -q $'__exception__\r' "$WORK/stream.body"; then
    SHAPE="marker"
elif grep -q '^Code: [0-9]*[.,] .*(version ' <(tail -n 1 "$WORK/stream.body"); then
    SHAPE="raw"
else
    SHAPE="unknown"
fi

if [ "$LINE" -ge 2511 ]; then
    EXPECTED="tagged"
elif [ "$LINE" -ge 2411 ]; then
    EXPECTED="marker"
else
    EXPECTED="raw"
fi

BOUNDED_STATUS="$(ask -o /dev/null -w '%{http_code}' "$URL/?$BOUNDED_ITEMS" --data-binary "$QUERY")"

echo "server: $VERSION"
echo "stream failure shape: $SHAPE (driver expects $EXPECTED)"
echo "bounded failure status: $BOUNDED_STATUS (driver expects 500)"

STATUS=0
[ "$SHAPE" = "$EXPECTED" ] || STATUS=1
[ "$BOUNDED_STATUS" = "500" ] || STATUS=1
exit "$STATUS"
