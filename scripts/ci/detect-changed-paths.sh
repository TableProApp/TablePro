#!/usr/bin/env bash
set -euo pipefail

# Prints "true" when a suite has to run for the changes since <base>, "false" when it can skip.
# Usage: detect-changed-paths.sh [--base <sha>] macos|plugins|ios|oracle|hana|release|linux

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
        PATTERNS=('apple/TablePro/' 'apple/TableProTests/' 'apple/TableProUITests/' 'apple/TestPlans/'
            'apple/Plugins/' 'apple/Packages/' 'apple/Native/' 'apple/Configs/' 'apple/Libs/' 'apple/project\.yml$'
            'apple/TablePro\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$'
            'apple/scripts/(generate-project|download-libs|create-openssl-dylibs|build-dameng|build-hana)\.sh$'
            'apple/scripts/lib/' 'apple/scripts/ci/(summarize-xcresult|verify-plugin-loads)\.sh$'
            'scripts/ci/detect-changed-paths\.sh$'
            'apple/scripts/check-pluginkit-abi\.sh$' 'apple/scripts/release/notes\.py$'
            '\.github/actions/(setup-xcode(gen)?|prepare-build)/' '\.github/workflows/macos-tests\.yml$') ;;
    plugins)
        # Registry plugins link the TableProCore and TableProOracle products.
        PATTERNS=('apple/Plugins/' 'apple/Packages/TableProCore/' 'apple/Packages/TableProOracle/' 'apple/Native/'
            'apple/Libs/' 'apple/Configs/' 'apple/project\.yml$'
            'apple/TablePro\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$'
            'apple/scripts/(generate-project|download-libs|create-openssl-dylibs|build-dameng|build-hana)\.sh$'
            'apple/scripts/lib/' 'apple/scripts/ci/verify-plugin-loads\.sh$' 'apple/scripts/check-pluginkit-abi\.sh$'
            '\.github/actions/(setup-xcode(gen)?|prepare-build)/' '\.github/workflows/macos-tests\.yml$') ;;
    ios)
        # The package's TableProPluginKit target is a symlink, so git reports its changes here.
        PATTERNS=('apple/TableProMobile/' 'apple/Libs/' 'apple/Plugins/TableProPluginKit/'
            'apple/scripts/(generate-project|download-libs|create-openssl-dylibs)\.sh$' 'apple/scripts/lib/'
            'apple/scripts/ci/summarize-xcresult\.sh$' 'scripts/ci/detect-changed-paths\.sh$'
            '\.github/actions/setup-xcode(gen)?/' '\.github/workflows/ios-tests\.yml$')
        # The iOS project compiles files from Plugins/, Packages/ and TablePro/, so every path its
        # spec reaches outside TableProMobile/ is read from the spec instead of copied here.
        SHARED="$(grep -oE '\.\./(Configs|Packages|Plugins|TablePro)/[^"[:space:]]*' apple/TableProMobile/project.yml \
            | sed -E -e 's#^\.\./#apple/#' -e 's#/\.?$#/#' -e 's#\.#\\.#g' | sort -u)"
        while IFS= read -r shared; do
            PATTERNS+=("$shared")
        done <<< "$SHARED" ;;
    oracle)
        PATTERNS=('apple/Packages/TableProOracle/' 'apple/scripts/ci/summarize-xcresult\.sh$'
            '\.github/actions/setup-xcode/' '\.github/workflows/ios-tests\.yml$') ;;
    hana)
        PATTERNS=('apple/Native/HanaBridge/' '\.github/workflows/repo-hygiene\.yml$') ;;
    release)
        # A Release build compiles no test target, so the test folders under Plugins/ and
        # Packages/ are skipped too.
        PATTERNS=('apple/TablePro/' 'apple/Plugins/' 'apple/Packages/' 'apple/Native/' 'apple/Configs/' 'apple/Libs/'
            'apple/project\.yml$'
            'apple/TablePro\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$'
            '\.github/plugin-registry\.json$'
            'apple/scripts/(generate-project|download-libs|create-openssl-dylibs|build-dameng|build-hana)\.sh$'
            'apple/scripts/lib/' 'apple/scripts/release/(build|package)\.sh$'
            'apple/scripts/release/(notes|registry|version)\.py$'
            'apple/scripts/ci/verify-plugin-loads\.sh$' 'scripts/ci/detect-changed-paths\.sh$'
            '\.github/actions/(setup-xcode(gen)?|prepare-build)/' '\.github/workflows/release-build\.yml$')
        SKIP='apple/Plugins/[^/]+Tests/|apple/Packages/[^/]+/Tests/' ;;
    linux)
        PATTERNS=('linux/' 'scripts/ci/detect-changed-paths\.sh$'
            '\.github/workflows/(build-linux|linux-packages|release-linux)\.yml$') ;;
    *)
        echo "detect-changed-paths.sh: expected macos, plugins, ios, oracle, hana, release or linux, got '$SUITE'" >&2
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
