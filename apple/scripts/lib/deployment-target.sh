# The macOS deployment target every native library and bridge is built for, read from project.yml,
# the iOS one from TableProMobile/project.yml, and the check that a built Mach-O stays at or below
# it. Sourced, never executed. Unlike common.sh it sets no LIBS_DIR or REPO_ROOT, so a script with
# its own can source it.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # DEPLOY_TARGET is read by the scripts that source this

[ -n "${TABLEPRO_DEPLOY_TARGET_SOURCED:-}" ] && return 0
TABLEPRO_DEPLOY_TARGET_SOURCED=1

TABLEPRO_DEPLOY_TARGET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DEPLOY_TARGET="$(
    awk '
        /^  deploymentTarget:/ { inTarget = 1; next }
        inTarget && /^    macOS:/ { gsub(/[" ]/, "", $2); print $2; exit }
        inTarget && /^[^ ]/ { exit }
    ' "$TABLEPRO_DEPLOY_TARGET_ROOT/project.yml"
)"

if [ -z "$DEPLOY_TARGET" ]; then
    echo "Could not read deploymentTarget.macOS from $TABLEPRO_DEPLOY_TARGET_ROOT/project.yml" >&2
    exit 1
fi

# The highest minimum OS across every slice and archive member, from LC_BUILD_VERSION or the
# older LC_VERSION_MIN_MACOSX: one newer object is enough to keep the whole file off the floor.
macho_min_version() {
    otool -arch all -l "$1" 2> /dev/null | awk '
        $1 == "cmd" { cmd = $2; next }
        cmd == "LC_BUILD_VERSION" && $1 == "minos" { print $2 }
        cmd == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2 }
    ' | sort -V | tail -1
}

# Read when a script asks, so a macOS-only script never depends on the iOS project.
ios_deployment_target() {
    local target
    target="$(
        awk '
            /^  deploymentTarget:/ { inTarget = 1; next }
            inTarget && /^    iOS:/ { gsub(/[" ]/, "", $2); print $2; exit }
            inTarget && /^[^ ]/ { exit }
        ' "$TABLEPRO_DEPLOY_TARGET_ROOT/TableProMobile/project.yml"
    )"
    if [ -z "$target" ]; then
        echo "Could not read deploymentTarget.iOS from $TABLEPRO_DEPLOY_TARGET_ROOT/TableProMobile/project.yml" >&2
        return 1
    fi
    echo "$target"
}

verify_deployment_target() {
    verify_deployment_target_for macOS "$DEPLOY_TARGET" "$@"
}

# Usage: verify_deployment_target_for <system> <target> <file>...
verify_deployment_target_for() {
    local system="$1" target="$2" file name version failed=0
    shift 2
    echo ""
    echo "🔍 Verifying deployment targets..."
    for file in "$@"; do
        [ -f "$file" ] || continue
        name=$(basename "$file")
        if ! version=$(macho_min_version "$file") || [ -z "$version" ]; then
            echo "   ❌ $name records no minimum $system"
            failed=1
        elif [ "$(printf '%s\n' "$target" "$version" | sort -V | tail -1)" != "$target" ]; then
            echo "   ❌ $name targets $system $version (expected $target)"
            failed=1
        else
            echo "   ✅ $name targets $system $version"
        fi
    done
    if [ "$failed" -eq 1 ]; then
        echo "❌ FATAL: some libraries have incorrect deployment targets" >&2
        return 1
    fi
}
