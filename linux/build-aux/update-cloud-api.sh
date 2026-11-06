#!/bin/sh
# Copies what core/crates/account vendors from a tablepro-cloud checkout: the /v2
# document build.rs generates the client from, and the entitlement test
# vectors. The apps' CI cannot reach that private repository, so these are
# copies, never links. Prints the tablepro-cloud commit for the commit message.
#
# Usage: build-aux/update-cloud-api.sh [tablepro-cloud checkout]
# The default is the tablepro-cloud checkout beside this repository.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cloud="${1:-$root/../../tablepro-cloud}"
document=api/v2.openapi-3.0.json
vectors=internal/licensing/adapter/jws/testdata/entitlement_vectors.json

for source in "$document" "$vectors"; do
    if [ ! -f "$cloud/$source" ]; then
        echo "update-cloud-api.sh: $cloud/$source does not exist; pass the tablepro-cloud checkout as the first argument" >&2
        exit 1
    fi
done

copy() {
    if cmp -s "$cloud/$1" "$root/$2"; then
        echo "$2 already matches"
    else
        cp "$cloud/$1" "$root/$2"
        echo "updated $2"
    fi
}

copy "$document" ../core/crates/account/openapi/v2.openapi-3.0.json
copy "$vectors" ../core/crates/account/tests/data/entitlement_vectors.json
echo "tablepro-cloud commit: $(git -C "$cloud" rev-parse --short HEAD 2>/dev/null || echo unknown)"
