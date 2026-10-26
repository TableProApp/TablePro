#!/usr/bin/env bash
#
# Time the sidebar, Open Quickly and autocomplete on a catalog of 50,000 tables (#3661), 10 runs each,
# and compare the median and 95th percentile with scripts/benchmark/large-catalog/baseline.json. A step
# also fails when the main thread stalls for more than 100 ms during it. The app times each step itself
# (TABLEPRO_INTERACTION_TRACE=1): sidebar-listing (connect to the full listing), sidebar-filter (one
# keystroke), sidebar-expand (a schema never read; MySQL: the database), quick-open-panel,
# quick-open-result (a table in every schema), complete-from and complete-schema (MySQL: the database),
# plus the memory footprint.
#
# Fixtures come from scripts/probes/build-large-catalog-fixtures.sh. The release build has no Oracle
# driver, so Oracle needs --oracle-plugin with an OracleDriver.tableplugin built from this tree and signed
# by the TablePro team; one built before the tree's last Oracle change is refused.
# Builds Release unless --app names a build, and drives a signed copy through System Events in a
# TABLEPRO_UI_TEST_SANDBOX, so the terminal needs Accessibility and Automation permission.
#
# Usage:
#   scripts/benchmark-large-catalog.sh [--app <TablePro.app>] [--fixtures postgres,oracle,mysql]
#       [--parts listing,session,expand] [--runs 10] [--mysql user@host:port] [--postgres user@host:port]
#       [--oracle host:port] [--oracle-container <name>] [--oracle-plugin <OracleDriver.tableplugin>] [--record] [--keep]
#
# Exit: 0 within budget, 1 a stall over 100 ms or over budget on the baseline's Mac and configuration,
# 2 the run stopped or a step has no baseline.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --app)
            [ $# -ge 2 ] || { echo "--app needs a path" >&2; exit 2; }
            APP="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

if [ -z "$APP" ]; then
    (cd "$ROOT" && scripts/release/build.sh app --unsigned)
    APP="$ROOT/build/release/TablePro.app"
fi
[ -d "$APP/Contents/MacOS" ] || { echo "not an app bundle: $APP" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-benchmark-catalog.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# An unsigned or development-signed build is refused by launchd once copied; an ad hoc copy runs.
ditto "$APP" "$WORK/TablePro.app"
codesign --force --deep --sign - "$WORK/TablePro.app" 2> /dev/null

python3 "$ROOT/scripts/benchmark/large-catalog/benchmark.py" "$WORK/TablePro.app" ${ARGS[@]+"${ARGS[@]}"}
