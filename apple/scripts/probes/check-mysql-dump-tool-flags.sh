#!/usr/bin/env bash
#
# Check the dump subsystem's MySQL and MariaDB flag tables against the client tools on this Mac.
#
# MySQL and MariaDB forked their client option surfaces and neither accepts the other's: MariaDB
# answers --ssl-mode with "unknown variable" and exit 7, MySQL 8.4 answers --ssl with "unknown
# option" and exit 2. MySQLClientArguments.swift holds the mapping by hand and nothing at runtime
# checks it, which is how #3046 shipped. This hands every flag it names to a real tool of that
# flavor and fails on one the tool does not know.
#
# No server is needed. A tool rejects an unknown option before it opens a socket, so a closed port
# and a socket file that does not exist tell the two apart: a flag it understands fails with "Can't
# connect", one it does not fails with "unknown variable" or "unknown option".
#
# Usage:
#   scripts/probes/check-mysql-dump-tool-flags.sh
#
# Needs at least one mysql-family client on PATH or in a Homebrew prefix. Skips (exit 3) when
# neither flavor can be found, so it is safe to run anywhere. Exits non-zero on a disagreement.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/TablePro/Core/Database/MySQLClientArguments.swift"
CLOSED_PORT=59999
MISSING_SOCKET=/nonexistent/tablepro-probe.sock

[ -f "$SOURCE" ] || {
    echo "not found: $SOURCE" >&2
    exit 3
}

# The table this script holds the tools to. Every flag here must also appear in the Swift file, and
# every SSL flag in the Swift file must appear here, so neither can drift alone.
MYSQL_FLAGS=(
    "--protocol=TCP"
    "--protocol=SOCKET"
    "--socket=/dev/null"
    "--ssl-mode=DISABLED"
    "--ssl-mode=PREFERRED"
    "--ssl-mode=REQUIRED"
    "--ssl-mode=VERIFY_CA"
    "--ssl-mode=VERIFY_IDENTITY"
    "--ssl-ca=/dev/null"
    "--ssl-cert=/dev/null"
    "--ssl-key=/dev/null"
    "--skip-column-statistics"
    "--enable-cleartext-plugin"
)
MARIADB_FLAGS=(
    "--protocol=TCP"
    "--protocol=SOCKET"
    "--socket=/dev/null"
    "--skip-ssl"
    "--ssl"
    "--ssl-verify-server-cert"
    "--skip-ssl-verify-server-cert"
    "--ssl-ca=/dev/null"
    "--ssl-cert=/dev/null"
    "--ssl-key=/dev/null"
    "--plugin-dir=/dev/null"
)
# The restore client's own flags, checked against `mysql` and `mariadb` rather than the dump tool.
# MySQLClientArguments.restoreSafety adds the last of each list only from the release that has it,
# and release_has_switch below holds the same gates.
MYSQL_RESTORE_FLAGS=(
    "--binary-mode"
    "--local-infile=0"
    "--skip-system-command"
)
MARIADB_RESTORE_FLAGS=(
    "--binary-mode"
    "--local-infile=0"
    "--sandbox"
)

failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

# The exact flags the Swift file emits, from its code rather than from its prose: comment lines are
# dropped first, so the explanatory table in the doc comment cannot vouch for a literal the code no
# longer contains. A path built by interpolation keeps its `=` and loses the expression, which is
# what the checked flags normalize to as well.
source_flags() {
    grep -vE '^[[:space:]]*//' "$SOURCE" \
        | grep -o '"--[^"]*"' \
        | tr -d '"' \
        | sed -E 's/=\\\(.*/=/' \
        | sort -u
}

checked_flags() {
    printf '%s\n' "${MYSQL_FLAGS[@]}" "${MARIADB_FLAGS[@]}" "${MYSQL_RESTORE_FLAGS[@]}" "${MARIADB_RESTORE_FLAGS[@]}" \
        | sed -E 's|=/dev/null|=|' | sort -u
}

# Both directions, so neither a flag the code dropped nor one it gained goes unchecked.
check_source_agrees() {
    local flag
    while read -r flag; do
        [ -n "$flag" ] || continue
        fail "$flag is checked here but no longer emitted by MySQLClientArguments.swift"
    done < <(comm -23 <(checked_flags) <(source_flags))
    while read -r flag; do
        [ -n "$flag" ] || continue
        fail "$flag is emitted by MySQLClientArguments.swift but not checked here"
    done < <(comm -13 <(checked_flags) <(source_flags))
}

flavor_of() {
    local banner
    banner="$("$1" --version 2> /dev/null)"
    [ -n "$banner" ] || return 1
    case "$banner" in
        *MariaDB* | *mariadb*) echo "mariadb" ;;
        *) echo "mysql" ;;
    esac
}

# `Distrib` beats `Ver` on MySQL 5.7 and MariaDB 10, `from` is MariaDB 11 and later: the last
# marker on the line is the release.
release_of() {
    "$1" --version 2> /dev/null | sed -nE 's/.*(Distrib|from|Ver)[[:space:]]+([0-9]+(\.[0-9]+)*).*/\2/p' | head -1
}

# 0 when the release is in [low, high). An empty high is open.
release_in() {
    local release=$1 low=$2 high=$3
    [ "$(printf '%s\n%s\n' "$low" "$release" | sort -V | head -1)" = "$low" ] || return 1
    [ -z "$high" ] && return 0
    [ "$release" != "$high" ] && [ "$(printf '%s\n%s\n' "$release" "$high" | sort -V | head -1)" = "$release" ]
}

release_has_switch() {
    local flavor=$1 release=$2
    [ -n "$release" ] || return 1
    if [ "$flavor" = "mariadb" ]; then
        release_in "$release" 10.6.18 10.7 || release_in "$release" 10.11.8 10.12 || release_in "$release" 11.4.2 ""
    else
        release_in "$release" 8.0.40 8.1 || release_in "$release" 8.4.3 8.5 || release_in "$release" 9.1.0 ""
    fi
}

# A tool that rejects the flag says so before connecting, so the connection failure is the pass.
check_tool() {
    local tool=$1 flavor=$2 role=${3:-dump} flag output
    local -a flags
    case "$flavor/$role" in
        mariadb/restore) flags=("${MARIADB_RESTORE_FLAGS[@]}") ;;
        mysql/restore) flags=("${MYSQL_RESTORE_FLAGS[@]}") ;;
        mariadb/dump) flags=("${MARIADB_FLAGS[@]}") ;;
        *) flags=("${MYSQL_FLAGS[@]}") ;;
    esac
    echo "checking $flavor $role tool $tool ($("$tool" --version 2> /dev/null | head -1))"
    if [ "$role" = "restore" ] && ! release_has_switch "$flavor" "$(release_of "$tool")"; then
        echo "  skip ${flags[${#flags[@]} - 1]}: the app adds it only from the release that has it"
        unset 'flags[${#flags[@]}-1]'
    fi
    for flag in "${flags[@]}"; do
        output="$("$tool" --protocol=TCP -h 127.0.0.1 -P "$CLOSED_PORT" --socket="$MISSING_SOCKET" -u probe "$flag" nodb 2>&1)"
        case "$output" in
            *"unknown variable"* | *"unknown option"* | *"Unknown option"*)
                fail "$tool ($flavor) rejects $flag: $(echo "$output" | head -1)"
                ;;
            *)
                echo "  ok $flag"
                ;;
        esac
    done
}

candidates() {
    local name
    for name in mysqldump mariadb-dump; do
        command -v "$name" 2> /dev/null
    done
    ls -1 /opt/homebrew/opt/*/bin/mysqldump /usr/local/opt/*/bin/mysqldump /usr/local/mysql/bin/mysqldump 2> /dev/null
}

restore_candidates() {
    local name
    for name in mysql mariadb; do
        command -v "$name" 2> /dev/null
    done
    ls -1 /opt/homebrew/opt/*/bin/mysql /usr/local/opt/*/bin/mysql /usr/local/mysql/bin/mysql 2> /dev/null
}

check_source_agrees

declare -a seen_flavors=()
while read -r tool; do
    [ -x "$tool" ] || continue
    flavor="$(flavor_of "$tool")" || continue
    case " ${seen_flavors[*]:-} " in
        *" $flavor "*) continue ;;
    esac
    seen_flavors+=("$flavor")
    check_tool "$tool" "$flavor"
done < <(candidates | sort -u)

declare -a seen_restore_flavors=()
while read -r tool; do
    [ -x "$tool" ] || continue
    flavor="$(flavor_of "$tool")" || continue
    case " ${seen_restore_flavors[*]:-} " in
        *" $flavor "*) continue ;;
    esac
    seen_restore_flavors+=("$flavor")
    check_tool "$tool" "$flavor" restore
done < <(restore_candidates | sort -u)

if [ ${#seen_flavors[@]} -eq 0 ]; then
    echo "no mysql-family client found; install mysql-client or mariadb to run this check" >&2
    exit 3
fi

# A MySQL 8 tool is the only one that reads information_schema.COLUMN_STATISTICS, and MariaDB's own
# tool does not know the flag that skips it, so the mapping is only correct while that stays true.
case " ${seen_flavors[*]} " in
    *" mariadb "*)
        maria="$(candidates | sort -u | while read -r t; do
            [ -x "$t" ] && [ "$(flavor_of "$t")" = "mariadb" ] && echo "$t" && break
        done)"
        if [ -n "$maria" ]; then
            # MariaDB's tools report an unknown option and still exit 0 for --version, so the
            # message is the signal rather than the exit code.
            case "$("$maria" --skip-column-statistics --version 2>&1)" in
                *"unknown option"* | *"unknown variable"*)
                    echo "  ok --skip-column-statistics is still MySQL-only"
                    ;;
                *)
                    fail "MariaDB's tool now accepts --skip-column-statistics; the compatibility rule needs revisiting"
                    ;;
            esac
        fi
        ;;
esac

if [ "$failures" -gt 0 ]; then
    echo "$failures disagreement(s) between the flag tables and the installed tools" >&2
    exit 1
fi
echo "flag tables agree with the installed tools"
