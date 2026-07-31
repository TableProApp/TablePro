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
# Requires a CloudKit management token:
#   xcrun cktool save-token --type management
#
# Usage:
#   scripts/export-cloudkit-schema.sh

TEAM_ID="D7HJ5TFYCU"
CONTAINER_ID="iCloud.com.TablePro"
ENVIRONMENT="production"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="${REPO_ROOT}/CloudKit/production-schema.ckdb"

mkdir -p "$(dirname "${OUTPUT_FILE}")"

echo "Exporting ${ENVIRONMENT} schema for ${CONTAINER_ID}..."
xcrun cktool export-schema \
    --team-id "${TEAM_ID}" \
    --container-id "${CONTAINER_ID}" \
    --environment "${ENVIRONMENT}" \
    --output-file "${OUTPUT_FILE}"

echo "Wrote ${OUTPUT_FILE}"
echo
echo "Review the diff, then commit it:"
echo "  git diff -- CloudKit/production-schema.ckdb"
