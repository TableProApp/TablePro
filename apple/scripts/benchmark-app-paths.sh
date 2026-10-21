#!/usr/bin/env bash
#
# Time cold launch, opening a 1,000,000-row table and switching among 20 tabs in the real app,
# 10 runs each, and compare the median and 95th percentile with scripts/benchmark/app-paths/baseline.json.
#
# Builds Release with scripts/release/build.sh unless --app names a build, signs a copy ad hoc and
# drives it in a TABLEPRO_UI_TEST_SANDBOX. Keys go through System Events, so the terminal needs
# Accessibility and Automation permission and the Mac must stay idle and unlocked for the run.
# MySQL (the socket its client uses) and PostgreSQL (127.0.0.1:5432) default to local servers, seeded
# into a tablepro_bench database.
#
# Usage:
#   scripts/benchmark-app-paths.sh                              # build Release, run every path
#   scripts/benchmark-app-paths.sh --app <TablePro.app>         # time an existing build
#   scripts/benchmark-app-paths.sh --paths tabs-next,tabs-recent --runs 5
#   scripts/benchmark-app-paths.sh --mysql user@127.0.0.1:3306 --postgres user@127.0.0.1:5432
#   scripts/benchmark-app-paths.sh --record                     # write the run as the new baseline
#
# Exit: 0 within budget, 1 over budget on the baseline's Mac and configuration, 2 the run stopped
# or a path has no baseline.

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-benchmark-app.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# An unsigned or development-signed build is refused by launchd once copied; an ad hoc copy runs.
ditto "$APP" "$WORK/TablePro.app"
codesign --force --deep --sign - "$WORK/TablePro.app" 2> /dev/null

python3 "$ROOT/scripts/benchmark/app-paths/benchmark.py" "$WORK/TablePro.app" ${ARGS[@]+"${ARGS[@]}"}
