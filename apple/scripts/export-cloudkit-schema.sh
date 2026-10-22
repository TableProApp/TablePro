#!/usr/bin/env bash
set -euo pipefail

# Refresh the checked-in snapshot of the Production CloudKit schema. When to run it:
# .claude/rules/data-sync-storage.md.
#
# Reads the management token from CLOUDKIT_MANAGEMENT_TOKEN, or from `xcrun cktool save-token --type management`.
#
# Usage:
#   scripts/export-cloudkit-schema.sh                   # overwrite the snapshot
#   scripts/export-cloudkit-schema.sh --check           # compare without writing
#   scripts/export-cloudkit-schema.sh --check-deployed  # fail only on what the snapshot has and Production lacks

TEAM_ID="D7HJ5TFYCU"
CONTAINER_ID="iCloud.com.TablePro"
ENVIRONMENT="production"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT_FILE="${REPO_ROOT}/CloudKit/production-schema.ckdb"

MODE="export"
case "${1:-}" in
    "") ;;
    --check) MODE="check" ;;
    --check-deployed) MODE="check-deployed" ;;
    *)
        echo "Usage: $0 [--check | --check-deployed]" >&2
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

# A release checks only its own snapshot's side: Production keeps every type and field a newer line
# deployed, and a build that never reads them is unaffected.
if [[ "${MODE}" == "check-deployed" ]]; then
    LIVE_FILE="$(mktemp -t production-schema)"
    trap 'rm -f "${LIVE_FILE}"' EXIT
    echo "Checking that ${ENVIRONMENT} ${CONTAINER_ID} has everything CloudKit/production-schema.ckdb declares..."
    export_schema "${LIVE_FILE}"
    if python3 "${REPO_ROOT}/scripts/release/schema.py" covers "${SNAPSHOT_FILE}" "${LIVE_FILE}"; then
        exit 0
    fi
    echo >&2
    echo "${ENVIRONMENT} lacks what the snapshot declares: deploy it in CloudKit Console." >&2
    exit 1
fi

mkdir -p "$(dirname "${SNAPSHOT_FILE}")"

echo "Exporting ${ENVIRONMENT} schema for ${CONTAINER_ID}..."
export_schema "${SNAPSHOT_FILE}"

echo "Wrote ${SNAPSHOT_FILE}"
echo
echo "Review the diff, then commit it:"
echo "  git diff -- CloudKit/production-schema.ckdb"
