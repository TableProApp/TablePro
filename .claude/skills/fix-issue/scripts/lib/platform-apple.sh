# shellcheck shell=bash
# shellcheck disable=SC2034
#
# Steps on the Apple platform (the macOS app, its plugins and packages, the iOS app):
#   verify.sh [options] generate
#   verify.sh [options] build [Scheme]          # default scheme: TablePro
#   verify.sh [options] plugins                 # AllPlugins aggregate
#   verify.sh [options] test  <Suite> [Suite…]
#   verify.sh [options] uitest <Suite> [Suite…]
#   verify.sh [options] package <Package> [filter]   # swift test in Packages/<Package>
#   verify.sh [options] ios <Suite> [Suite…]         # TableProMobileTests on a simulator
#   verify.sh [options] abi   <merge-base>
#   verify.sh [options] lint  <path> [path…]
#   verify.sh [options] docs [docs-checkout]    # TableProApp/docs checks against this tree (default ../tablepro-docs)
#   verify.sh [options] l10n                    # plugin and package strings in the app catalog, managed manually
#
# Here --no-wait skips the wait for another xcodebuild, and --offline pins SwiftPM to Package.resolved.

# Sourced by verify.sh, which owns the options, the log and the verdict. A backend defines
# platform_step, which runs one step and ends in emit, and platform_parse, which re-derives a
# verdict from a stored log that has no receipt. STEP_DETAIL is read by emit over there, which is
# all SC2034 is off for.

MAX_WAIT_SECONDS=1800

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
    [ -x "${DEVELOPER_DIR:-/nonexistent}/usr/bin/xcodebuild" ] && return 0
    # The Xcode that xcode-select names wins when it is a full Xcode. Command Line Tools has no
    # xcodebuild and no sourcekitd, so fall back to whichever Xcode is installed.
    local candidate
    for candidate in "$(xcode-select -p 2> /dev/null)" \
        /Applications/Xcode.app/Contents/Developer \
        /Applications/Xcode-beta.app/Contents/Developer; do
        if [ -x "$candidate/usr/bin/xcodebuild" ]; then
            export DEVELOPER_DIR="$candidate"
            return 0
        fi
    done
}

# Only a build of THIS checkout contends: every worktree builds into its own DerivedData, so a
# machine-wide wait stalled a worktree run for as long as a peer session built somewhere else.
# A build belongs here when it names this checkout's project or runs from its root.
checkout_busy() {
    local pid
    for pid in $(pgrep -f 'Developer/usr/bin/xcodebuild' 2> /dev/null); do
        ps -o args= -p "$pid" 2> /dev/null | grep -qF "$REPO_ROOT/TablePro.xcodeproj" && return 0
        [ "$(lsof -a -p "$pid" -d cwd -Fn 2> /dev/null | sed -n 's/^n//p')" = "$REPO_ROOT" ] && return 0
    done
    return 1
}

wait_for_free_toolchain() {
    waits_for_other_builds || return 0
    checkout_busy || return 0
    echo "waiting: another xcodebuild is running in this checkout" >&2
    local waited=0
    while checkout_busy; do
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
    is_offline && printf ' %s' "-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile"
}

# ---------------------------------------------------------------------------- test reporting

# Mutes failing cases listed in the CI quarantine files, so a red run reports only the failures
# that are new.
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
        # A crash, a timeout or an unrecognised line format fails the run without a case line the
        # patterns above can count. This printed PASS over a log that said TEST FAILED.
        if grep -qE '^\*\* TEST FAILED \*\*|^Failing tests:' "$log" 2> /dev/null; then
            STATUS=FAIL
            note "cause: xcodebuild reported a failure that no counted case line names. Read the block below."
            note "$(grep -A 8 '^Failing tests:' "$log" 2> /dev/null | sed 's/^/  /' | head -10)"
            return
        fi
        STATUS=PASS
        return
    fi

    local quarantine="$REPO_ROOT/.github/macos-test-quarantine.txt"
    local ui_quarantine="$REPO_ROOT/.github/macos-ui-test-quarantine.txt"

    # Both quarantine files hold one case per line as Suite/case(), never a bare suite name, so a
    # failing line is matched by its own case id. Matching the suite instead did two wrong things
    # at once: it never matched the unit file at all, so every quarantined case was reported as a
    # new failure; and on the UI file it muted the whole suite, hiding a real regression sitting
    # beside a quarantined case.
    # xcodebuild prints a failing case in three spellings and the quarantine files use only the
    # last one, so every line is normalised to Suite/case() before the lookup:
    #   Test Case '-[TableProUITests.FooUITests testBar]' failed (1.0 seconds).   XCTest
    #   Test case 'FooUITests.testBar()' failed on 'My Mac' ...                   XCTest
    #   Test case 'FooTests/bar()' failed on 'My Mac' ...                         Swift Testing
    # Matching only the third muted nothing written by XCTest, which is every entry in the UI
    # quarantine file, so a clean uitest run reported both quarantined cases as new failures.
    local fail_lines unmuted muted_cases=0
    fail_lines="$(grep -iE "$FAIL_PATTERN" "$log" 2> /dev/null)"
    unmuted=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local case_id
        case_id="$(printf '%s\n' "$line" | sed -E \
            -e "s|.*'-\[[A-Za-z0-9_]+\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]'.*|\1/\2()|" \
            -e "s|.*'([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\(\)'.*|\1/\2()|" \
            -e "s|.*'([A-Za-z0-9_]+/[A-Za-z0-9_]+\(\))'.*|\1|")"
        # A line none of the three matched comes back unchanged, so require the normalised shape
        # before trusting it. Failing to extract must report the line, never mute it.
        case "$case_id" in
            *' '* | *'/'*'/'*) case_id="" ;;
            */*'()') ;;
            *) case_id="" ;;
        esac
        if [ -n "$case_id" ] \
            && { grep -qxF "$case_id" "$quarantine" 2> /dev/null \
                || grep -qxF "$case_id" "$ui_quarantine" 2> /dev/null; }; then
            muted_cases=$((muted_cases + 1))
            continue
        fi
        unmuted="$unmuted$line"$'\n'
    done <<< "$fail_lines"

    [ "$muted_cases" -gt 0 ] && note "muted: $muted_cases quarantined case(s)"

    local suites
    suites="$(printf '%s\n' "$unmuted" \
        | grep -oE "[A-Za-z_][A-Za-z0-9_]*Tests" \
        | grep -vxE "TableProTests|TableProUITests" \
        | sort -u)"

    if [ -z "$suites" ]; then
        if [ -z "${unmuted//[$'\n' ]/}" ]; then
            STATUS=PASS
            note "verdict: no unexplained failures. Every failing case is quarantined."
            return
        fi
        STATUS=FAIL
        note "failing cases (no suite name on the line, read the log):"
        note "$(printf '%s\n' "$unmuted" | sed 's/^/  /' | head -10)"
        return
    fi

    STATUS=FAIL
    note "failing suites: $(printf '%s ' $suites)"
    note "$(printf '%s\n' "$unmuted" | sed 's/^/  /' | head -10)"
}

# SwiftLint applies `.swiftlint.yml`'s `included:` to a DIRECTORY argument but not to a file
# argument, so `swiftlint lint --strict TableProTests` reports zero violations having linted
# nothing at all. Measured 2026-09-15: that command found 0 and `TableProTests/**/*.swift` found
# 1227. Name the directories a run was handed and then dropped, so a clean result is not read as
# coverage it never had.
swiftlint_filtered_dirs() {
    local config="$REPO_ROOT/.swiftlint.yml"
    [ -f "$config" ] || return 0
    local roots
    roots="$(awk '/^included:/ { inside = 1; next }
                  /^[A-Za-z_]+:/ { inside = 0 }
                  inside && /^[[:space:]]*-[[:space:]]*/ {
                      sub(/^[[:space:]]*-[[:space:]]*/, "")
                      gsub(/["'"'"']/, "")
                      print
                  }' "$config")"
    [ -n "$roots" ] || return 0
    local dropped="" path root covered
    for path in "$@"; do
        [ -d "$REPO_ROOT/$path" ] || continue
        covered=0
        for root in $roots; do
            case "${path%/}/" in
                "${root%/}/"*) covered=1 ;;
            esac
        done
        [ "$covered" -eq 1 ] || dropped="$dropped $path"
    done
    printf '%s' "${dropped# }"
}

# ---------------------------------------------------------------------------- steps

platform_parse() {
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
}

platform_step() {
    case "$STEP" in
        generate)
            STEP_DETAIL=""
            setup_toolchain
            require_tool xcodegen
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
            require_tool xcodebuild
            wait_for_free_toolchain
            log="$(new_log "build-$scheme")"
            : > "$log"
            # The HANA plugin embeds a Go helper that is built, not downloaded, so a fresh worktree has
            # none and AllPlugins fails on "has no arm64 slice" every time until someone builds it.
            helper="$REPO_ROOT/Native/HanaBridge/bin/tablepro-hana-helper"
            if [ "$scheme" = "AllPlugins" ] && [ ! -e "$helper" ] && command -v go > /dev/null; then
                "$REPO_ROOT/scripts/build-hana.sh" "$(uname -m)" >> "$log" 2>&1 \
                    && note "built the HANA helper first: $helper"
            fi
            # shellcheck disable=SC2046
            xcodebuild -project "$REPO_ROOT/TablePro.xcodeproj" -scheme "$scheme" \
                -configuration Debug build $(xcodebuild_flags) >> "$log" 2>&1
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
            require_tool xcodebuild
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
            require_tool xcodebuild
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
            require_tool swiftlint
            log="$(new_log lint)"
            filtered="$(swiftlint_filtered_dirs "$@")"
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
            if [ -n "$filtered" ]; then
                note "NOT LINTED, outside .swiftlint.yml included: $filtered"
                note "  a directory argument is filtered, a file argument is not: <dir>/**/*.swift"
            fi

            emit "$log" $code
            ;;

        package)
            [ $# -ge 1 ] || usage
            package_dir="$REPO_ROOT/Packages/$1"
            [ -f "$package_dir/Package.swift" ] || { echo "no such package: Packages/$1" >&2; exit 3; }
            STEP_DETAIL="$1${2:+ --filter $2}"
            setup_toolchain
            require_tool swift
            log="$(new_log "package-$1")"
            filter=()
            [ $# -ge 2 ] && filter=(--filter "$2")
            run_logged "$log" swift test --package-path "$package_dir" --force-resolved-versions ${filter[@]+"${filter[@]}"}
            code=$?
            report_tests "$log"
            # swift test exits non-zero for a compile error or a crash that leaves no case line.
            if [ $code -ne 0 ] && [ "$STATUS" = "PASS" ]; then
                STATUS=FAIL
                note "cause: swift test exited $code. The errors below are from the log."
                note "$(report_errors "$log")"
            fi
            diagnose_environment "$log" && STATUS=INCONCLUSIVE
            emit "$log" $code
            ;;

        ios)
            [ $# -ge 1 ] || usage
            STEP_DETAIL="TableProMobileTests: $*"
            setup_toolchain
            require_tool xcodebuild
            wait_for_free_toolchain
            log="$(new_log "ios-${1}")"
            : > "$log"
            project="$REPO_ROOT/TableProMobile/TableProMobile.xcodeproj"
            if [ ! -d "$project" ]; then
                "$REPO_ROOT/scripts/generate-project.sh" ios >> "$log" 2>&1
            fi
            # CI names one simulator; this machine may not have it, so take the first available iPhone.
            simulator="$(xcrun simctl list devices available 2> /dev/null \
                | grep -m1 -oE 'iPhone[^(]*\([0-9A-F-]{36}\)' | grep -oE '[0-9A-F-]{36}')"
            if [ -z "$simulator" ]; then
                STATUS=INCONCLUSIVE
                note "cause: no available iPhone simulator. Nothing was run."
                emit "$log" 2
            fi
            filters=()
            for suite in "$@"; do filters+=("-only-testing:TableProMobileTests/$suite"); done
            xcodebuild test -project "$project" -scheme TableProMobile -destination "id=$simulator" \
                -parallel-testing-enabled NO -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
                "${filters[@]}" >> "$log" 2>&1
            code=$?
            report_tests "$log"
            diagnose_environment "$log" && STATUS=INCONCLUSIVE
            emit "$log" $code
            ;;

        l10n)
            # Plugin strings live in the app's catalog, and CI fails a PR whose new plugin message is
            # missing from it or not managed manually, which neither a build nor SwiftLint notices.
            log="$(new_log l10n)"
            : > "$log"
            code=0
            echo "== localization.py plugins" >> "$log"
            (cd "$REPO_ROOT" && python3 scripts/localization.py plugins) >> "$log" 2>&1 || code=1
            if [ $code -eq 0 ]; then
                STATUS=PASS
            else
                STATUS=FAIL
                note "$(grep -vE '^==' "$log" | tail -12 | sed 's/^/  /')"
                note "  plugin strings: python3 scripts/localization.py plugins --add"
            fi
            emit "$log" $code
            ;;

        docs)
            # The docs live in TableProApp/docs, whose CI checks them against the app's main only. Run
            # here with --app pointed at this tree, the same checks say whether a paired docs change
            # passes once this branch merges, and whether this branch breaks a page that is already live.
            log="$(new_log docs)"
            : > "$log"
            code=0
            main_checkout="$(dirname "$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)")"
            docs_root="${1:-$(dirname "$main_checkout")/tablepro-docs}"
            if [ ! -f "$docs_root/docs.json" ]; then
                STATUS=INCONCLUSIVE
                note "no TableProApp/docs checkout at $docs_root: clone https://github.com/TableProApp/docs there, or pass its path"
            else
                {
                    (cd "$docs_root" && bash scripts/check-writing-style.sh "$REPO_ROOT") || code=1
                    (cd "$docs_root" && python3 scripts/check-docs-against-source.py --app "$REPO_ROOT") || code=1
                    (cd "$docs_root" && python3 scripts/check-links.py --app "$REPO_ROOT") || code=1
                } >> "$log" 2>&1
                if [ $code -eq 0 ]; then
                    STATUS=PASS
                    note "$docs_root: house style, source claims and links all agree with this tree"
                else
                    STATUS=FAIL
                    # The scripts print one line per check, most of them "ok". Show the failing check
                    # and the file:line under it, not the twenty passes above it.
                    note "$(grep -A 2 -E '^ *FAIL' "$log" 2> /dev/null | sed 's/^/  /' | head -15)"
                    note "$(grep -E 'contradict|house style' "$log" 2> /dev/null | sed 's/^/  /' | head -3)"
                fi
                note "STYLE.md rules no script enforces: see AGENTS.md in $docs_root"
            fi
            emit "$log" $code
            ;;

        *)
            echo "unknown step: $STEP" >&2
            usage
            ;;
    esac
}
