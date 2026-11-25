#!/usr/bin/env bash
set -euo pipefail

# Copies the /v2 document the generated client is built from out of tablepro-cloud. The entitlement vectors live with
# the core's verifier (core/scripts/update-cloud-api.sh). Prints the tablepro-cloud commit it came from, for the
# commit message.
#
# Usage: update-cloud-api.sh [tablepro-cloud checkout]   # default: ../tablepro-cloud beside the repository

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLOUD="${1:-$REPO_ROOT/../tablepro-cloud}"
DOCUMENT="api/v2.json"

if [ ! -f "$CLOUD/$DOCUMENT" ]; then
    echo "ERROR: $CLOUD/$DOCUMENT does not exist. Pass the tablepro-cloud checkout as the first argument." >&2
    exit 1
fi

copy() {
    if cmp -s "$CLOUD/$1" "$REPO_ROOT/$2"; then
        echo "$2 already matches"
    else
        cp "$CLOUD/$1" "$REPO_ROOT/$2"
        echo "Updated $2"
    fi
}

copy "$DOCUMENT" apple/Packages/TableProMacCore/Sources/TableProCloudAPI/openapi.json
echo "tablepro-cloud commit: $(git -C "$CLOUD" rev-parse --short HEAD 2> /dev/null || echo unknown)"
