# The check that the core's static library takes SQLite from the system, as the app does. Sourced, never executed.
# Two copies in one process break each other's POSIX locks on the same file (core/docs/decisions/0010-macos-on-the-core.md),
# and the system's library only has the functions the deployment target's macOS shipped: the SDK header marks each newer
# one with API_AVAILABLE, which the core's generated bindings drop.
#
# shellcheck shell=bash

[ -n "${TABLEPRO_SYSTEM_SQLITE_SOURCED:-}" ] && return 0
TABLEPRO_SYSTEM_SQLITE_SOURCED=1

source "$(dirname "${BASH_SOURCE[0]}")/deployment-target.sh"

# Every function and variable sqlite3.h declares, with the macOS release that added it, or 0 when it carries no mark.
sqlite_header_availability() {
    awk '
        /^API_AVAILABLE\(/ {
            since = "0"
            if (match($0, /macos\([0-9.]+\)/)) since = substr($0, RSTART + 6, RLENGTH - 7)
            next
        }
        /^SQLITE_API/ {
            line = $0
            while (match(line, /sqlite3_[A-Za-z0-9_]+[ ]*[([]/)) {
                name = substr(line, RSTART, RLENGTH)
                sub(/[ ]*[([]$/, "", name)
                if (!(name in seen)) { print name, (since == "" ? "0" : since); seen[name] = 1 }
                line = substr(line, RSTART + RLENGTH)
            }
        }
        { since = "" }
    ' "$1"
}

verify_system_sqlite() {
    local archive="$1" header sdk defined called failed=0 name since
    sdk="$(xcrun --sdk macosx --show-sdk-path)" || return 1
    header="$sdk/usr/include/sqlite3.h"
    echo ""
    echo "🔍 Verifying the system SQLite linkage..."
    # nm exits 1 on an archive with a member that defines nothing, which a Rust static library always has.
    defined="$(nm -gUj "$archive" 2> /dev/null || true)"
    called="$(nm -uj "$archive" 2> /dev/null || true)"
    if [ -z "$defined" ] || [ -z "$called" ]; then
        echo "   ❌ nm read no symbols from $archive" >&2
        return 1
    fi
    if grep -qx '_sqlite3_open_v2' <<< "$defined"; then
        echo "   ❌ $(basename "$archive") defines sqlite3_open_v2: it bundles its own SQLite" >&2
        return 1
    fi
    local available
    available="$(sqlite_header_availability "$header")"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        since="$(awk -v n="$name" '$1 == n { print $2; exit }' <<< "$available")"
        if [ -z "$since" ]; then
            echo "   ❌ $name is not in $header" >&2
            failed=1
        elif [ "$(printf '%s\n' "$DEPLOY_TARGET" "$since" | sort -V | tail -1)" != "$DEPLOY_TARGET" ]; then
            echo "   ❌ $name needs macOS $since, above the deployment target $DEPLOY_TARGET" >&2
            failed=1
        fi
    done < <(sed -n 's/^_\(sqlite3_[A-Za-z0-9_]*\)$/\1/p' <<< "$called" | sort -u)
    if [ "$failed" -ne 0 ]; then
        echo "❌ FATAL: the core calls SQLite functions macOS $DEPLOY_TARGET does not have" >&2
        return 1
    fi
    echo "   ✅ $(basename "$archive") calls the system SQLite, every function present on macOS $DEPLOY_TARGET"
}
