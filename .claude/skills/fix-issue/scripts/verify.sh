#!/usr/bin/env bash
#
# Run one TablePro verification step, keep the full output on disk, and print a short verdict.
#
# A Debug build prints thousands of lines and a test run lists every case. This keeps that log on
# disk and prints about 30 lines: the status, the real errors and the executed counts. A test
# verdict comes from the result bundle or the xunit file, never from the console banner.
#
# Usage:
#   verify.sh [options] <step> [args]           # a step of the platform, listed below
#   verify.sh [options] agent-docs              # AGENTS.md, .claude/rules and this skill against the tree
#   verify.sh          tail   <log> [lines]     # re-read a stored log without rerunning
#   verify.sh          parse  <log>             # re-read the verdict for a stored log
#
# Options, accepted before or after the step:
#   --platform <name>  whose steps to run: lib/platform-<name>.sh beside this script (default: the
#                      one for this machine's operating system)
#   --run <dir>     run directory; logs go in <dir>/logs (default: <root>/.analysis/<branch>)
#   --root <dir>    repository root (default: the checkout the current directory is in, when it
#                   is this repository, else the checkout this script lives in)
#   --no-wait       do not wait for a concurrent build of the same checkout to finish
#   --offline       resolve dependencies without the network
#
# Exit: 0 pass, 1 fail, 2 inconclusive (a named environment cause, not the change), 3 usage error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# Called by absolute path from a worktree, this script would otherwise verify the main checkout.
caller_root="$(git rev-parse --show-toplevel 2> /dev/null)"
if [ -n "$caller_root" ] && [ "$caller_root" != "$REPO_ROOT" ] \
    && [ "$(git -C "$caller_root" rev-parse --path-format=absolute --git-common-dir 2> /dev/null)" \
        = "$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2> /dev/null)" ]; then
    REPO_ROOT="$caller_root"
fi
RUN_DIR=""
PLATFORM=""
PLATFORM_GIVEN=0
BACKEND=""
HELP=0
WAIT_FOR_BUILD=1
OFFLINE=0

# -h exits 0; any other usage error exits 3, which a caller can tell apart from a verdict.
header_of() {
    awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$1"
}

usage() {
    header_of "${BASH_SOURCE[0]}"
    [ -n "$BACKEND" ] && [ -f "$BACKEND" ] && header_of "$BACKEND"
    exit "${1:-3}"
}

need_value() {
    [ "$1" -ge 2 ] || { echo "$2 needs a value" >&2; usage; }
}

# Options are read before or after the step, so a trailing option never becomes a step argument.
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --run) need_value $# "--run"; RUN_DIR="$2"; shift 2 ;;
        --root)
            need_value $# "--root"
            REPO_ROOT="$(cd "$2" 2> /dev/null && pwd)" || { echo "--root: no such directory: $2" >&2; exit 3; }
            [ -n "$REPO_ROOT" ] || { echo "--root: no such directory: $2" >&2; exit 3; }
            shift 2
            ;;
        --platform) need_value $# "--platform"; PLATFORM="$2"; PLATFORM_GIVEN=1; shift 2 ;;
        --no-wait) WAIT_FOR_BUILD=0; shift ;;
        --offline) OFFLINE=1; shift ;;
        -h | --help) HELP=1; shift ;;
        --*) echo "unknown option: $1" >&2; usage ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
# bash 3.2 treats an unset array as unbound under `set -u`, so an options-only run needs the guard.
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

# The default platform is the one this machine can build, which is its operating system.
if [ -z "$PLATFORM" ]; then
    case "$(uname -s)" in
        Darwin) PLATFORM=apple ;;
        Linux) PLATFORM=linux ;;
        MINGW* | MSYS* | CYGWIN*) PLATFORM=windows ;;
    esac
fi
BACKEND="$SCRIPT_DIR/lib/platform-$PLATFORM.sh"

[ "$HELP" -eq 1 ] && usage 0
[ $# -ge 1 ] || usage
STEP="$1"; shift

if [ -z "$RUN_DIR" ]; then
    branch="$(git -C "$REPO_ROOT" branch --show-current 2> /dev/null || echo detached)"
    RUN_DIR="$REPO_ROOT/.analysis/${branch//\//-}"
fi
LOG_DIR="$RUN_DIR/logs"
# `parse` and `tail` read an existing log, so they create no logs/ directory.
case "$STEP" in
    parse | tail) ;;
    *) mkdir -p "$LOG_DIR" ;;
esac

# ---------------------------------------------------------------------------- reporting helpers

STATUS=""
NOTES=("")

note() { NOTES=("${NOTES[@]}" "$1"); }

# The verdict is written beside the log: part of what decides it, like the exit code, is not in the log.
emit() {
    local log="$1" exit_code="$2" receipt=""
    [ -n "$log" ] && [ "$STEP" != "parse" ] && receipt="$log.verdict"
    {
        echo "step: $STEP ${STEP_DETAIL:-}"
        echo "root: $REPO_ROOT"
        echo "status: $STATUS"
        [ "$exit_code" != "-" ] && echo "exit: $exit_code"
        if [ -n "$log" ]; then
            echo "log: $log ($(wc -l < "$log" | tr -d ' ') lines)"
        fi
        local n
        for n in "${NOTES[@]:-}"; do
            [ -n "$n" ] && echo "$n"
        done
    } | if [ -n "$receipt" ]; then tee "$receipt"; else cat; fi
    case "$STATUS" in
        PASS) exit 0 ;;
        INCONCLUSIVE) exit 2 ;;
        *) exit 1 ;;
    esac
}

# Two steps can start in the same second; neither may overwrite the other's log.
new_log() {
    local base n=1
    base="$LOG_DIR/$1-$(date +%H%M%S)"
    [ -e "$base.log" ] || { printf '%s.log' "$base"; return; }
    while [ -e "$base-$n.log" ]; do n=$((n + 1)); done
    printf '%s-%s.log' "$base" "$n"
}

waits_for_other_builds() { [ "$WAIT_FOR_BUILD" -eq 1 ]; }
is_offline() { [ "$OFFLINE" -eq 1 ]; }

run_logged() {
    local log="$1"; shift
    "$@" > "$log" 2>&1
    return $?
}

# A missing tool is the machine, not the change.
require_tool() {
    command -v "$1" > /dev/null 2>&1 && return 0
    STATUS=INCONCLUSIVE
    note "cause: $1 is not installed on this machine. Nothing was run."
    emit "" 2
}

available_platforms() {
    local file names=""
    for file in "$SCRIPT_DIR"/lib/platform-*.sh; do
        [ -f "$file" ] || continue
        file="${file##*/platform-}"
        names="$names ${file%.sh}"
    done
    printf '%s' "${names# }"
}

# A platform named on the command line with no backend is a typo; one picked from the operating
# system is a checkout this machine cannot verify, which says nothing about the change.
load_platform() {
    if [ ! -f "$BACKEND" ]; then
        if [ "$PLATFORM_GIVEN" -eq 1 ]; then
            echo "unknown platform: $PLATFORM (this checkout has: $(available_platforms))" >&2
            exit 3
        fi
        STATUS=INCONCLUSIVE
        note "cause: this checkout has no steps for ${PLATFORM:-this operating system} (it has: $(available_platforms)). Nothing was run."
        note "  run the step on a machine that builds that platform, or name one with --platform"
        emit "" 2
    fi
    # shellcheck source=/dev/null
    . "$BACKEND"
}

# ---------------------------------------------------------------------------- steps

case "$STEP" in
    tail)
        [ $# -ge 1 ] || usage
        [ -f "$1" ] || { echo "no such log: $1" >&2; exit 3; }
        tail -n "${2:-60}" "$1"
        exit 0
        ;;

    parse)
        [ $# -ge 1 ] || usage
        [ -f "$1" ] || { echo "no such log: $1" >&2; exit 3; }
        if [ -f "$1.verdict" ]; then
            cat "$1.verdict"
            case "$(sed -n 's/^status: //p' "$1.verdict")" in
                PASS) exit 0 ;;
                INCONCLUSIVE) exit 2 ;;
                *) exit 1 ;;
            esac
        fi
        STEP_DETAIL="$1"
        load_platform
        platform_parse "$1"
        emit "$1" "-"
        ;;

    agent-docs)
        # Kept out of `lint`, so one stale reference on main never turns a code lint red.
        log="$(new_log agent-docs)"
        run_logged "$log" "$REPO_ROOT/scripts/check-doc-symbols.sh"
        code=$?
        if [ $code -eq 0 ]; then
            STATUS=PASS
            note "$(tail -1 "$log")"
        else
            STATUS=FAIL
            note "$(grep -E '^(CLAUDE|AGENTS|\.claude)' "$log" | sed 's/^/  /' | head -10)"
        fi
        emit "$log" $code
        ;;

    *)
        load_platform
        platform_step "$@"
        ;;
esac
