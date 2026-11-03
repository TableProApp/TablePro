#!/usr/bin/env bash
#
# Print what the Cloudflare D1 REST API answers for the requests the D1 driver sends, so the decoder in
# Plugins/CloudflareD1DriverPlugin/D1HttpClient.swift is checked against the wire, not the docs:
#
#   1. /raw for one row holding a BLOB, an integer past 2^53, a real, a boolean expression, NULL and text
#   2. GET .../database/{name}, which the driver uses to resolve a database named rather than given by UUID
#   3. one page of the database list with per_page=10, to show result_info
#
# Usage:
#   CF_ACCOUNT_ID=... CF_API_TOKEN=... scripts/probes/check-cloudflare-d1-wire-shapes.sh <database-name>
#
# The token needs D1 Read. Nothing is written. The token is read from the environment and never printed.
# Exits 3 when curl or a variable is missing.

set -uo pipefail

DATABASE="${1:-}"
if [[ -z "$DATABASE" || -z "${CF_ACCOUNT_ID:-}" || -z "${CF_API_TOKEN:-}" ]]; then
    sed -n '3,15p' "$0" >&2
    exit 3
fi
command -v curl > /dev/null || { echo "curl is missing" >&2; exit 3; }

BASE="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/d1/database"

# The token reaches curl on stdin as a config line, so it never shows in the process list.
request() {
    printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" \
        | curl --silent --show-error --config - --header "Content-Type: application/json" "$@"
    echo
}

echo "== GET database by name"
DETAILS="$(request "${BASE}/${DATABASE}")"
echo "$DETAILS"
UUID="$(printf '%s' "$DETAILS" | sed -n 's/.*"uuid":"\([0-9a-fA-F-]*\)".*/\1/p' | head -1)"
if [[ -z "$UUID" ]]; then
    echo "No uuid in the answer above; the name lookup failed." >&2
    exit 1
fi

echo "== /raw value shapes"
request --request POST "${BASE}/${UUID}/raw" --data \
    '{"sql":"SELECT X'"'"'0001FF'"'"' AS blob_value, X'"'"''"'"' AS empty_blob, 9007199254740993 AS big_int, 2.5 AS real_value, (1 = 1) AS bool_value, NULL AS null_value, '"'"'text'"'"' AS text_value"}'

echo "== list, first page of 10"
request "${BASE}?per_page=10&page=1"
