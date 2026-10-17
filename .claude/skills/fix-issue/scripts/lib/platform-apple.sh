# shellcheck shell=bash
# shellcheck disable=SC2034
#
# Steps on the Apple platform (the macOS app, its plugins and packages, the iOS app):
#   verify.sh [options] generate
#   verify.sh [options] build [Scheme]          # default scheme: TablePro
#   verify.sh [options] plugins                 # AllPlugins aggregate
#   verify.sh [options] test   [Test...]        # TestPlans/Unit.xctestplan, all of it when no Test is named
#   verify.sh [options] uitest [Test...]        # TestPlans/UI.xctestplan, all of it when no Test is named
#   verify.sh [options] package <Package> [regex]    # swift test in Packages/<Package>
#   verify.sh [options] ios <Suite> [Suite...]       # TableProMobileTests on a simulator
#   verify.sh [options] abi   <merge-base>
#   verify.sh [options] lint  <path> [path...]
#   verify.sh [options] docs [docs-checkout]    # TableProApp/docs checks against this tree (default ../tablepro-docs)
#   verify.sh [options] l10n                    # plugin and package strings in the mac and ios catalogs
#
# A Test is Suite, Suite/case(), or either behind its target name (TableProGrammarsTests/Suite).
# A bare Suite is a Swift type name, looked up in every test target of the tree.
# A test target no plan lists (TableProCore, TableProOracle) runs under swift test, not xcodebuild.
# `test` with no Test runs the Unit plan only; those two packages run with `package <Package>`.
# A name no target declares exits 3 before anything builds. A Test that runs nothing is FAIL.
# Here --no-wait skips the wait for another xcodebuild, and --offline pins SwiftPM to Package.resolved.

MAX_WAIT_SECONDS=1800

# Known false failures in this checkout. Each one presents as a code defect and is not one.
diagnose_environment() {
    local log="$1" found=1
    if grep -q 'build database .* is locked\|two concurrent builds running' "$log" 2> /dev/null; then
        note "cause: another xcodebuild holds the build database. Not your change. Rerun when it exits."
        found=0
    fi
    if grep -q 'produced no further output' "$log" 2> /dev/null; then
        note "cause: the Swift frontend crashed without a diagnostic. Rerun before believing any 'cannot find type' error."
        found=0
    fi
    if grep -q "Could not resolve package dependencies\|Couldn't fetch updates from remote" "$log" 2> /dev/null; then
        note "cause: SwiftPM tried to reach the network. Rerun with --offline to pin Package.resolved."
        found=0
    fi
    if grep -q 'Unable to open base configuration reference file' "$log" 2> /dev/null; then
        note "cause: the generated project names an xcconfig this checkout lacks. Rerun scripts/generate-project.sh (verify.sh generate)."
        found=0
    fi
    if grep -q 'The test runner hung before establishing connection' "$log" 2> /dev/null; then
        note "cause: the XCTest host wedged before running anything."
        found=0
    fi
    if grep -q 'Timed out while enabling automation mode\|failed to initialize for UI testing' "$log" 2> /dev/null; then
        note "cause: Automation Mode is off and XCTest could not turn it on. automationmodetool prints whether enabling it needs an admin password; the remedy is in references/verification-apple.md, INCONCLUSIVE."
        found=0
    fi
    return $found
}

report_errors() {
    local log="$1" errors total
    errors="$(grep -E '(^|[^a-zA-Z])error: ' "$log" 2> /dev/null \
        | sed 's/^.*\/\([^/]*\.swift:[0-9]*:[0-9]*\)/\1/' \
        | sort -u | head -12)"
    [ -n "$errors" ] || return 0
    echo "errors:"
    printf '%s\n' "$errors" | sed 's/^/  /'
    total="$(grep -cE '(^|[^a-zA-Z])error: ' "$log" 2> /dev/null)"
    [ "$total" -gt 12 ] && echo "  ... $((total - 12)) more, see the log"
}

# ---------------------------------------------------------------------------- environment

setup_toolchain() {
    [ -x "${DEVELOPER_DIR:-/nonexistent}/usr/bin/xcodebuild" ] && return 0
    # Command Line Tools has no xcodebuild and no sourcekitd, so fall back to an installed Xcode.
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

# Every worktree builds into its own DerivedData, so only a build of this checkout contends.
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

# ---------------------------------------------------------------------------- test selection

# One line per test target, "<target><TAB><route>": the plan that lists it (Unit, UI), or
# swift:<Package> for a package test target no plan lists.
test_targets_table() {
    local plan manifest package target table=""
    for plan in Unit UI; do
        [ -f "$REPO_ROOT/TestPlans/$plan.xctestplan" ] || continue
        table="$table$(jq -r --arg plan "$plan" '.testTargets[].target.name + "\t" + $plan' \
            "$REPO_ROOT/TestPlans/$plan.xctestplan")"$'\n'
    done
    for manifest in "$REPO_ROOT"/Packages/*/Package.swift; do
        [ -f "$manifest" ] || continue
        package="${manifest%/Package.swift}"
        package="${package##*/}"
        for target in $(awk '/\.testTarget\(/ { t = 1 }
                t && /name:/ { if (match($0, /"[^"]+"/)) print substr($0, RSTART + 1, RLENGTH - 2); t = 0 }' "$manifest"); do
            case $'\n'"$table" in
                *$'\n'"$target"$'\t'*) ;;
                *) table="$table$target"$'\t'"swift:$package"$'\n' ;;
            esac
        done
    done
    printf '%s' "$table"
}

route_of() {
    printf '%s' "$TEST_TARGETS" | awk -F'\t' -v t="$1" '$1 == t { print $2; exit }'
}

# The test targets that declare a type named $1, one per line. A file outside every known target
# prints as ?<directory>.
targets_declaring() {
    local file part target
    git -C "$REPO_ROOT" grep --untracked -l -E \
        "^[^/\"]*(struct|class|enum|actor|extension)[[:space:]]+$1([^A-Za-z0-9_]|\$)" -- '*Tests/*.swift' 2> /dev/null \
        | while IFS= read -r file; do
            target=""
            IFS=/ read -r -a parts <<< "$file"
            for part in "${parts[@]}"; do
                [ -n "$(route_of "$part")" ] && { target="$part"; break; }
            done
            printf '%s\n' "${target:-?${file%/*}}"
        done | sort -u
}

# Sets TARGET, TEST_PATH and ROUTE for one Test argument, or says why it cannot and fails.
resolve_test() {
    local first="${1%%/*}" rest="" found known
    [ "$first" = "$1" ] || rest="${1#*/}"
    case "$first" in
        '' | *[!A-Za-z0-9_]*) echo "not a test name: $1" >&2; return 1 ;;
    esac
    TARGET="" TEST_PATH="$rest"
    # TableProGrammarsTests/case() names a suite that shares its target's name, not a target.
    if [ -n "$(route_of "$first")" ] \
        && ! { [ -n "$rest" ] && [ "${rest#*/}" = "$rest" ] && [ "${rest%)}" != "$rest" ]; }; then
        TARGET="$first"
    else
        found="$(targets_declaring "$first")"
        known="$(grep -v '^?' <<< "$found")"
        if [ -z "$found" ]; then
            echo "no test type named $first in this tree" >&2
            return 1
        elif [ -z "$known" ]; then
            echo "$first is declared only under ${found#?}, which no test plan or package lists" >&2
            case "$found" in *TableProMobileTests*) echo "  run it with: verify.sh ios $first" >&2 ;; esac
            return 1
        elif [ "$(wc -l <<< "$known" | tr -d ' ')" -gt 1 ]; then
            echo "$first is declared in more than one test target; name it as <target>/$1:" >&2
            sed 's/^/  /' <<< "$known" >&2
            return 1
        fi
        TARGET="$known" TEST_PATH="$1"
    fi
    ROUTE="$(route_of "$TARGET")"
}

ere_escape() {
    printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|]/\\&/g'
}

# Matches a test identifier, <target><sep><suite>/<case>(): sep is / in a result bundle and . under
# swift test. XCTest names a case without the parentheses, so they are optional.
test_regex() {
    local target="$1" path="$2" sep="$3"
    if [ -z "$path" ]; then
        printf '^%s(%s|$)' "$(ere_escape "$target")" "$(ere_escape "$sep")"
    else
        printf '^%s%s%s(\\(\\))?(/|$)' "$(ere_escape "$target")" "$(ere_escape "$sep")" "$(ere_escape "${path%()}")"
    fi
}

# ---------------------------------------------------------------------------- test results

# Beside this script, not under --root, so the parser always matches the tally format read here.
XCRESULT_CASES="$SCRIPT_DIR/../../../../scripts/lib/xcresult-cases.py"

# Sets RUN_EXECUTED, RUN_FAILED, RUN_ZERO and RUN_SYSTEM from the cases in a result bundle or xunit
# file, counted against the run's filters ("<label><TAB><regex>[<TAB>...]"), and notes the tallies.
apply_tally() {
    local filters="$1" input="$2" out
    out="$(python3 "$XCRESULT_CASES" tally --filters "$filters" "$input")" \
        || out="cause: scripts/lib/xcresult-cases.py failed, so no case was read."$'\n'"0 0 0 0"
    read -r RUN_EXECUTED RUN_FAILED RUN_ZERO RUN_SYSTEM <<< "$(tail -1 <<< "$out")"
    note "$(sed '$d' <<< "$out")"
}

# Build errors with their file and line, which the result bundle keeps even when the log interleaves them.
report_build_errors() {
    local errors
    errors="$(python3 "$XCRESULT_CASES" errors "$1" | head -12)"
    [ -n "$errors" ] || return 1
    note "errors:"
    note "$(sed 's/^/  /' <<< "$errors")"
}

# The result bundle is the verdict. The log only explains a run that left no tests in it.
report_xcresult() {
    local bundle="$1" code="$2" filters="$3" log="$4"
    apply_tally "$filters" "$bundle"
    if [ "$RUN_EXECUTED" -eq 0 ] && [ "$RUN_FAILED" -eq 0 ] && [ "$RUN_SYSTEM" -eq 0 ] && report_build_errors "$bundle"; then
        RUN_STATUS=FAIL
        note "cause: the test build failed, so no test ran."
    elif [ "$RUN_EXECUTED" -eq 0 ] && [ "$code" -ne 0 ]; then
        RUN_STATUS=FAIL
        note "cause: xcodebuild exited $code before any test ran."
        note "$(report_errors "$log")"
    elif [ "$RUN_FAILED" -gt 0 ]; then
        RUN_STATUS=FAIL
    elif [ "$RUN_SYSTEM" -gt 0 ]; then
        RUN_STATUS=FAIL
        note "cause: the test runner failed outside any test."
    elif [ "$code" -ne 0 ]; then
        RUN_STATUS=FAIL
        note "cause: xcodebuild exited $code although no test failed."
        note "$(report_errors "$log")"
    elif [ "$RUN_ZERO" -gt 0 ] || [ "$RUN_EXECUTED" -eq 0 ]; then
        RUN_STATUS=FAIL
        note "cause: a filter or the whole run executed no test. Filter by the Swift type name, and a case as Suite/case()."
    else
        RUN_STATUS=PASS
    fi
}

report_xunit() {
    local log="$1" code="$2" filters="$3" xunit="${1%.log}.xml"
    note "results: $xunit"
    apply_tally "$filters" "$xunit"
    if [ "$code" -ne 0 ] || [ "$RUN_FAILED" -gt 0 ]; then
        RUN_STATUS=FAIL
        note "$(report_errors "$log")"
        note "$(grep -E '✘ Test .* (failed|recorded an issue)' "$log" | sed 's/^/  /' | head -10)"
    elif [ "$RUN_ZERO" -gt 0 ] || [ "$RUN_EXECUTED" -eq 0 ]; then
        RUN_STATUS=FAIL
        note "cause: a filter or the whole run executed no test. swift test matches a filter against <Target>.<Suite>/<case>()."
    else
        RUN_STATUS=PASS
    fi
}

# A run that executed no test says nothing about the change when a known environment cause explains it.
ran_nothing_for_the_environment() {
    [ "$RUN_STATUS" != PASS ] && [ "${RUN_EXECUTED:-0}" -eq 0 ] && diagnose_environment "$1"
}

# The worst verdict of the runs in one step wins.
merge_status() {
    case "$1" in
        FAIL) STATUS=FAIL ;;
        INCONCLUSIVE) [ "$STATUS" = FAIL ] || STATUS=INCONCLUSIVE ;;
        *) [ -n "$STATUS" ] || STATUS="$1" ;;
    esac
}

run_plan() {
    local plan="$1" log="$2" filters="$3" bundle="${2%.log}.xcresult" only=() label regex arg
    while IFS=$'\t' read -r label regex arg; do
        only+=("-only-testing:$arg")
    done < "$filters"
    note "run: xcodebuild test -testPlan $plan${only[*]+ (${#only[@]} filter(s))}"
    # shellcheck disable=SC2046
    run_logged "$log" xcodebuild test -project "$REPO_ROOT/TablePro.xcodeproj" -scheme TablePro \
        -testPlan "$plan" -resultBundlePath "$bundle" $(xcodebuild_flags) ${only[@]+"${only[@]}"}
    RUN_CODE=$?
    report_xcresult "$bundle" "$RUN_CODE" "$filters" "$log"
    ran_nothing_for_the_environment "$log" && RUN_STATUS=INCONCLUSIVE
    # A failing run's bundle carries diagnostics of about 150 MB; a passing one is not worth keeping.
    if [ "$RUN_STATUS" = PASS ]; then
        rm -rf "$bundle"
    else
        note "results: $bundle"
    fi
}

# A package with a Package.resolved runs pinned to it, the way CI runs it.
run_swift_tests() {
    local package="$1" log="$2" filters="$3" dir="$REPO_ROOT/Packages/$1" args=() label regex
    [ -f "$dir/Package.resolved" ] && args+=(--force-resolved-versions)
    while IFS=$'\t' read -r label regex _; do
        args+=(--filter "$regex")
    done < "$filters"
    note "run: swift test --package-path Packages/$package --parallel${args[*]+ ${args[*]}}"
    # SwiftPM writes the XCTest xunit file only for a parallel run; a serial one leaves just the
    # Swift Testing file, and every XCTest case would go uncounted.
    run_logged "$log" swift test --package-path "$dir" --parallel --xunit-output "${log%.log}.xml" ${args[@]+"${args[@]}"}
    RUN_CODE=$?
    report_xunit "$log" "$RUN_CODE" "$filters"
    ran_nothing_for_the_environment "$log" && RUN_STATUS=INCONCLUSIVE
}

# SwiftLint applies `.swiftlint.yml`'s `included:` to a directory argument but not to a file
# argument, so a directory outside that scope lints nothing and reports zero violations.
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
    local stem="${1%.log}" filters="${1%.log}.filters"
    [ -f "$filters" ] || filters=/dev/null
    STATUS="" RUN_STATUS="" RUN_EXECUTED=0
    if [ -d "$stem.xcresult" ]; then
        note "results: $stem.xcresult"
        report_xcresult "$stem.xcresult" 0 "$filters" "$1"
    elif [ -f "$stem.xml" ] || [ -f "$stem-swift-testing.xml" ]; then
        report_xunit "$1" 0 "$filters"
    else
        case "${1##*/}" in
            test-* | uitest-* | ios-* | package-*)
                RUN_STATUS=INCONCLUSIVE
                note "cause: no result bundle or xunit file beside this log, so there is no test verdict to re-read."
                ;;
            *)
                RUN_STATUS=PASS
                grep -q '^\*\* BUILD FAILED \*\*' "$1" 2> /dev/null && RUN_STATUS=FAIL
                local errors
                errors="$(report_errors "$1")"
                [ -n "$errors" ] && { note "$errors"; RUN_STATUS=FAIL; }
                ;;
        esac
    fi
    ran_nothing_for_the_environment "$1" && RUN_STATUS=INCONCLUSIVE
    merge_status "$RUN_STATUS"
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
            # Xcode copies the HANA helper into the plugin and never builds it.
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
            plan=Unit other=uitest
            [ "$STEP" = "uitest" ] && plan=UI other=test
            require_tool jq
            require_tool git
            require_tool python3
            [ -f "$REPO_ROOT/TestPlans/$plan.xctestplan" ] || { echo "no TestPlans/$plan.xctestplan in $REPO_ROOT" >&2; exit 3; }
            TEST_TARGETS="$(test_targets_table)"
            plan_tests="" swift_tests="" packages=""
            for test in "$@"; do
                resolve_test "$test" || exit 3
                case "$ROUTE" in
                    "$plan")
                        plan_tests="$plan_tests$test"$'\t'"$(test_regex "$TARGET" "$TEST_PATH" /)"$'\t'"$TARGET${TEST_PATH:+/$TEST_PATH}"$'\n'
                        ;;
                    swift:*)
                        [ "$STEP" = test ] || { echo "$test is in $TARGET, a swift test target: verify.sh test $test" >&2; exit 3; }
                        swift_tests="$swift_tests${ROUTE#swift:}"$'\t'"$test"$'\t'"$(test_regex "$TARGET" "$TEST_PATH" .)"$'\n'
                        case " $packages " in *" ${ROUTE#swift:} "*) ;; *) packages="$packages ${ROUTE#swift:}" ;; esac
                        ;;
                    *)
                        echo "$test is in $TARGET, which the $ROUTE plan runs: verify.sh $other $test" >&2
                        exit 3
                        ;;
                esac
            done
            runs=""
            runs_plan=0
            if [ $# -eq 0 ] || [ -n "$plan_tests" ]; then
                runs_plan=1
                runs="$plan plan"
            fi
            for package in $packages; do runs="${runs:+$runs, }swift test $package"; done
            STEP_DETAIL="$runs${*:+: $*}"
            setup_toolchain
            name="$(printf '%s' "${1:-all}" | tr -c 'A-Za-z0-9_-' '_')"
            log="$(new_log "$STEP-$name")"
            : > "$log"
            code=0
            run_log=""
            if [ "$runs_plan" -eq 1 ]; then
                require_tool xcodebuild
                wait_for_free_toolchain
                run_log="$log"
                printf '%s' "$plan_tests" > "${run_log%.log}.filters"
                run_plan "$plan" "$run_log" "${run_log%.log}.filters"
                merge_status "$RUN_STATUS"
                code=$RUN_CODE
            fi
            for package in $packages; do
                require_tool swift
                # The first run writes the step's own log; each later one gets its own beside it.
                if [ -z "$run_log" ]; then
                    run_log="$log"
                else
                    run_log="${log%.log}-$package.log"
                    note "log: $run_log"
                fi
                printf '%s' "$swift_tests" | awk -F'\t' -v p="$package" '$1 == p { print $2 "\t" $3 }' > "${run_log%.log}.filters"
                run_swift_tests "$package" "$run_log" "${run_log%.log}.filters"
                merge_status "$RUN_STATUS"
                [ "$code" -ne 0 ] || code=$RUN_CODE
            done
            emit "$log" "$code"
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
            [ -f "$REPO_ROOT/Packages/$1/Package.swift" ] || { echo "no such package: Packages/$1" >&2; exit 3; }
            STEP_DETAIL="$1${2:+ --filter $2}"
            setup_toolchain
            require_tool swift
            require_tool python3
            log="$(new_log "package-$1")"
            : > "${log%.log}.filters"
            [ $# -ge 2 ] && printf '%s\t%s\n' "$2" "$2" > "${log%.log}.filters"
            run_swift_tests "$1" "$log" "${log%.log}.filters"
            merge_status "$RUN_STATUS"
            emit "$log" "$RUN_CODE"
            ;;

        ios)
            [ $# -ge 1 ] || usage
            STEP_DETAIL="TableProMobileTests: $*"
            setup_toolchain
            require_tool xcodebuild
            require_tool python3
            wait_for_free_toolchain
            name="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_')"
            log="$(new_log "ios-$name")"
            bundle="${log%.log}.xcresult"
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
            : > "${log%.log}.filters"
            for suite in "$@"; do
                filters+=("-only-testing:TableProMobileTests/$suite")
                printf '%s\t%s\n' "$suite" "$(test_regex TableProMobileTests "$suite" /)" >> "${log%.log}.filters"
            done
            xcodebuild test -project "$project" -scheme TableProMobile -destination "id=$simulator" \
                -parallel-testing-enabled NO -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO ARCHS=arm64 \
                -resultBundlePath "$bundle" "${filters[@]}" >> "$log" 2>&1
            code=$?
            note "results: $bundle"
            report_xcresult "$bundle" "$code" "${log%.log}.filters" "$log"
            ran_nothing_for_the_environment "$log" && RUN_STATUS=INCONCLUSIVE
            merge_status "$RUN_STATUS"
            emit "$log" $code
            ;;

        l10n)
            require_tool python3
            log="$(new_log l10n)"
            : > "$log"
            code=0
            failed=""
            for target in mac ios; do
                echo "== localization.py plugins --target $target" >> "$log"
                (cd "$REPO_ROOT" && python3 scripts/localization.py plugins --target "$target") >> "$log" 2>&1 \
                    || { code=1; failed="$failed $target"; }
            done
            if [ $code -eq 0 ]; then
                STATUS=PASS
                note "mac and ios: every plugin and package string is in the catalog, managed manually"
            else
                STATUS=FAIL
                note "$(grep -vE '^(==|ok:|  )' "$log" | grep -v '^Run with --add' | sed 's/^/  /' | head -12)"
                for target in $failed; do
                    note "  $target: python3 scripts/localization.py plugins --add --target $target"
                done
            fi
            emit "$log" $code
            ;;

        docs)
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
