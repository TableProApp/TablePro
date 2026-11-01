#!/usr/bin/env bash
#
# Run TableProQdrantCore against a live Qdrant node: cursor paging, every filter kind, order_by,
# set-payload, insert_only inserts with no vector, delete, truncate, export and drop. The probe
# creates and drops a collection named tablepro_probe.
#
# Usage:
#   scripts/probes/check-qdrant.sh [host] [port]
#
# QDRANT_API_KEY sends a key. Start a node with:
#   docker run -d --name tablepro-qdrant-probe -p 6333:6333 qdrant/qdrant
#
# Exits 3 when no node answers.

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-6333}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../../Packages/TableProCore" && pwd)"

if ! curl -fsS -o /dev/null ${QDRANT_API_KEY:+-H "api-key: $QDRANT_API_KEY"} "http://$HOST:$PORT/collections"; then
    echo "No Qdrant node answers at $HOST:$PORT." >&2
    exit 3
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/probe"
cp "$HERE/qdrant-probe.swift" "$WORK/Sources/probe/main.swift"
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$CORE")],
    targets: [.executableTarget(name: "probe", dependencies: [.product(name: "TableProQdrantCore", package: "TableProCore")])]
)
MANIFEST

QDRANT_HOST="$HOST" QDRANT_PORT="$PORT" swift run --package-path "$WORK" probe
