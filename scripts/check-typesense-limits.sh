#!/usr/bin/env bash
#
# Check the Typesense server behaviours the driver hard-codes against a real server.
#
# Four numbers and one escaping rule are transcribed into TypesenseQueryBuilder and
# TypesenseFilterBuilder, and nothing at runtime re-derives them. A change in any of them is
# silent: a raised hit ceiling wastes round trips, a lowered one truncates a page, and an escape
# for backticks arriving in filter_by would mean the driver refuses values it no longer has to.
# The backtick case is the one that matters most, because without the driver's guard a filter
# value can close its own literal and the rest of it is parsed as filter syntax.
#
# Usage:
#   scripts/check-typesense-limits.sh [host] [port] [api-key]
#
# Creates and drops a collection named tablepro_limit_probe. Exits non-zero on a disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-8108}"
KEY="${3:-${TYPESENSE_API_KEY:-xyz}}"
BASE="http://$HOST:$PORT"
COLLECTION="tablepro_limit_probe"
FAILURES=0

command -v curl > /dev/null || {
    echo "curl not found" >&2
    exit 3
}
command -v python3 > /dev/null || {
    echo "python3 not found" >&2
    exit 3
}

api() {
    curl -sS -m 20 -H "X-TYPESENSE-API-KEY: $KEY" -H "Content-Type: application/json" "$@"
}

VERSION="$(api "$BASE/debug" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version",""))' 2> /dev/null)"
if [ -z "$VERSION" ]; then
    echo "no Typesense at $HOST:$PORT, or the API key was rejected" >&2
    exit 3
fi
echo "Typesense $VERSION at $HOST:$PORT"

cleanup() {
    api -X DELETE "$BASE/collections/$COLLECTION" > /dev/null 2>&1
}
trap cleanup EXIT

cleanup
api -X POST "$BASE/collections" -d "{
    \"name\": \"$COLLECTION\",
    \"fields\": [
        {\"name\": \"title\", \"type\": \"string\"},
        {\"name\": \"tag\", \"type\": \"string\", \"sort\": true},
        {\"name\": \"year\", \"type\": \"int32\", \"sort\": true}
    ]
}" > /dev/null
api -X POST "$BASE/collections/$COLLECTION/documents?action=upsert" \
    -d '{"id": "p1", "title": "probe one", "tag": "alpha", "year": 2000}' > /dev/null
api -X POST "$BASE/collections/$COLLECTION/documents?action=upsert" \
    -d '{"id": "p2", "title": "probe two", "tag": "beta", "year": 2020}' > /dev/null

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'ok    %s\n' "$name"
    else
        printf 'FAIL  %s\n      expected %s\n      actual   %s\n' "$name" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

# TypesenseQueryBuilder.maxHitsPerRequest
ACCEPTED="$(api "$BASE/collections/$COLLECTION/documents/search?q=*&limit=250" \
    | python3 -c 'import sys,json;print("yes" if "hits" in json.load(sys.stdin) else "no")')"
REFUSED="$(api "$BASE/collections/$COLLECTION/documents/search?q=*&limit=251" \
    | python3 -c 'import sys,json;print("no" if "message" in json.load(sys.stdin) else "yes")')"
check "limit 250 is accepted" "yes" "$ACCEPTED"
check "limit 251 is refused" "no" "$REFUSED"

# TypesenseQueryBuilder.maxSearchesPerRequest
BATCH="$(python3 - "$BASE" "$KEY" "$COLLECTION" <<'PY'
import json, sys, urllib.error, urllib.request

base, key, collection = sys.argv[1], sys.argv[2], sys.argv[3]


def searches(count):
    body = json.dumps({"searches": [{"collection": collection, "q": "*", "limit": 1}] * count})
    request = urllib.request.Request(
        base + "/multi_search",
        data=body.encode(),
        headers={"X-TYPESENSE-API-KEY": key, "Content-Type": "application/json"},
    )
    try:
        return len(json.load(urllib.request.urlopen(request))["results"]) == count
    except urllib.error.HTTPError:
        return False


print("yes" if searches(50) else "no", "yes" if searches(51) else "no")
PY
)"
check "50 searches per multi_search" "yes no" "$BATCH"

# TypesenseQueryBuilder.maxSortFields, and the sort gate in sortBy
SORTS="$(api "$BASE/collections/$COLLECTION/documents/search?q=*&sort_by=year:asc,tag:asc,year:desc,tag:desc" \
    | python3 -c 'import sys,json;print("no" if "message" in json.load(sys.stdin) else "yes")')"
UNSORTABLE="$(api "$BASE/collections/$COLLECTION/documents/search?q=*&sort_by=title:asc" \
    | python3 -c 'import sys,json;print("no" if "message" in json.load(sys.stdin) else "yes")')"
check "a fourth sort field is refused" "no" "$SORTS"
check "sorting a sort:false field is refused" "no" "$UNSORTABLE"

# TypesenseFilterBuilder.comparison: a string range answers empty instead of raising
STRING_RANGE="$(api --get "$BASE/collections/$COLLECTION/documents/search" \
    --data-urlencode 'q=*' --data-urlencode 'filter_by=title:>a' \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print("error" if "message" in d else str(d.get("found")))')"
check "a string comparison matches nothing rather than raising" "0" "$STRING_RANGE"

# TypesenseFilterBuilder.textLiteral: the reason a backtick in a value is refused
INJECTED="$(api --get "$BASE/collections/$COLLECTION/documents/search" \
    --data-urlencode 'q=*' --data-urlencode 'filter_by=tag:=`alpha` || year:>0' \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("found", "error"))')"
check "a backtick in a value still injects filter syntax" "2" "$INJECTED"

if [ "$FAILURES" -gt 0 ]; then
    echo
    echo "$FAILURES disagreement(s). Typesense $VERSION no longer behaves the way the driver assumes."
    exit 1
fi
echo
echo "Typesense $VERSION matches every limit the driver hard-codes."
