# shellcheck shell=bash
# shellcheck disable=SC2034
#
# Steps on the Linux platform (the GTK app under linux/), each run in linux/ with the environment
# `meson devenv` gives Cargo:
#   verify.sh [options] setup                      # meson setup _build, or reconfigure an existing one
#   verify.sh [options] build                      # meson compile
#   verify.sh [options] test <package> [filter]    # one crate's tests through Cargo
#   verify.sh [options] test                       # every Meson suite, as the CI fast job runs them
#   verify.sh [options] lint                       # rustfmt, then clippy with and without default features
#   verify.sh [options] data                       # the desktop entry, schema and metainfo validators
#   verify.sh [options] l10n                       # POTFILES.in against the tree, and the catalog test
#   verify.sh [options] docker <package>           # the tests that need a container
#   verify.sh [options] secrets                    # the Secret Service tests on a private session bus
#   verify.sh [options] dist                       # meson dist of the last commit
#
# Here --offline keeps Cargo off the network. --no-wait changes nothing: Cargo waits for its own lock.

# Sourced by verify.sh, which owns the options, the log and the verdict. STEP_DETAIL is read by
# emit over there, which is all SC2034 is off for.

LINUX_DIR="$REPO_ROOT/linux"
BUILD_DIR="$LINUX_DIR/_build"
CARGO_FAILURE_PATTERN='^error(\[E[0-9]+\])?: |^test .* \.\.\. FAILED$|process didn.t exit successfully'

# ---------------------------------------------------------------------------- environment

# rustup puts cargo in ~/.cargo/bin and asks the shell to source ~/.cargo/env, which a shell that
# never read the user's profile has not done. Meson stored cargo's absolute path at setup, so
# compile and test work anyway, and only `meson devenv cargo` failed with "Command not found".
load_rust_environment() {
    if ! command -v cargo > /dev/null 2>&1 && [ -f "$HOME/.cargo/env" ]; then
        # shellcheck source=/dev/null
        . "$HOME/.cargo/env"
    fi
    if is_offline; then
        export CARGO_NET_OFFLINE=true
    fi
}

require_linux_tree() {
    [ -f "$LINUX_DIR/meson.build" ] && return 0
    STATUS=INCONCLUSIVE
    note "cause: $REPO_ROOT has no linux/. The Linux app is on the linux branch: make the tree from origin/linux."
    emit "" 2
}

require_configured() {
    [ -f "$BUILD_DIR/build.ninja" ] && return 0
    STATUS=INCONCLUSIVE
    note "cause: linux/_build is not configured in this tree. Run the setup step first. Nothing was run."
    emit "" 2
}

prepare() {
    require_linux_tree
    load_rust_environment
    require_tool meson
    require_tool cargo
}

# Test traffic stays off the user's session bus, as in CI. Without a display the GTK suite cannot
# initialise, so it gets a virtual one when xvfb-run is there to provide it.
test_wrapper() {
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && command -v xvfb-run > /dev/null 2>&1; then
        printf '%s\n' xvfb-run -a
    fi
    if command -v dbus-run-session > /dev/null 2>&1; then
        printf '%s\n' dbus-run-session --
    fi
}

in_devenv() {
    meson devenv -C "$BUILD_DIR" --workdir "$LINUX_DIR" "$@"
}

# A service the private session bus started can outlive the step and still write to the log. With
# the file opened for truncation, its writes landed at its own offset, over whatever the step had
# appended since. Opened for appending, every write goes to the end.
run_appending() {
    local log="$1"; shift
    : > "$log"
    "$@" >> "$log" 2>&1
}

# Known false failures. Each one presents as a code defect and is not one.
diagnose_environment() {
    local log="$1" found=1
    if grep -q 'Failed to initialize GTK' "$log" 2> /dev/null; then
        note "cause: GTK found no display. Run inside the desktop session, or install xvfb-run."
        found=0
    fi
    if grep -qE "Unable to update registry|failed to download|failed to fetch|Couldn't resolve host|failed to get .* as a dependency" "$log" 2> /dev/null; then
        note "cause: Cargo could not reach the network. A new tree downloads every crate into linux/_build/cargo-home on its first build."
        found=0
    fi
    if grep -q 'No space left on device' "$log" 2> /dev/null; then
        note "cause: the disk is full. Each tree's linux/_build holds about 20 GB."
        found=0
    fi
    if grep -qE 'Cannot connect to the Docker daemon|permission denied while trying to connect to the [Dd]ocker' "$log" 2> /dev/null; then
        note "cause: Docker is not reachable from this shell."
        found=0
    fi
    return $found
}

# Compiler and clippy diagnostics print the message on one line and the location on a later
# "-->" line. Pair them, so a note names the file and line instead of only the message.
report_errors() {
    local log="$1" errors total
    errors="$(awk '
        /^(error|warning)(\[[A-Za-z0-9_:]+\])?: / { message = $0; next }
        message != "" && /^ *--> / { sub(/^ *--> /, ""); print $0 ": " message; message = "" }
    ' "$log" 2> /dev/null | grep -v ': warning: build failed' | sort -u | head -12)"
    [ -n "$errors" ] || errors="$(grep -E '^error' "$log" 2> /dev/null | sort -u | head -12)"
    [ -n "$errors" ] || return 0
    echo "errors:"
    printf '%s\n' "$errors" | sed 's/^/  /'
    total="$(grep -cE '^error(\[E[0-9]+\])?: ' "$log" 2> /dev/null)"
    [ "${total:-0}" -gt 12 ] && echo "  … $((total - 12)) more, see the log"
}

# rustfmt names each file it would change as "Diff in <path>:<line>:", and an older one as
# "Diff in <path> at line <line>:".
report_unformatted() {
    local unformatted
    unformatted="$(sed -nE 's/^Diff in (.*):([0-9]+):$/\1:\2/p; s/^Diff in (.*) at line ([0-9]+):$/\1:\2/p' "$1" 2> /dev/null \
        | sed "s|^$LINUX_DIR/||" | sort -u | head -8)"
    [ -n "$unformatted" ] || return 0
    note "not formatted (cargo fmt --all fixes it):"
    note "$(printf '%s\n' "$unformatted" | sed 's/^/  /')"
}

# ---------------------------------------------------------------------------- test reporting

# `cargo test` sums nothing itself: each test binary prints its own "test result:" line. Three
# binaries in the app crate have no harness and print no counts, so each one is a single case,
# failed when Cargo names it in "process didn't exit successfully". A filter that matches nothing
# exits 0 with "0 passed", and a harness-free binary ignores the filter and runs anyway, so
# "nothing matched" is decided on the counted cases alone.
report_tests() {
    local log="$1" filtered="$2" counts passed failed harnessless harnessless_failed executed
    counts="$(awk '
        function close_block() { if (open && !counted) harnessless++; open = 0 }
        /^ *(Running|Doc-tests) / { close_block(); open = 1; counted = 0; next }
        /^running [0-9]+ tests?$/ { counted = 1 }
        /^test result: / {
            for (i = 1; i <= NF; i++) {
                if ($(i + 1) ~ /^passed/) passed += $i
                if ($(i + 1) ~ /^failed/) failed += $i
            }
        }
        /^ *Summary \[/ {
            for (i = 1; i <= NF; i++) {
                if ($(i + 1) ~ /^passed/) passed += $i
                if ($(i + 1) ~ /^failed/) failed += $i
            }
        }
        END { close_block(); print passed + 0, failed + 0, harnessless + 0 }
    ' "$log" 2> /dev/null)"
    read -r passed failed harnessless <<< "$counts"
    harnessless_failed="$(grep -cE "process didn.t exit successfully: .*/deps/(startup|logging|i18n_catalog)-" "$log" 2> /dev/null)"
    executed=$((passed + failed + harnessless))
    note "cases: $executed executed, $((passed + harnessless - harnessless_failed)) passed, $((failed + harnessless_failed)) failed"

    if [ "$filtered" = 1 ] && [ $((passed + failed)) -eq 0 ]; then
        STATUS=INCONCLUSIVE
        note "cause: the filter matched no test. Cargo still exits 0 and prints \"0 passed\"."
        return
    fi
    if [ "$executed" -eq 0 ]; then
        STATUS=INCONCLUSIVE
        note "cause: zero cases executed. Read the log."
        return
    fi
    if [ "$failed" -eq 0 ] && [ "$harnessless_failed" -eq 0 ] && ! grep -qE "$CARGO_FAILURE_PATTERN" "$log" 2> /dev/null; then
        STATUS=PASS
        return
    fi
    STATUS=FAIL
    local names
    names="$(sed -nE 's/^test (.*) \.\.\. FAILED$/\1/p; s/.*process didn.t exit successfully: .*\/deps\/([a-z_]+)-[0-9a-f]+.*/\1 (harness-free test binary)/p' "$log" 2> /dev/null | sort -u | head -10)"
    if [ -n "$names" ]; then
        note "failing tests:"
        note "$(printf '%s\n' "$names" | sed 's/^/  /')"
    fi
}

# A compile error ends the run before any test, with the same exit code a failing test has.
compile_failed() {
    grep -qE '^error: could not compile|^error(\[E[0-9]+\])?: ' "$1" 2> /dev/null \
        && ! grep -qE '^test result: |^running [0-9]+ tests?$' "$1" 2> /dev/null
}

# meson test prints only the failing tests and keeps every test's output in testlog.txt, which the
# next run overwrites. Copy it into the log, which is what the counts are read from.
append_meson_testlog() {
    local log="$1" testlog="$BUILD_DIR/meson-logs/testlog.txt"
    [ -f "$testlog" ] || return 0
    {
        echo "== $testlog"
        cat "$testlog"
    } >> "$log"
}

# The summary Meson printed, read from before the copied testlog.txt, which repeats it.
meson_summary() {
    awk '/^== .*testlog\.txt$/ { exit } /^(Ok|Expected Fail|Fail|Unexpected Pass|Skipped|Timeout): +[0-9]+/' "$1" 2> /dev/null \
        | tr -s ' ' | paste -sd ' ' -
}

# ---------------------------------------------------------------------------- steps

platform_parse() {
    local log="$1"
    STATUS=PASS
    case "$(basename "$log")" in
        test-* | docker-* | secrets-*)
            report_tests "$log" 0
            ;;
        *)
            if grep -qE '^error|^Diff in ' "$log" 2> /dev/null; then
                STATUS=FAIL
                report_unformatted "$log"
                note "$(report_errors "$log")"
            fi
            ;;
    esac
    diagnose_environment "$log" && STATUS=INCONCLUSIVE
}

platform_step() {
    case "$STEP" in
        setup)
            STEP_DETAIL=""
            prepare
            log="$(new_log setup)"
            if [ -f "$BUILD_DIR/build.ninja" ]; then
                (cd "$LINUX_DIR" && meson setup --reconfigure _build -Dprofile=development) > "$log" 2>&1
            else
                (cd "$LINUX_DIR" && meson setup _build -Dprofile=development) > "$log" 2>&1
            fi
            code=$?
            if [ $code -eq 0 ]; then
                STATUS=PASS
            else
                STATUS=FAIL
                note "$(grep -E 'ERROR|error' "$log" | tail -5 | sed 's/^/  /')"
                diagnose_environment "$log" && STATUS=INCONCLUSIVE
            fi
            emit "$log" $code
            ;;

        build)
            STEP_DETAIL=""
            prepare
            require_configured
            log="$(new_log build)"
            run_logged "$log" meson compile -C "$BUILD_DIR"
            code=$?
            if [ $code -eq 0 ]; then
                STATUS=PASS
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
            require_configured
            if [ $# -eq 0 ]; then
                STEP_DETAIL="every Meson suite"
                log="$(new_log test-suites)"
                local wrapper=()
                mapfile -t wrapper < <(test_wrapper)
                run_appending "$log" ${wrapper[@]+"${wrapper[@]}"} meson test -C "$BUILD_DIR" --print-errorlogs
                code=$?
                append_meson_testlog "$log"
                note "suites: $(meson_summary "$log")"
                report_tests "$log" 0
                [ $code -ne 0 ] && [ "$STATUS" = PASS ] && STATUS=FAIL
            else
                local package="$1" filter=()
                shift
                [ $# -ge 1 ] && filter=("$@")
                STEP_DETAIL="$package${filter[0]:+ $*}"
                log="$(new_log "test-$package")"
                local wrapper=() gtk_env=()
                mapfile -t wrapper < <(test_wrapper)
                # The app crate's widget tests need the accessibility test backend and a renderer
                # that works without a GPU, which only Meson's gtk suite sets; devenv does not.
                [ "$package" = tablepro ] && gtk_env=(env GTK_A11Y=test GSK_RENDERER=cairo)
                run_appending "$log" ${wrapper[@]+"${wrapper[@]}"} ${gtk_env[@]+"${gtk_env[@]}"} \
                    meson devenv -C "$BUILD_DIR" --workdir "$LINUX_DIR" \
                    cargo test --locked --no-fail-fast -p "$package" ${filter[@]+"${filter[@]}"}
                code=$?
                if grep -q "package ID specification .* did not match any packages" "$log" 2> /dev/null; then
                    echo "no such package: $package (the names are in each linux/crates/*/Cargo.toml)" >&2
                    exit 3
                fi
                if compile_failed "$log"; then
                    STATUS=FAIL
                    note "cause: the tests failed to compile. The errors below are compile errors, not test failures."
                    note "$(report_errors "$log")"
                else
                    local filtered=0
                    [ ${#filter[@]} -gt 0 ] && filtered=1
                    report_tests "$log" "$filtered"
                    [ $code -ne 0 ] && [ "$STATUS" = PASS ] && STATUS=FAIL
                fi
            fi
            diagnose_environment "$log" && STATUS=INCONCLUSIVE
            emit "$log" $code
            ;;

        lint)
            STEP_DETAIL="rustfmt, clippy, clippy --no-default-features"
            prepare
            require_configured
            log="$(new_log lint)"
            : > "$log"
            code=0
            {
                echo "== cargo fmt --all -- --check"
                (cd "$LINUX_DIR" && cargo fmt --all -- --check) || code=1
                echo "== cargo clippy --locked --workspace --all-targets -- -D warnings"
                in_devenv cargo clippy --locked --workspace --all-targets -- -D warnings || code=1
                echo "== cargo clippy --locked --workspace --all-targets --no-default-features -- -D warnings"
                in_devenv cargo clippy --locked --workspace --all-targets --no-default-features -- -D warnings || code=1
            } >> "$log" 2>&1
            if [ $code -eq 0 ]; then
                STATUS=PASS
                note "violations: 0"
            elif diagnose_environment "$log"; then
                STATUS=INCONCLUSIVE
            else
                STATUS=FAIL
                report_unformatted "$log"
                note "$(report_errors "$log")"
            fi
            emit "$log" $code
            ;;

        data)
            STEP_DETAIL="desktop entry, schema, metainfo"
            prepare
            require_configured
            log="$(new_log data)"
            run_logged "$log" meson test -C "$BUILD_DIR" --no-rebuild --suite data --print-errorlogs
            code=$?
            note "suites: $(meson_summary "$log")"
            if [ $code -ne 0 ]; then
                STATUS=FAIL
                note "$(grep -vE '^(Ok|Fail|Skipped|Expected Fail|Unexpected Pass|Timeout):' "$log" | grep -iE 'error|fail|invalid' | head -10 | sed 's/^/  /')"
            elif grep -qE '^Ok: +0$' "$log"; then
                STATUS=INCONCLUSIVE
                note "cause: no validator ran. Each one is skipped when its tool is not installed."
            else
                STATUS=PASS
                grep -qE '^Skipped: +[1-9]' "$log" && note "some validators were skipped: their tools are not installed here"
            fi
            emit "$log" $code
            ;;

        l10n)
            STEP_DETAIL="POTFILES.in, i18n_catalog"
            prepare
            require_configured
            log="$(new_log l10n)"
            : > "$log"
            code=0
            {
                # The same file list CI regenerates, compared without writing to the tree.
                echo "== POTFILES.in against the tree"
                (cd "$LINUX_DIR" && git ls-files 'crates/app/src/*.rs' 'data/resources/*.ui' 'data/*.desktop.in.in' \
                    'data/*.gschema.xml' 'data/*.metainfo.xml.in.in' | diff - po/POTFILES.in) || code=1
                echo "== cargo test -p tablepro --test i18n_catalog"
                in_devenv cargo test --locked -p tablepro --test i18n_catalog || code=1
            } >> "$log" 2>&1
            if [ $code -eq 0 ]; then
                STATUS=PASS
            else
                STATUS=FAIL
                note "$(grep -E '^[<>] |could not|missing|error' "$log" | head -10 | sed 's/^/  /')"
                grep -qE '^[<>] ' "$log" && note "  POTFILES.in is stale: list the files above in linux/po/POTFILES.in"
                diagnose_environment "$log" && STATUS=INCONCLUSIVE
            fi
            note "the POT template itself is checked by CI's Translations job, which needs gettext 0.24 or later"
            emit "$log" $code
            ;;

        docker)
            [ $# -ge 1 ] || usage
            local package="$1"
            STEP_DETAIL="$package"
            prepare
            require_configured
            log="$(new_log "docker-$package")"
            if ! docker version > "$log" 2>&1; then
                STATUS=INCONCLUSIVE
                note "cause: Docker is not reachable from this shell. Nothing was run."
                emit "$log" 2
            fi
            # CI runs these through nextest, whose test groups keep one container engine busy at a
            # time. Without nextest, one thread does the same.
            if cargo nextest --version > /dev/null 2>&1; then
                run_logged "$log" in_devenv cargo nextest run --locked --profile ci -p "$package" --run-ignored only
            else
                run_logged "$log" in_devenv cargo test --locked --no-fail-fast -p "$package" -- --ignored --test-threads=1
                note "cargo-nextest is not installed, so this ran through cargo test on one thread"
            fi
            code=$?
            if compile_failed "$log"; then
                STATUS=FAIL
                note "$(report_errors "$log")"
            else
                report_tests "$log" 0
                [ $code -ne 0 ] && [ "$STATUS" = PASS ] && STATUS=FAIL
            fi
            diagnose_environment "$log" && STATUS=INCONCLUSIVE
            emit "$log" $code
            ;;

        secrets)
            STEP_DETAIL="tablepro-storage secret_service"
            prepare
            require_configured
            require_tool dbus-run-session
            require_tool gnome-keyring-daemon
            log="$(new_log secrets)"
            # gnome-keyring-daemon keeps its keyrings under XDG_DATA_HOME and its control socket
            # under XDG_RUNTIME_DIR. A private bus alone left both pointing at the user's own, so
            # this step rewrote the developer's login keyring with the test password. Both now
            # point at a directory that exists only for this run.
            local keyring_home
            keyring_home="$(mktemp -d)" || { STATUS=INCONCLUSIVE; note "cause: no temporary directory for the throwaway keyring. Nothing was run."; emit "" 2; }
            mkdir -m 700 "$keyring_home/data" "$keyring_home/run"
            run_appending "$log" env XDG_DATA_HOME="$keyring_home/data" XDG_RUNTIME_DIR="$keyring_home/run" \
                dbus-run-session -- bash -c \
                "gnome-keyring-daemon --components=secrets --daemonize --unlock <<< ci > /dev/null \
                && meson devenv -C '$BUILD_DIR' --workdir '$LINUX_DIR' \
                    cargo test --locked -p tablepro-storage --test secret_service -- --ignored"
            code=$?
            rm -rf "$keyring_home"
            report_tests "$log" 0
            [ $code -ne 0 ] && [ "$STATUS" = PASS ] && STATUS=FAIL
            diagnose_environment "$log" && STATUS=INCONCLUSIVE
            emit "$log" $code
            ;;

        dist)
            STEP_DETAIL=""
            prepare
            require_configured
            log="$(new_log dist)"
            run_logged "$log" meson dist -C "$BUILD_DIR" --no-tests --formats xztar
            code=$?
            if [ $code -eq 0 ]; then
                STATUS=PASS
                note "$(grep -E '^Created ' "$log" | sed 's/^/  /')"
            elif grep -qi 'uncommitted\|not clean\|local changes' "$log"; then
                STATUS=INCONCLUSIVE
                note "cause: meson dist packs the last commit and refuses a tree with uncommitted changes. Commit first."
            else
                STATUS=FAIL
                note "$(tail -8 "$log" | sed 's/^/  /')"
            fi
            emit "$log" $code
            ;;

        *)
            echo "unknown step: $STEP" >&2
            usage
            ;;
    esac
}
