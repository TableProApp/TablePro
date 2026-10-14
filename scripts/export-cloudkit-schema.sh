#!/usr/bin/env bash
set -euo pipefail

# Refresh the checked-in snapshot of the Production CloudKit schema.
#
# CloudKit only creates record fields automatically in the Development
# environment. TablePro pins both apps to Production, so a field added to a
# record type in code never reaches the server on its own: saving a record
# that carries an undeclared field makes CloudKit reject that record.
#
# ConnectionSyncField refuses to write any field that is not verified against
# this snapshot, and ProductionSchemaParityTests fails if the two disagree.
# After deploying a schema change in CloudKit Console, run this script and
# commit the result, then mark the field verified in ConnectionSyncSchema.swift.
#
# The snapshot is only ever this script's output: a hand edit passes
# ProductionSchemaParityTests while Production still rejects the field.
#
# Requires a CloudKit management token:
#   xcrun cktool save-token --type management
#
# Usage:
#   scripts/export-cloudkit-schema.sh            # overwrite the snapshot
#   scripts/export-cloudkit-schema.sh --check    # compare without writing

TEAM_ID="D7HJ5TFYCU"
CONTAINER_ID="iCloud.com.TablePro"
ENVIRONMENT="production"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT_FILE="${REPO_ROOT}/CloudKit/production-schema.ckdb"

MODE="export"
case "${1:-}" in
    "") ;;
    --check) MODE="check" ;;
    *)
        echo "Usage: $0 [--check]" >&2
        exit 2
        ;;
esac

export_schema() {
    xcrun cktool export-schema \
        --team-id "${TEAM_ID}" \
        --container-id "${CONTAINER_ID}" \
        --environment "${ENVIRONMENT}" \
        --output-file "$1"
}

if [[ "${MODE}" == "check" ]]; then
    LIVE_FILE="$(mktemp -t production-schema)"
    trap 'rm -f "${LIVE_FILE}"' EXIT
    echo "Checking CloudKit/production-schema.ckdb against ${ENVIRONMENT} ${CONTAINER_ID}..."
    export_schema "${LIVE_FILE}"
    if diff -u --label "snapshot" --label "${ENVIRONMENT}" "${SNAPSHOT_FILE}" "${LIVE_FILE}"; then
        echo "Snapshot matches ${ENVIRONMENT}."
        exit 0
    fi
    echo >&2
    echo "Snapshot and ${ENVIRONMENT} differ. A '-' line is in the snapshot but not deployed:" >&2
    echo "deploy it in CloudKit Console, then rerun this script without --check." >&2
    exit 1
fi

mkdir -p "$(dirname "${SNAPSHOT_FILE}")"

echo "Exporting ${ENVIRONMENT} schema for ${CONTAINER_ID}..."
export_schema "${SNAPSHOT_FILE}"

echo "Wrote ${SNAPSHOT_FILE}"
echo
echo "Review the diff, then commit it:"
echo "  git diff -- CloudKit/production-schema.ckdb"
