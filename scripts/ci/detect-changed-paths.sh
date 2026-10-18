#!/usr/bin/env bash
set -euo pipefail

# Prints "true" when a suite has to run for the changes since <base>, "false" when it can skip.
# Usage: detect-changed-paths.sh [--base <sha>] macos|plugins|ios|oracle|hana|release

BASE=""
SUITE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-}"; shift 2 ;;
        -*) echo "detect-changed-paths.sh: unknown flag $1" >&2; exit 2 ;;
        *) SUITE="$1"; shift ;;
    esac
done

cd "$(git rev-parse --show-toplevel)"

SKIP=""
case "$SUITE" in
    macos)
        PATTERNS=('TablePro/' 'TableProTests/' 'TableProUITests/' 'TestPlans/' 'Plugins/' 'Packages/'
            'Native/' 'Configs/' 'Libs/' 'project\.yml$'
            'TablePro\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$'
            'scripts/(generate-project|download-libs|create-openssl-dylibs|build-dameng|build-hana)\.sh$'
            'scripts/lib/' 'scripts/ci/(detect-changed-paths|summarize-xcresult|verify-plugin-loads)\.sh$'
            'scripts/release/notes\.py$' '\.github/actions/setup-xcode(gen)?/' '\.github/workflows/macos-tests\.yml$') ;;
    plugins)
        # Registry plugins link the TableProCore and TableProOracle products.
        PATTERNS=('Plugins/' 'Packages/TableProCore/' 'Packages/TableProOracle/' 'Native/' 'Libs/'
            'Configs/' 'project\.yml$'
            'TablePro\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$'
            'scripts/(build-dameng|build-hana)\.sh$' 'scripts/lib/' 'scripts/ci/verify-plugin-loads\.sh$'
            '\.github/actions/setup-xcode/' '\.github/workflows/macos-tests\.yml$') ;;
    ios)
        # The package's TableProPluginKit target is a symlink, so git reports its changes here.
        PATTERNS=('TableProMobile/' 'Libs/' 'Plugins/TableProPluginKit/'
            'scripts/(generate-project|download-libs|create-openssl-dylibs)\.sh$' 'scripts/lib/'
            'scripts/ci/(detect-changed-paths|summarize-xcresult)\.sh$'
            '\.github/actions/setup-xcode(gen)?/' '\.github/workflows/ios-tests\.yml$')
        # The iOS project compiles files from Plugins/, Packages/ and TablePro/, so every path its
        # spec reaches outside TableProMobile/ is read from the spec instead of copied here.
        SHARED="$(grep -oE '\.\./(Configs|Packages|Plugins|TablePro)/[^"[:space:]]*' TableProMobile/project.yml \
            | sed -E -e 's#^\.\./##' -e 's#/\.?$#/#' -e 's#\.#\\.#g' | sort -u)"
        while IFS= read -r shared; do
            PATTERNS+=("$shared")
        done <<< "$SHARED" ;;
    oracle)
        PATTERNS=('Packages/TableProOracle/' 'scripts/ci/summarize-xcresult\.sh$'
            '\.github/actions/setup-xcode/' '\.github/workflows/ios-tests\.yml$') ;;
    hana)
        PATTERNS=('Native/HanaBridge/' '\.github/workflows/repo-hygiene\.yml$') ;;
    release)
        # A Release build compiles no test target, so the test folders under Plugins/ and
        # Packages/ are skipped too.
        PATTERNS=('TablePro/' 'Plugins/' 'Packages/' 'Native/' 'Configs/' 'Libs/' 'project\.yml$'
            'TablePro\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$'
            '\.github/plugin-registry\.json$'
            'scripts/(generate-project|download-libs|create-openssl-dylibs|build-dameng|build-hana)\.sh$'
            'scripts/lib/' 'scripts/release/' 'scripts/ci/(detect-changed-paths|verify-plugin-loads)\.sh$'
            '\.github/actions/setup-xcode(gen)?/' '\.github/workflows/release-build\.yml$')
        SKIP='Plugins/[^/]+Tests/|Packages/[^/]+/Tests/' ;;
    *)
        echo "detect-changed-paths.sh: expected macos, plugins, ios, oracle, hana or release, got '$SUITE'" >&2
        exit 2 ;;
esac

# A new branch has no previous commit, so it is compared with the point where it left main.
if [ -n "$BASE" ] && [ -z "${BASE//0/}" ]; then
    BASE="$(git merge-base HEAD origin/main 2> /dev/null || true)"
fi

if [ -z "$BASE" ]; then
    echo "true"
    exit 0
fi

# Raw NUL-separated paths: core.quotePath would quote a non-ASCII path and defeat the ^ anchor.
# Files rather than $(...), which drops NUL bytes and would hide grep's exit status.
CHANGED="$(mktemp)"
RELEVANT="$(mktemp)"
trap 'rm -f "$CHANGED" "$RELEVANT"' EXIT
git -c core.quotePath=false diff --no-renames --name-only -z "$BASE" HEAD > "$CHANGED"
if [ -n "$SKIP" ]; then
    LC_ALL=C grep -zvE "^($SKIP)" "$CHANGED" > "$RELEVANT" || [ $? -eq 1 ]
else
    cp "$CHANGED" "$RELEVANT"
fi

JOINED="$(IFS='|'; echo "${PATTERNS[*]}")"
status=0
LC_ALL=C grep -zqE "^($JOINED)" "$RELEVANT" || status=$?
case "$status" in
    0) echo "true" ;;
    1) echo "false" ;;
    *) exit "$status" ;;
esac
