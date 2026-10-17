# The macOS deployment target every native library is built for, read from the one place that
# decides it.
#
# Sourced, never executed, and it defines nothing but DEPLOY_TARGET so a script with its own
# LIBS_DIR or REPO_ROOT can pick it up without inheriting anything else:
#
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deployment-target.sh"
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
