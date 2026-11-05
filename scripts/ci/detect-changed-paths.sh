#!/usr/bin/env bash
set -euo pipefail

# Prints "true" when a suite has to run for the changes from <base> to <head>, "false" when it can skip.
# Usage: detect-changed-paths.sh [--base <sha>] [--head <rev>] [--ref <git ref>] <suite>
# Suites: macos, plugins, ios, oracle, hana, release, shipped, swiftlint, linux, linux-docs, linux-deps, packages, core,
# windows.

BASE=""
HEAD_REV="HEAD"
REF=""
SUITE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-}"; shift 2 ;;
        --head) HEAD_REV="${2:-}"; shift 2 ;;
        --ref) REF="${2:-}"; shift 2 ;;
        -*) echo "detect-changed-paths.sh: unknown flag $1" >&2; exit 2 ;;
        *) SUITE="$1"; shift ;;
    esac
done

cd "$(git rev-parse --show-toplevel)"

SKIP=""
KEEP=""
case "$SUITE" in
    macos)
        PATTERNS=('apple/TablePro/' 'apple/TableProTests/' 'apple/TableProUITests/' 'apple/TestPlans/'
            'apple/Plugins/' 'apple/Packages/' 'apple/Native/' 'apple/Configs/' 'apple/Libs/' 'apple/project\.yml$'
            'apple/TablePro\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$'
            'apple/scripts/(generate-project|download-libs|create-openssl-dylibs|build-dameng|build-hana)\.sh$'
            'apple/scripts/lib/' 'apple/scripts/ci/(summarize-xcresult|verify-plugin-loads)\.sh$'
            'apple/scripts/localization\.py$' 'scripts/ci/detect-changed-paths\.sh$'
            'apple/scripts/check-pluginkit-abi\.sh$' 'apple/scripts/release/notes\.py$'
            '\.github/actions/(setup-xcode(gen)?|prepare-build)/' '\.github/workflows/(ci|macos-tests)\.yml$') ;;
    plugins)
        # Registry plugins link the TableProCore and TableProOracle products.
        PATTERNS=('apple/Plugins/' 'apple/Packages/TableProCore/' 'apple/Packages/TableProOracle/' 'apple/Native/'
            'apple/Libs/' 'apple/Configs/' 'apple/project\.yml$'
            'apple/TablePro\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$'
            'apple/scripts/(generate-project|download-libs|create-openssl-dylibs|build-dameng|build-hana)\.sh$'
            'apple/scripts/lib/' 'apple/scripts/ci/verify-plugin-loads\.sh$' 'apple/scripts/check-pluginkit-abi\.sh$'
            '\.github/actions/(setup-xcode(gen)?|prepare-build)/' '\.github/workflows/(ci|macos-tests)\.yml$') ;;
    ios)
        # The package's TableProPluginKit target is a symlink, so git reports its changes here.
        PATTERNS=('apple/TableProMobile/' 'apple/Libs/' 'apple/Plugins/TableProPluginKit/'
            'apple/scripts/(generate-project|download-libs|create-openssl-dylibs)\.sh$' 'apple/scripts/lib/'
            'apple/scripts/ci/summarize-xcresult\.sh$' 'apple/scripts/localization\.py$'
            'scripts/ci/detect-changed-paths\.sh$'
            '\.github/actions/setup-xcode(gen)?/' '\.github/workflows/(ci|ios-tests)\.yml$'
            # The TableProCore package tests read the function names the Linux app shares.
            'core/crates/core/tests/fixtures/state_changing_functions\.json$')
        # The iOS project compiles files from Plugins/, Packages/ and TablePro/, so every path its
        # spec reaches outside TableProMobile/ is read from the spec instead of copied here.
        SHARED="$(grep -oE '\.\./(Configs|Packages|Plugins|TablePro)/[^"[:space:]]*' apple/TableProMobile/project.yml \
            | sed -E -e 's#^\.\./#apple/#' -e 's#/\.?$#/#' -e 's#\.#\\.#g' | sort -u)"
        while IFS= read -r shared; do
            PATTERNS+=("$shared")
        done <<< "$SHARED" ;;
    oracle)
        PATTERNS=('apple/Packages/TableProOracle/' 'apple/scripts/ci/summarize-xcresult\.sh$'
            '\.github/actions/setup-xcode/' '\.github/workflows/(ci|ios-tests)\.yml$') ;;
    hana)
        PATTERNS=('apple/Native/HanaBridge/' '\.github/workflows/(ci|ci-lint)\.yml$') ;;
    release|shipped)
        # A Release build compiles no test target, so the test folders under Plugins/ and
        # Packages/ are skipped too.
        PATTERNS=('apple/TablePro/' 'apple/Plugins/' 'apple/Packages/' 'apple/Native/' 'apple/Configs/' 'apple/Libs/'
            'apple/project\.yml$'
            'apple/TablePro\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/Package\.resolved$'
            '\.github/plugin-registry\.json$'
            'apple/scripts/(generate-project|download-libs|create-openssl-dylibs|build-dameng|build-hana)\.sh$'
            'apple/scripts/lib/' 'apple/scripts/release/(build|package|dmg)\.sh$'
            'apple/scripts/release/dmg\.DS_Store$' 'apple/scripts/release/(notes|registry|version)\.py$'
            'apple/scripts/ci/verify-plugin-loads\.sh$' 'scripts/ci/detect-changed-paths\.sh$'
            '\.github/actions/(setup-xcode(gen)?|prepare-build)/' '\.github/workflows/(ci|nightly)\.yml$')
        SKIP='apple/Plugins/[^/]+Tests/|apple/Packages/[^/]+/Tests/'
        # shipped is what an X.Y.0 may not change after its newest beta: the release build minus its CI.
        if [ "$SUITE" = shipped ]; then
            KEPT=()
            for pattern in "${PATTERNS[@]}"; do
                case "$pattern" in
                    '\.github/workflows/'* | '\.github/actions/'*) ;;
                    *) KEPT+=("$pattern") ;;
                esac
            done
            PATTERNS=("${KEPT[@]}")
        fi ;;
    swiftlint)
        PATTERNS=('.*\.swift$' '(.*/)?\.swiftlint\.yml$' 'scripts/ci/detect-changed-paths\.sh$'
            '\.github/workflows/(ci|ci-lint)\.yml$') ;;
    linux|linux-docs)
        # The Linux app builds the shared core in the Cargo workspace whose files are at the top.
        PATTERNS=('linux/' 'core/' 'Cargo\.(toml|lock)$' '(rust-toolchain|rustfmt|clippy|deny)\.toml$'
            '\.config/nextest\.toml$' 'scripts/ci/detect-changed-paths\.sh$'
            '\.github/workflows/(ci|build-linux|linux-packages|release-linux)\.yml$')
        # linux-docs decides the docs links job, which reads every path. The other Linux jobs skip
        # Markdown, except the files a Meson test reads and the notices the build installs.
        if [ "$SUITE" = linux ]; then
            SKIP='(linux|core)/.*\.md$'
            KEEP='linux/CHANGELOG\.md$|linux/docs/regression-tests\.md$|linux/data/'
        fi ;;
    linux-deps)
        # The Linux checks a dependency, toolchain or manifest change needs beyond the baseline: the minimum Rust
        # version with the distribution's compiler, the Arm64 Flatpak and the advisory database.
        PATTERNS=('Cargo\.(toml|lock)$' '(linux|core)/(.*/)?Cargo\.toml$' '(rust-toolchain|deny)\.toml$'
            'linux/build-aux/flatpak/' 'linux/build-aux/debian/control$'
            'linux/build-aux/packaging/add-rust-toolchain-ppa\.sh$' 'scripts/ci/detect-changed-paths\.sh$'
            '\.github/workflows/(ci|build-linux)\.yml$') ;;
    packages)
        # The clean distribution builds: what declares a build or runtime dependency, how the build runs and installs,
        # and the packaging itself. A source change alone builds no package.
        PATTERNS=('Cargo\.(toml|lock)$' '(linux|core)/(.*/)?Cargo\.toml$' 'rust-toolchain\.toml$'
            'linux/build-aux/(debian|rpm|packaging|flatpak|about)/' 'linux/build-aux/[^/]+$' 'linux/about\.toml$'
            'linux/meson\.(build|options)$' 'linux/(.*/)?meson\.build$' 'linux/po/LINGUAS$'
            'scripts/ci/detect-changed-paths\.sh$' '\.github/workflows/(ci|linux-packages)\.yml$')
        SKIP='linux/.*\.md$' ;;
    core)
        # core.yml: the core on Windows and macOS, and its Swift bindings, which take the deployment target from
        # apple/project.yml. A change to linux/ alone runs none of it.
        PATTERNS=('core/' 'Cargo\.(toml|lock)$' 'rust-toolchain\.toml$'
            'scripts/ci/(detect-changed-paths\.sh|start-windows-sshd\.ps1)$'
            'apple/project\.yml$' 'apple/Packages/TableProFFI/' 'apple/scripts/build-core\.sh$'
            'apple/scripts/lib/deployment-target\.sh$' '\.github/workflows/(ci|core)\.yml$')
        SKIP='core/.*\.md$' ;;
    windows)
        # The .NET tests run the whole core through its FFI crate, so any core or workspace change runs them.
        PATTERNS=('windows/' 'core/' 'Cargo\.(toml|lock)$' 'rust-toolchain\.toml$'
            'scripts/ci/(detect-changed-paths\.sh|start-windows-sshd\.ps1)$' '\.github/workflows/(ci|windows)\.yml$')
        SKIP='(windows|core)/.*\.md$' ;;
    *)
        echo "detect-changed-paths.sh: expected macos, plugins, ios, oracle, hana, release, shipped, swiftlint, linux, linux-docs, linux-deps, packages, core or windows, got '$SUITE'" >&2
        exit 2 ;;
esac

# Every suite runs on a release line: a tag's verify needs its commit's own runs, and a release PR
# changes only the changelog.
case "$REF" in
    refs/heads/release/*)
        echo "true"
        exit 0 ;;
esac

# A new branch has no previous commit, so it is compared with the point where it left main.
if [ -n "$BASE" ] && [ -z "${BASE//0/}" ]; then
    BASE="$(git merge-base "$HEAD_REV" origin/main 2> /dev/null || true)"
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
git -c core.quotePath=false diff --no-renames --name-only -z "$BASE" "$HEAD_REV" > "$CHANGED"
if [ -n "$SKIP" ]; then
    LC_ALL=C grep -zvE "^($SKIP)" "$CHANGED" > "$RELEVANT" || [ $? -eq 1 ]
    if [ -n "$KEEP" ]; then
        LC_ALL=C grep -zE "^($KEEP)" "$CHANGED" >> "$RELEVANT" || [ $? -eq 1 ]
    fi
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
