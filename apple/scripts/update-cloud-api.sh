#!/usr/bin/env bash
set -euo pipefail

# Copies tablepro-cloud's published /v2 document over the one the generated client is built from,
# then prints the tablepro-cloud commit it came from, for the commit message.
#
# Usage: update-cloud-api.sh [tablepro-cloud checkout]   # default: ../tablepro-cloud beside the repository

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLOUD="${1:-$REPO_ROOT/../tablepro-cloud}"
SOURCE="$CLOUD/api/v2.json"
TARGET="$REPO_ROOT/apple/Packages/TableProMacCore/Sources/TableProCloudAPI/openapi.json"

if [ ! -f "$SOURCE" ]; then
    echo "ERROR: $SOURCE does not exist. Pass the tablepro-cloud checkout as the first argument." >&2
    exit 1
fi

if cmp -s "$SOURCE" "$TARGET"; then
    echo "openapi.json already matches $SOURCE"
else
    cp "$SOURCE" "$TARGET"
    echo "Updated openapi.json from $SOURCE"
fi
echo "tablepro-cloud commit: $(git -C "$CLOUD" rev-parse --short HEAD 2> /dev/null || echo unknown)"
