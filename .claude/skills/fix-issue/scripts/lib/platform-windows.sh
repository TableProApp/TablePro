# shellcheck shell=bash
# shellcheck disable=SC2034
#
# Steps on the Windows platform (the WinUI app under windows/, over the core's FFI crate). The .NET steps run in
# windows/, the only place dotnet finds global.json:
#   verify.sh [options] build                          # dotnet build TablePro.slnx, which builds the core first
#   verify.sh [options] test [project] [filter...]     # the solution's tests, or one project's under windows/tests
#   verify.sh [options] core [package] [filter]        # cargo test, of tablepro-ffi unless a package is named
#   verify.sh [options] bindings                       # regenerate src/TablePro.Interop/Generated, fail when it changed
#   verify.sh [options] app [win-x64|win-arm64]        # the app's Native AOT publish, for the SDK's platform by default; Windows only
#   verify.sh [options] ui [filter...]                 # the UI tests against the app step's build; Windows only
#
# A project is a folder under windows/tests, with or without its TablePro. prefix. A filter is part of a test's name,
# run as --filter-method "*<filter>*". xunit's own filter options go after --, as in
# `test App.Model.Tests -- --filter-class '*SessionFileTests'` or `test -- --filter-trait Needs=Core`.
# A filter that runs no test is INCONCLUSIVE.
# There is no lint step: windows.yml runs none, and the build fails on any analyzer or style warning.
# CARGO_TARGET_DIR and CARGO_BUILD_JOBS reach Cargo as set. Here --offline keeps Cargo off the network, and NuGet
# restores from its cache when that holds every package. --no-wait changes nothing: Cargo waits for its own lock.

# Sourced by verify.sh, which owns the options, the log and the verdict. STEP_DETAIL is read by
# emit over there, which is all SC2034 is off for.

WINDOWS_DIR="$REPO_ROOT/windows"
GENERATED_DIR="$WINDOWS_DIR/src/TablePro.Interop/Generated"
# CoreRustFlags in src/TablePro.Interop/TablePro.Interop.csproj, the hybrid CRT the Windows core is linked with.
WINDOWS_CORE_RUSTFLAGS='-C target-feature=+crt-static -C link-arg=/NODEFAULTLIB:libucrt.lib -C link-arg=/DEFAULTLIB:ucrt.lib'
CARGO_ERROR_PATTERN='^error(\[E[0-9]+\])?: '
DOTNET_ERROR_PATTERN=': error [A-Z]+[0-9]+: '

# ---------------------------------------------------------------------------- environment

on_windows() {
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) return 0 ;;
    esac
    return 1
}

# windows.yml builds the core with these. Every step that reaches Cargo sets the same ones, so build, test, core
# and bindings share one build instead of each invalidating the others.
load_environment() {
    if ! command -v cargo > /dev/null 2>&1 && [ -f "$HOME/.cargo/env" ]; then
        # shellcheck source=/dev/null
        . "$HOME/.cargo/env"
    fi
    [ -n "${RUSTFLAGS+set}" ] || export RUSTFLAGS="-D warnings"
    [ -n "${AWS_LC_SYS_PREBUILT_NASM+set}" ] || export AWS_LC_SYS_PREBUILT_NASM=1
    export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
    if is_offline; then
        export CARGO_NET_OFFLINE=true
    fi
}

require_windows_tree() {
    [ -f "$WINDOWS_DIR/TablePro.slnx" ] && return 0
    STATUS=INCONCLUSIVE
    note "cause: $REPO_ROOT has no windows/TablePro.slnx. Make the tree from the profile's worktree base."
    emit "" 2
}

prepare() {
    require_windows_tree
    load_environment
    require_tool dotnet
    require_tool cargo
}

# Only Windows runs WinUI's PRI and manifest tools and UI Automation. Elsewhere the PR's CI runs these steps.
require_windows() {
    on_windows && return 0
    STATUS=INCONCLUSIVE
    note "cause: $1 runs on Windows only. Nothing was run."
    note "  the pull request's windows / Windows (x64) and windows / Windows (Arm64) jobs run it"
    emit "" 2
}

host_triple() {
    rustc -vV 2> /dev/null | sed -n 's/^host: //p'
}

# The SDK's own runtime identifier, which is also what the csproj builds the core for when none is given.
sdk_rid() {
    dotnet --info 2> /dev/null | sed -n 's/^ *RID: *//p' | head -1
}

# Known false failures. Each one presents as a code defect and is not one.
diagnose_environment() {
    local log="$1" found=1
    if grep -qE 'No space left on device|There is not enough space on the disk' "$log" 2> /dev/null; then
        note "cause: the disk is full. The core's debug build alone takes several GB in the Cargo target folder."
        found=0
    fi
    if grep -qE "Unable to update registry|failed to download|failed to fetch|Couldn't resolve host|failed to get .* as a dependency" "$log" 2> /dev/null; then
        note "cause: Cargo could not reach the network. A new target folder downloads every crate on its first build."
        found=0
    fi
    if grep -qE 'NU1301|Unable to load the service index' "$log" 2> /dev/null; then
        note "cause: NuGet could not reach the network to restore the packages."
        found=0
    fi
    if grep -qE 'A compatible .NET SDK was not found|NETSDK1045' "$log" 2> /dev/null; then
        note "cause: windows/global.json asks for a .NET 10 SDK this machine does not have."
        found=0
    fi
    if grep -qE "the .* target may not be installed|can't find crate for .(core|std)." "$log" 2> /dev/null; then
        note "cause: the pinned Rust toolchain lacks the target. rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc"
        found=0
    fi
    if grep -qE 'linker .link\.exe. not found' "$log" 2> /dev/null; then
        note "cause: MSVC is not installed: windows/scripts/install-toolchain.ps1 installs the Build Tools."
        found=0
    fi
    if grep -qE 'MSB3027|MSB3021|being used by another process' "$log" 2> /dev/null; then
        note "cause: a running TablePro.exe or test host holds a file the build copies. Close it and rerun."
        found=0
    fi
    return $found
}

# MSBuild repeats every error in its summary and appends the project to each line. Cargo, which the core's build
# target runs, prints its message on one line and the location on a later "-->" line. Both are paired and cut down
# so a note names the file and line once.
report_errors() {
    local log="$1" errors total
    errors="$(
        {
            grep -E "$DOTNET_ERROR_PATTERN" "$log" 2> /dev/null \
                | grep -v 'MSB3073' \
                | sed -E 's/ \[[^]]*\]$//' \
                | sed "s|$WINDOWS_DIR/||"
            awk '
                /^error(\[E[0-9]+\])?: / { message = $0; next }
                message != "" && /^ *--> / { sub(/^ *--> /, ""); print $0 ": " message; message = "" }
            ' "$log" 2> /dev/null
        } | sort -u | head -12
    )"
    [ -n "$errors" ] || errors="$(grep -E "$CARGO_ERROR_PATTERN|MSB3073" "$log" 2> /dev/null | sed -E 's/ \[[^]]*\]$//' | sort -u | head -12)"
    [ -n "$errors" ] || return 0
    echo "errors:"
    printf '%s\n' "$errors" | sed 's/^/  /'
    total="$(grep -E "$DOTNET_ERROR_PATTERN" "$log" 2> /dev/null | sed -E 's/ \[[^]]*\]$//' | sort -u | wc -l | tr -d ' ')"
    [ "${total:-0}" -gt 12 ] && echo "  … $((total - 12)) more, see the log"
}

# ---------------------------------------------------------------------------- test reporting

# Microsoft.Testing.Platform ends each dotnet test call with one summary block: "Test run summary:", then the
# total, failed, succeeded and skipped counts. The blocks are summed, so a log that holds several calls counts
# them all. A filter that matches nothing exits 8 with "Zero tests ran", which is not a pass.
report_dotnet_tests() {
    local log="$1" filtered="$2" code="$3" counts total failed succeeded skipped names
    counts="$(awk '
        /Test run summary:/ { in_summary = 1; next }
        in_summary && /^ *total: [0-9]+/ { total += $2 }
        in_summary && /^ *failed: [0-9]+/ { failed += $2 }
        in_summary && /^ *succeeded: [0-9]+/ { succeeded += $2 }
        in_summary && /^ *skipped: [0-9]+/ { skipped += $2 }
        in_summary && /^ *duration: / { in_summary = 0 }
        END { print total + 0, failed + 0, succeeded + 0, skipped + 0 }
    ' "$log" 2> /dev/null)"
    read -r total failed succeeded skipped <<< "$counts"
    note "cases: $((total - skipped)) executed, $succeeded passed, $failed failed, $skipped skipped"

    if [ "$failed" -gt 0 ]; then
        STATUS=FAIL
        names="$(sed -nE 's/^ *failed (.*) \([0-9][^)]*\)$/\1/p' "$log" 2> /dev/null | sort -u | head -10)"
        if [ -n "$names" ]; then
            note "failing tests:"
            note "$(printf '%s\n' "$names" | sed 's/^/  /')"
        fi
        return
    fi
    if [ "$total" -eq 0 ] || [ "$code" -eq 8 ]; then
        STATUS=INCONCLUSIVE
        if [ "$filtered" = 1 ]; then
            note "cause: the filter matched no test. The test platform exits 8 with \"Zero tests ran\"."
        else
            note "cause: zero cases executed. Read the log."
        fi
        return
    fi
    if [ "$code" -ne 0 ]; then
        STATUS=FAIL
        note "dotnet test exited $code with no failed case. Read the log."
        return
    fi
    STATUS=PASS
}

# A build error ends a test run before any test, so the log has no summary to count.
dotnet_compile_failed() {
    grep -qE "$DOTNET_ERROR_PATTERN|$CARGO_ERROR_PATTERN" "$1" 2> /dev/null \
        && ! grep -q 'Test run summary:' "$1" 2> /dev/null
}

# `cargo test` sums nothing itself: each test binary prints its own "test result:" line. A filter that matches
# nothing exits 0 with "0 passed".
report_cargo_tests() {
    local log="$1" filtered="$2" counts passed failed ignored names
    counts="$(awk '
        /^test result: / {
            for (i = 1; i <= NF; i++) {
                if ($(i + 1) ~ /^passed/) passed += $i
                if ($(i + 1) ~ /^failed/) failed += $i
                if ($(i + 1) ~ /^ignored/) ignored += $i
            }
        }
        END { print passed + 0, failed + 0, ignored + 0 }
    ' "$log" 2> /dev/null)"
    read -r passed failed ignored <<< "$counts"
    note "cases: $((passed + failed)) executed, $passed passed, $failed failed, $ignored ignored"

    if [ "$failed" -gt 0 ] || grep -qE '^test .* \.\.\. FAILED$' "$log" 2> /dev/null; then
        STATUS=FAIL
        names="$(sed -nE 's/^test (.*) \.\.\. FAILED$/\1/p' "$log" 2> /dev/null | sort -u | head -10)"
        if [ -n "$names" ]; then
            note "failing tests:"
            note "$(printf '%s\n' "$names" | sed 's/^/  /')"
        fi
        return
    fi
    if [ $((passed + failed)) -eq 0 ]; then
        STATUS=INCONCLUSIVE
        if [ "$filtered" = 1 ]; then
            note "cause: the filter matched no test. Cargo still exits 0 and prints \"0 passed\"."
        else
            note "cause: zero cases executed. Read the log."
        fi
        return
    fi
    STATUS=PASS
}

cargo_compile_failed() {
    grep -qE "^error: could not compile|$CARGO_ERROR_PATTERN" "$1" 2> /dev/null \
        && ! grep -qE '^test result: |^running [0-9]+ tests?$' "$1" 2> /dev/null
}

# ---------------------------------------------------------------------------- arguments

# The grid gate's projects sit in tests/ too, but they are programs, not test projects.
is_test_project() {
    grep -q '<IsTestProject>true</IsTestProject>' "$WINDOWS_DIR/$1/${1##*/}.csproj" 2> /dev/null
}

# A test project by its folder under windows/tests, with or without the TablePro. prefix, or by its path.
resolve_test_project() {
    local name="$1" candidate
    name="${name%/}"
    name="${name#windows/}"
    name="${name%.csproj}"
    for candidate in "$name" "tests/$name" "tests/TablePro.$name"; do
        if is_test_project "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

test_projects() {
    local dir names=""
    for dir in "$WINDOWS_DIR"/tests/*/; do
        dir="${dir%/}"
        is_test_project "tests/${dir##*/}" && names="$names ${dir##*/}"
    done
    printf '%s' "${names# }"
}

# A WinUI project builds elsewhere but runs on Windows only; its csproj turns IsTestProject off there.
windows_only_project() {
    grep -qE '<UseWinUI>true</UseWinUI>|<TargetFramework>net[0-9.]+-windows</TargetFramework>' "$WINDOWS_DIR/$1/${1##*/}.csproj"
}

# Sets FILTER_ARGS from the step's filter words: options pass through, a bare word matches part of a test's name.
build_filter_args() {
    FILTER_ARGS=()
    [ $# -ge 1 ] || return 0
    case "$1" in
        --*)
            FILTER_ARGS=("$@")
            return 0
            ;;
    esac
    local word
    for word in "$@"; do
        FILTER_ARGS+=(--filter-method "*$word*")
    done
}

# ---------------------------------------------------------------------------- steps

platform_parse() {
    local log="$1"
    STATUS=PASS
    case "$(basename "$log")" in
        test-* | ui-*)
            report_dotnet_tests "$log" 0 0
            ;;
        core-*)
            report_cargo_tests "$log" 0
            ;;
        *)
            if grep -qE "$DOTNET_ERROR_PATTERN|$CARGO_ERROR_PATTERN" "$log" 2> /dev/null; then
                STATUS=FAIL
                note "$(report_errors "$log")"
            fi
            ;;
    esac
    diagnose_environment "$log" && STATUS=INCONCLUSIVE
}

platform_step() {
    case "$STEP" in
        build)
            STEP_DETAIL="TablePro.slnx"
            prepare
            log="$(new_log build)"
            (cd "$WINDOWS_DIR" && dotnet build TablePro.slnx -nologo -tl:off) > "$log" 2>&1
            code=$?
            if [ $code -eq 0 ]; then
                STATUS=PASS
                on_windows || note "the WinUI projects compiled only: their PRI and manifest steps run on Windows"
            elif diagnose_environment "$log"; then
                STATUS=INCONCLUSIVE
            else
                STATUS=FAIL
                note "$(report_errors "$log")"
            fi
            emit "$log" $code
            ;;

        test)
            prepare
            local project="" filtered=0
            if [ $# -ge 1 ] && [ "${1#--}" = "$1" ]; then
                project="$(resolve_test_project "$1")" || {
                    echo "no such test project: $1 (windows/tests has: $(test_projects))" >&2
                    exit 3
                }
                shift
                STEP_DETAIL="${project##*/}"
                if [ "${project##*/}" = TablePro.App.UITests ]; then
                    echo "TablePro.App.UITests drives the built app: run it with the ui step" >&2
                    exit 3
                fi
                if ! on_windows && windows_only_project "$project"; then
                    require_windows "${project##*/}"
                fi
            fi
            build_filter_args "$@"
            [ ${#FILTER_ARGS[@]} -gt 0 ] && filtered=1
            if [ -n "$project" ]; then
                STEP_DETAIL="${project##*/}${1:+ $*}"
                log="$(new_log "test-${project##*/}")"
                (cd "$WINDOWS_DIR" && dotnet test --project "$project" ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"}) > "$log" 2>&1
            else
                STEP_DETAIL="TablePro.slnx${1:+ $*}"
                log="$(new_log test-solution)"
                (cd "$WINDOWS_DIR" && dotnet test --solution TablePro.slnx ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"}) > "$log" 2>&1
            fi
            code=$?
            if dotnet_compile_failed "$log"; then
                STATUS=FAIL
                note "cause: the tests failed to build. The errors below are build errors, not test failures."
                note "$(report_errors "$log")"
            else
                report_dotnet_tests "$log" "$filtered" "$code"
                if [ -z "$project" ] && ! on_windows; then
                    note "TablePro.DataGrid.Tests compiled but did not run: it runs on Windows"
                fi
            fi
            diagnose_environment "$log" && STATUS=INCONCLUSIVE
            emit "$log" $code
            ;;

        core)
            prepare
            local package=tablepro-ffi triple filter=()
            case "${1:-}" in
                tablepro-*) package="$1"; shift ;;
            esac
            [ $# -ge 1 ] && filter=("$@")
            STEP_DETAIL="$package${filter[0]:+ $*}"
            triple="$(host_triple)"
            [ -n "$triple" ] || { STATUS=INCONCLUSIVE; note "cause: rustc printed no host triple. Nothing was run."; emit "" 2; }
            log="$(new_log "core-$package")"
            # The csproj builds the core with --target, and with CoreRustFlags on Windows; the same here reuses that build.
            local rustflags="$RUSTFLAGS"
            case "$triple" in
                *-windows-msvc) rustflags="$rustflags $WINDOWS_CORE_RUSTFLAGS" ;;
            esac
            (cd "$REPO_ROOT" && RUSTFLAGS="$rustflags" cargo test --locked --no-fail-fast --target "$triple" -p "$package" ${filter[@]+"${filter[@]}"}) > "$log" 2>&1
            code=$?
            if grep -q "package ID specification .* did not match any packages" "$log" 2> /dev/null; then
                echo "no such package: $package (the names are in each Cargo.toml under core/crates)" >&2
                exit 3
            fi
            if cargo_compile_failed "$log"; then
                STATUS=FAIL
                note "cause: the tests failed to compile. The errors below are compile errors, not test failures."
                note "$(report_errors "$log")"
            else
                local filtered=0
                [ ${#filter[@]} -gt 0 ] && filtered=1
                report_cargo_tests "$log" "$filtered"
                [ $code -ne 0 ] && [ "$STATUS" = PASS ] && STATUS=FAIL
            fi
            diagnose_environment "$log" && STATUS=INCONCLUSIVE
            emit "$log" $code
            ;;

        bindings)
            STEP_DETAIL="src/TablePro.Interop/Generated"
            prepare
            local wanted tool="" candidate found snapshot changed
            wanted="$(sed -n 's:.*<UniffiBindgenCsVersion>\(.*\)</UniffiBindgenCsVersion>.*:\1:p' "$WINDOWS_DIR/src/TablePro.Interop/TablePro.Interop.csproj")"
            # UNIFFI_BINDGEN_CS first, then where windows.yml installs it, then PATH.
            for candidate in "${UNIFFI_BINDGEN_CS:-}" "$HOME/.uniffi-bindgen-cs/bin/uniffi-bindgen-cs" "$(command -v uniffi-bindgen-cs 2> /dev/null)"; do
                [ -n "$candidate" ] && [ -x "$candidate" ] || continue
                found="$("$candidate" --version 2> /dev/null)"
                case "$found" in
                    *" $wanted") tool="$candidate"; break ;;
                esac
            done
            if [ -z "$tool" ]; then
                STATUS=INCONCLUSIVE
                note "cause: no uniffi-bindgen-cs $wanted here${found:+ (found: $found)}. Nothing was run."
                note "  install it with the command in windows/AGENTS.md, Bindings, or name one with UNIFFI_BINDGEN_CS"
                emit "" 2
            fi
            log="$(new_log bindings)"
            snapshot="$(mktemp -d)" || { STATUS=INCONCLUSIVE; note "cause: no temporary directory for the snapshot. Nothing was run."; emit "" 2; }
            cp -R "$GENERATED_DIR/." "$snapshot/"
            (cd "$WINDOWS_DIR" && dotnet msbuild src/TablePro.Interop -t:GenerateBindings -p:UniffiBindgenCs="$tool" -nologo -tl:off) > "$log" 2>&1
            code=$?
            if [ $code -ne 0 ]; then
                # A generator that stopped halfway leaves neither the old files nor the new ones.
                rm -rf "$GENERATED_DIR"
                mkdir -p "$GENERATED_DIR"
                cp -R "$snapshot/." "$GENERATED_DIR/"
                rm -rf "$snapshot"
                if diagnose_environment "$log"; then
                    STATUS=INCONCLUSIVE
                else
                    STATUS=FAIL
                    note "$(report_errors "$log")"
                fi
                note "Generated/ is back as it was before the step"
                emit "$log" $code
            fi
            changed="$(diff -rq "$snapshot" "$GENERATED_DIR" 2> /dev/null | sed -e "s|$snapshot|before|g" -e "s|$WINDOWS_DIR/||g")"
            rm -rf "$snapshot"
            if [ -n "$changed" ]; then
                STATUS=FAIL
                note "the generator changed Generated/; the tree now holds the new files, so commit them with the FFI change:"
                note "$(printf '%s\n' "$changed" | head -8 | sed 's/^/  /')"
            else
                STATUS=PASS
                [ -n "$(git -C "$REPO_ROOT" status --porcelain -- "$GENERATED_DIR")" ] \
                    && note "Generated/ matches the library but differs from HEAD: commit it with the change"
            fi
            emit "$log" $code
            ;;

        app)
            STEP_DETAIL="${1:-}"
            require_windows "the app build"
            prepare
            local rid="${1:-}" platform
            [ -n "$rid" ] || rid="$(sdk_rid)"
            case "$rid" in
                win-x64) platform=x64 ;;
                win-arm64) platform=ARM64 ;;
                *) echo "app builds win-x64 or win-arm64, not '$rid'" >&2; exit 3 ;;
            esac
            STEP_DETAIL="$rid"
            log="$(new_log "app-$rid")"
            # The Native AOT build windows.yml runs the UI tests on, over the debug core the other steps share.
            (cd "$WINDOWS_DIR" && dotnet publish src/TablePro.App -c Release -r "$rid" -p:Platform="$platform" \
                -p:CargoProfile=dev -nologo -tl:off) > "$log" 2>&1
            code=$?
            if [ $code -eq 0 ]; then
                STATUS=PASS
                note "app: $(find "$WINDOWS_DIR/src/TablePro.App/bin/$platform" -path "*/$rid/publish/TablePro.exe" 2> /dev/null | head -1)"
            elif diagnose_environment "$log"; then
                STATUS=INCONCLUSIVE
            else
                STATUS=FAIL
                note "$(report_errors "$log")"
            fi
            emit "$log" $code
            ;;

        ui)
            STEP_DETAIL="TablePro.App.UITests${1:+ $*}"
            require_windows "TablePro.App.UITests"
            prepare
            local exe filtered=0 shots
            exe="$(find "$WINDOWS_DIR/src/TablePro.App/bin" -path "*/$(sdk_rid)/publish/TablePro.exe" 2> /dev/null | head -1)"
            if [ -z "$exe" ]; then
                STATUS=INCONCLUSIVE
                note "cause: no TablePro.exe for $(sdk_rid) in this tree. Run the app step first. Nothing was run."
                emit "" 2
            fi
            build_filter_args "$@"
            [ ${#FILTER_ARGS[@]} -gt 0 ] && filtered=1
            STEP_DETAIL="TablePro.App.UITests${1:+ $*}"
            log="$(new_log ui)"
            shots="${log%.log}-screenshots"
            # Each launch gets a data folder of its own; the screenshots land under <shots>/light and <shots>/dark.
            (cd "$WINDOWS_DIR" && TABLEPRO_APP="$exe" TABLEPRO_UI_SCREENSHOTS="$shots" \
                dotnet test --project tests/TablePro.App.UITests ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"}) > "$log" 2>&1
            code=$?
            if dotnet_compile_failed "$log"; then
                STATUS=FAIL
                note "cause: the UI tests failed to build."
                note "$(report_errors "$log")"
            else
                report_dotnet_tests "$log" "$filtered" "$code"
            fi
            [ -d "$shots" ] && note "screenshots: $shots"
            diagnose_environment "$log" && STATUS=INCONCLUSIVE
            emit "$log" $code
            ;;

        *)
            echo "unknown step: $STEP" >&2
            usage
            ;;
    esac
}
