#!/usr/bin/env bash
#
# Run one TablePro verification step, store the full output on disk, and print a short verdict.
#
# The point is context economy: a Debug build prints thousands of lines and a test run enumerates
# every case, which is unreadable and crowds out the work. This keeps the full log on disk and
# prints at most ~30 lines: status, the real errors, test counts, and whether a failure is one of
# the known false alarms in this checkout.
#
# Usage:
#   verify.sh [options] generate
#   verify.sh [options] build [Scheme]          # default scheme: TablePro
#   verify.sh [options] plugins                 # AllPlugins aggregate
#   verify.sh [options] test  <Suite> [Suite…]
#   verify.sh [options] uitest <Suite> [Suite…]
#   verify.sh [options] abi   <merge-base>
#   verify.sh [options] lint  <path> [path…]
#   verify.sh          tail   <log> [lines]     # re-read a stored log without rerunning
#   verify.sh          parse  <log>             # re-read the verdict for a stored log
#
# Options:
#   --run <dir>     run directory for logs (default: <repo>/.analysis/<branch>)
#   --root <dir>    repository root (default: the checkout this script lives in)
#   --no-wait       do not wait for a concurrent xcodebuild to finish
#   --offline       pin SwiftPM to Package.resolved
#
# Exit: 0 pass, 1 fail, 2 inconclusive (environment, not the change), 3 usage error.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
RUN_DIR=""
WAIT_FOR_XCODEBUILD=1
OFFLINE=0
MAX_WAIT_SECONDS=1800

# Suites that fail on this machine for environment reasons and are not in the CI quarantine file.
# Source: .claude/skills/fix-issue/references/verification.md ("Test", rule 3).
KNOWN_ENV_FAILURES="StatusBarSnapshotTests RowOperationsManagerBinaryCopyTests AWSSSOFetchTests SSEEventStreamTests CopilotIdleStopControllerTests"

# Asking for help is not a usage error, so -h exits 0. Anything else exits 3, which a caller
# running under `set -e` can distinguish from a real verdict.
usage() {
    awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit "${1:-3}"
}

need_value() {
    [ "$1" -ge 2 ] || { echo "$2 needs a value" >&2; usage; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --run) need_value $# "--run"; RUN_DIR="$2"; shift 2 ;;
        --root)
            need_value $# "--root"
            # Without this check a bad path leaves REPO_ROOT empty, and the run then builds and
            # reports on a tree that is not the one asked for.
            REPO_ROOT="$(cd "$2" 2> /dev/null && pwd)" || { echo "--root: no such directory: $2" >&2; exit 3; }
            [ -n "$REPO_ROOT" ] || { echo "--root: no such directory: $2" >&2; exit 3; }
            shift 2
            ;;
        --no-wait) WAIT_FOR_XCODEBUILD=0; shift ;;
        --offline) OFFLINE=1; shift ;;
        -h | --help) usage 0 ;;
        --*) echo "unknown option: $1" >&2; usage ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || usage
STEP="$1"; shift

if [ -z "$RUN_DIR" ]; then
    branch="$(git -C "$REPO_ROOT" branch --show-current 2> /dev/null || echo detached)"
    RUN_DIR="$REPO_ROOT/.analysis/${branch//\//-}"
fi
LOG_DIR="$RUN_DIR/logs"
# Only the steps that produce a log create the directory. `parse` and `tail` read an existing
# log and used to leave an empty logs/ tree wherever --run pointed.
case "$STEP" in
    parse | tail) ;;
    *) mkdir -p "$LOG_DIR" ;;
esac

# ---------------------------------------------------------------------------- reporting helpers

STATUS=""
NOTES=("")

note() { NOTES=("${NOTES[@]}" "$1"); }

emit() {
    local log="$1" exit_code="$2"
    echo "step: $STEP ${STEP_DETAIL:-}"
    echo "status: $STATUS"
    [ "$exit_code" != "-" ] && echo "exit: $exit_code"
    if [ -n "$log" ]; then
        echo "log: $log ($(wc -l < "$log" | tr -d ' ') lines)"
    fi
    local n
    for n in "${NOTES[@]:-}"; do
        [ -n "$n" ] && echo "$n"
    done
    case "$STATUS" in
        PASS) exit 0 ;;
        INCONCLUSIVE) exit 2 ;;
        *) exit 1 ;;
    esac
}

# Known false failures in this checkout. Each one presents as a code defect and is not one.
diagnose_environment() {
    local log="$1" found=1
    if grep -q 'build database .* is locked\|two concurrent builds running' "$log" 2> /dev/null; then
        note "cause: another xcodebuild holds the build database. Not your change. Rerun when it exits."
        found=0
    fi
    if grep -q 'produced no further output' "$log" 2> /dev/null; then
        note "cause: the Swift frontend crashed without a diagnostic. Flaky on this machine. Rerun before believing any 'cannot find type' error."
        found=0
    fi
    if grep -q "Could not resolve package dependencies\|Couldn't fetch updates from remote" "$log" 2> /dev/null; then
        note "cause: SwiftPM tried to reach the network. Rerun with --offline to pin Package.resolved."
        found=0
    fi
    if grep -q 'Unable to open base configuration reference file' "$log" 2> /dev/null; then
        note "cause: Secrets.xcconfig is missing from this checkout. A fresh worktree needs it symlinked from the main checkout."
        found=0
    fi
    if grep -q 'The test runner hung before establishing connection' "$log" 2> /dev/null; then
        note "cause: the XCTest host wedged before running anything. Check the executed count below."
        found=0
    fi
    return $found
}

report_errors() {
    local log="$1"
    local errors
    errors="$(grep -E '(^|[^a-zA-Z])error: ' "$log" 2> /dev/null \
        | sed 's/^.*\/\([^/]*\.swift:[0-9]*:[0-9]*\)/\1/' \
        | sort -u | head -12)"
    if [ -n "$errors" ]; then
        echo "errors:"
        printf '%s\n' "$errors" | sed 's/^/  /'
        local total
        total="$(grep -cE '(^|[^a-zA-Z])error: ' "$log" 2> /dev/null)"
        [ "$total" -gt 12 ] && echo "  … $((total - 12)) more, see the log"
    fi
}

# ---------------------------------------------------------------------------- environment

setup_toolchain() {
    if [ ! -x "${DEVELOPER_DIR:-/nonexistent}/usr/bin/xcodebuild" ]; then
        if [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
            export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
        elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        fi
    fi
}

wait_for_free_toolchain() {
    [ "$WAIT_FOR_XCODEBUILD" -eq 1 ] || return 0
    pgrep -f 'Developer/usr/bin/xcodebuild' > /dev/null 2>&1 || return 0
    echo "waiting: another xcodebuild is running in this checkout" >&2
    local waited=0
    while pgrep -f 'Developer/usr/bin/xcodebuild' > /dev/null 2>&1; do
        sleep 10
        waited=$((waited + 10))
        if [ "$waited" -ge "$MAX_WAIT_SECONDS" ]; then
            STATUS=INCONCLUSIVE
            note "cause: a concurrent xcodebuild ran for over $((MAX_WAIT_SECONDS / 60)) minutes. Nothing was run."
            emit "" 2
        fi
    done
}

xcodebuild_flags() {
    printf '%s' "-skipPackagePluginValidation"
    [ "$OFFLINE" -eq 1 ] && printf ' %s' "-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile"
}

new_log() {
    printf '%s/%s-%s.log' "$LOG_DIR" "$1" "$(date +%H%M%S)"
}

# ---------------------------------------------------------------------------- test reporting

# Cross-references failing suites against the CI quarantine and the known-env list so a red run
# is reported as "N new failures", not "N failures".
PASS_PATTERN="^test case .* passed|✔ test .* passed"
FAIL_PATTERN="^test case .* failed|✘ test .* (failed|recorded an issue)"

report_tests() {
    local log="$1"
    local passed failed executed
    passed="$(grep -ciE "$PASS_PATTERN" "$log" 2> /dev/null)"
    failed="$(grep -ciE "$FAIL_PATTERN" "$log" 2> /dev/null)"
    executed=$((passed + failed))
    note "cases: $executed executed, $passed passed, $failed failed"

    if [ "$executed" -eq 0 ]; then
        STATUS=INCONCLUSIVE
        note "cause: zero cases executed. The filter matched nothing, or the host wedged. A -only-testing filter naming a Swift Testing @Test function silently matches nothing and still prints TEST SUCCEEDED. Filter by suite."
        return
    fi
    if [ "$failed" -eq 0 ]; then
        STATUS=PASS
        return
    fi

    local quarantine="$REPO_ROOT/.github/macos-test-quarantine.txt"
    local ui_quarantine="$REPO_ROOT/.github/macos-ui-test-quarantine.txt"
    local suites
    suites="$(grep -iE "$FAIL_PATTERN" "$log" 2> /dev/null \
        | grep -oE "[A-Za-z_][A-Za-z0-9_]*Tests" \
        | grep -vxE "TableProTests|TableProUITests" \
        | sort -u)"

    if [ -z "$suites" ]; then
        STATUS=FAIL
        note "failing cases (no suite name on the line, read the log):"
        note "$(grep -iE "$FAIL_PATTERN" "$log" 2> /dev/null | sed 's/^/  /' | head -10)"
        return
    fi

    local new_suites="" muted=0 suite
    for suite in $suites; do
        if [ -f "$quarantine" ] && grep -qx "$suite" "$quarantine" 2> /dev/null; then
            muted=$((muted + 1))
        elif [ -f "$ui_quarantine" ] && grep -q "^$suite/" "$ui_quarantine" 2> /dev/null; then
            muted=$((muted + 1))
        elif [[ " $KNOWN_ENV_FAILURES " == *" $suite "* ]]; then
            muted=$((muted + 1))
        else
            new_suites="$new_suites $suite"
        fi
    done

    [ "$muted" -gt 0 ] && note "muted: $muted failing suite(s) are quarantined or known environment failures"
    if [ -z "$new_suites" ]; then
        STATUS=PASS
        note "verdict: no unexplained failures. Every failing suite is already red on this machine."
    else
        STATUS=FAIL
        note "new failures:$new_suites"
        note "$(grep -iE "$FAIL_PATTERN" "$log" 2> /dev/null | sed 's/^/  /' | head -10)"
    fi
}

# ---------------------------------------------------------------------------- steps

run_logged() {
    local log="$1"; shift
    "$@" > "$log" 2>&1
    return $?
}

case "$STEP" in
    tail)
        [ $# -ge 1 ] || usage
        # A mistyped path used to print the shell's error and still exit 0, which reads as success.
        [ -f "$1" ] || { echo "no such log: $1" >&2; exit 3; }
        tail -n "${2:-60}" "$1"
        exit 0
        ;;

    parse)
        [ $# -ge 1 ] || usage
        [ -f "$1" ] || { echo "no such log: $1" >&2; exit 3; }
        STEP_DETAIL="$1"
        STATUS=PASS
        grep -q '^\*\* \(BUILD\|TEST\) FAILED \*\*' "$1" 2> /dev/null && STATUS=FAIL

        # Treat anything that looks like a test run as one, not only a log that already has case
        # lines. A wedged host prints TEST SUCCEEDED with zero cases, and keying on case lines
        # meant report_tests never ran, so that log parsed as a pass.
        if grep -qiE "$PASS_PATTERN|$FAIL_PATTERN|^Test Suite |-only-testing:|^\*\* TEST (SUCCEEDED|FAILED) \*\*" "$1" 2> /dev/null; then
            report_tests "$1"
        else
            parse_errors="$(report_errors "$1")"
            if [ -n "$parse_errors" ]; then
                note "$parse_errors"
                # swiftlint and other non-xcodebuild tools never print the ** BUILD FAILED **
                # banner, so without this a lint log full of errors reported PASS and exit 0.
                STATUS=FAIL
            fi
        fi

        # An environment cause outranks whatever the log appears to say, because the run did not
        # get far enough to be evidence about the change. This runs last so nothing overwrites it.
        diagnose_environment "$1" && STATUS=INCONCLUSIVE
        emit "$1" "-"
        ;;

    generate)
        STEP_DETAIL=""
        setup_toolchain
        log="$(new_log generate)"
        run_logged "$log" "$REPO_ROOT/scripts/generate-project.sh"
        code=$?
        if [ $code -eq 0 ]; then
            STATUS=PASS
        else
            STATUS=FAIL
            note "$(tail -5 "$log" | sed 's/^/  /')"
        fi
        emit "$log" $code
        ;;

    build | plugins)
        scheme="TablePro"
        [ "$STEP" = "plugins" ] && scheme="AllPlugins"
        [ $# -ge 1 ] && [ "$STEP" = "build" ] && scheme="$1"
        STEP_DETAIL="$scheme"
        setup_toolchain
        wait_for_free_toolchain
        log="$(new_log "build-$scheme")"
        # shellcheck disable=SC2046
        run_logged "$log" xcodebuild -project "$REPO_ROOT/TablePro.xcodeproj" -scheme "$scheme" \
            -configuration Debug build $(xcodebuild_flags)
        code=$?
        if grep -q '^\*\* BUILD SUCCEEDED \*\*' "$log" 2> /dev/null; then
            STATUS=PASS
        elif diagnose_environment "$log"; then
            STATUS=INCONCLUSIVE
        else
            STATUS=FAIL
            note "$(report_errors "$log")"
        fi
        emit "$log" $code
        ;;

    test | uitest)
        [ $# -ge 1 ] || usage
        target="TableProTests"
        [ "$STEP" = "uitest" ] && target="TableProUITests"
        STEP_DETAIL="$target: $*"
        setup_toolchain
        wait_for_free_toolchain
        filters=()
        for suite in "$@"; do filters+=("-only-testing:$target/$suite"); done
        log="$(new_log "test-${1}")"
        # shellcheck disable=SC2046
        run_logged "$log" xcodebuild -project "$REPO_ROOT/TablePro.xcodeproj" -scheme TablePro \
            test $(xcodebuild_flags) "${filters[@]}"
        code=$?
        # report_tests owns the verdict on this path, so reading the TEST SUCCEEDED banner here
        # was dead: it was always overwritten. Keep the environment answer instead, which the
        # build path already honours and this path used to discard.
        env_failed=1
        diagnose_environment "$log" && env_failed=0

        if grep -qE '(^|[^a-zA-Z])error: ' "$log" 2> /dev/null && ! grep -qiE "$PASS_PATTERN|$FAIL_PATTERN" "$log" 2> /dev/null; then
            STATUS=FAIL
            note "cause: the test target failed to build. The errors below are compile errors, not test failures."
            note "$(report_errors "$log")"
            [ "$env_failed" -eq 0 ] && STATUS=INCONCLUSIVE
            emit "$log" $code
        fi

        report_tests "$log"
        [ "$env_failed" -eq 0 ] && STATUS=INCONCLUSIVE
        emit "$log" $code
        ;;

    abi)
        [ $# -ge 1 ] || usage
        STEP_DETAIL="merge-base $1"
        setup_toolchain
        log="$(new_log abi)"
        run_logged "$log" "$REPO_ROOT/scripts/check-pluginkit-abi.sh" "$1"
        code=$?
        if [ $code -eq 0 ]; then
            STATUS=PASS
        else
            STATUS=FAIL
            note "$(tail -15 "$log" | sed 's/^/  /')"
        fi
        emit "$log" $code
        ;;

    lint)
        [ $# -ge 1 ] || usage
        STEP_DETAIL="$# path(s)"
        setup_toolchain
        log="$(new_log lint)"
        run_logged "$log" swiftlint lint --strict "$@"
        code=$?
        if grep -q 'Loading sourcekitdInProc.framework .* failed' "$log" 2> /dev/null; then
            STATUS=INCONCLUSIVE
            note "cause: SwiftLint could not load sourcekitd. DEVELOPER_DIR is not pointing at a full Xcode."
        elif [ $code -eq 0 ]; then
            STATUS=PASS
            note "violations: 0"
        else
            STATUS=FAIL
            note "$(grep -E ':[0-9]+:[0-9]+: (error|warning):' "$log" 2> /dev/null | sed 's/^/  /' | head -15)"
        fi

        # Lint the agent-facing docs in the same pass. They are instructions the next run acts on,
        # so a stale symbol there is a defect the same way a lint violation is, and it is the one
        # class of defect nothing else in this repo catches.
        doc_check="$REPO_ROOT/scripts/check-doc-symbols.sh"
        if [ -x "$doc_check" ]; then
            doc_out="$("$doc_check" 2>&1)"
            doc_code=$?
            if [ "$doc_code" -ne 0 ]; then
                [ "$STATUS" = "PASS" ] && STATUS=FAIL
                note "docs: $(printf '%s' "$doc_out" | tail -3 | head -1)"
                note "$(printf '%s' "$doc_out" | grep -E '^(CLAUDE|\.claude)' | sed 's/^/  /' | head -10)"
                note "  run scripts/check-doc-symbols.sh for the full list"
            else
                note "docs: $(printf '%s' "$doc_out" | tail -1)"
            fi
        fi
        emit "$log" $code
        ;;

    *)
        echo "unknown step: $STEP" >&2
        usage
        ;;
esac
