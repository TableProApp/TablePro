#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/check-pluginkit-abi.sh [--frozen] [base]
# Rules: .claude/rules/plugin-system.md, ABI.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
frozen=0
if [ "${1:-}" = "--frozen" ]; then
    frozen=1
    shift
fi
if [ $# -gt 1 ]; then
    echo "usage: scripts/check-pluginkit-abi.sh [--frozen] [base]" >&2
    exit 2
fi
base="${1:-$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*')}"

fail() {
    echo "::error::$1"
    exit 1
}

kits() {
    awk -F' *= *' -v origin="$1" '
        $1 == "TABLEPRO_PLUGINKIT_VERSION" { kit = $2 }
        $1 == "TABLEPRO_PLUGINKIT_MINIMUM_VERSION" { minimum = $2 }
        END {
            if (kit !~ /^[0-9]+$/ || minimum !~ /^[0-9]+$/) {
                print "::error::no PluginKit versions in " origin
                exit 1
            }
            print kit, minimum
        }'
}

base_kits="$(git -C "$root" show "$base:Configs/PluginKit.xcconfig" | kits "$base")"
head_kits="$(kits HEAD < "$root/Configs/PluginKit.xcconfig")"
read -r base_kit _ <<< "$base_kits"
read -r head_kit head_minimum <<< "$head_kits"

work="$(mktemp -d)"
cleanup() {
    git -C "$root" worktree remove --force "$work/src" > /dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# Without -error-on-abi-breakage, swift-api-digester reports a breakage as a warning.
build_kit() {
    local project="$1" side="$2"
    shift 2
    xcodebuild build -project "$project/TablePro.xcodeproj" -scheme TableProPluginKit -configuration Debug \
        -destination platform=macOS -derivedDataPath "$work/$side/DerivedData" \
        -clonedSourcePackagesDirPath "$work/packages" -skipPackagePluginValidation \
        CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_ABI_CHECKER_FLAGS=-error-on-abi-breakage \
        RUN_SWIFT_ABI_GENERATION_TOOL=YES SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR="$work/$side/ABI" \
        "$@" > "$work/$side.log" 2>&1
}

echo "Building TableProPluginKit at $base"
git -C "$root" worktree add --quiet --detach "$work/src" "$base"
(cd "$work/src" && xcodegen generate --quiet --spec project.yml)
build_kit "$work/src" base || { tail -30 "$work/base.log"; fail "TableProPluginKit does not build at $base"; }

echo "Building TableProPluginKit at HEAD"
build_kit "$root" head || { tail -30 "$work/head.log"; fail "TableProPluginKit does not build at HEAD"; }
for side in base head; do
    ls "$work/$side/ABI"/*.json > /dev/null 2>&1 || fail "The $side build wrote no ABI baseline."
done

echo "Checking the ABI against $base"
change=unchanged
if ! build_kit "$root" head RUN_SWIFT_ABI_CHECKER_TOOL=YES SWIFT_ABI_CHECKER_BASELINE_DIR="$work/base"; then
    breakages="$(grep ': error: ABI breakage: ' "$work/head.log" | sort -u)" \
        || { tail -30 "$work/head.log"; fail "The ABI checker failed without reporting a breakage."; }
    echo "$breakages"
    change=breaking
else
    compared=0
    diff -rq "$work/base/ABI" "$work/head/ABI" > /dev/null || compared=$?
    case "$compared" in
        0) ;;
        1) change=changed ;;
        *) fail "Could not compare the ABI baselines." ;;
    esac
fi

next=$((base_kit + 1))
config="Configs/PluginKit.xcconfig"
if [ "$frozen" -eq 1 ] && [ "$change" != unchanged ]; then
    fail "PluginKit's ABI differs from $base, and a release line never changes it."
fi
case "$change" in
    breaking)
        if [ "$head_kit" -ne "$next" ] || [ "$head_minimum" -ne "$next" ]; then
            fail "Breaking change since $base: set TABLEPRO_PLUGINKIT_VERSION and TABLEPRO_PLUGINKIT_MINIMUM_VERSION to $next in $config."
        fi
        ;;
    changed)
        if [ "$head_kit" -ne "$next" ]; then
            fail "PluginKit's ABI changed since $base: set TABLEPRO_PLUGINKIT_VERSION to $next in $config."
        fi
        ;;
    unchanged)
        if [ "$head_kit" -ne "$base_kit" ]; then
            fail "PluginKit's ABI matches $base: TABLEPRO_PLUGINKIT_VERSION stays $base_kit in $config."
        fi
        ;;
esac
echo "PluginKit ABI against $base: $change; kit $head_kit, minimum $head_minimum."
