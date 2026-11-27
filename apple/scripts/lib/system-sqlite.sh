# The check that the core's static library takes SQLite from the system, as the app does. Sourced, never executed.
# Two copies in one process break each other's POSIX locks on the same file (core/docs/decisions/0010-macos-on-the-core.md),
# and the system's library only has the functions the deployment target's OS shipped: the SDK header marks each newer
# one with API_AVAILABLE, which the core's generated bindings drop.
#
# shellcheck shell=bash

[ -n "${TABLEPRO_SYSTEM_SQLITE_SOURCED:-}" ] && return 0
TABLEPRO_SYSTEM_SQLITE_SOURCED=1

source "$(dirname "${BASH_SOURCE[0]}")/deployment-target.sh"

# Every function and variable sqlite3.h declares, with the release of <platform> (macos, ios) that added it, or 0 when
# it carries no mark.
# Usage: sqlite_header_availability <header> [platform]
sqlite_header_availability() {
    awk -v platform="${2:-macos}" '
        /^API_AVAILABLE\(/ {
            since = "0"
            if (match($0, platform "\\([0-9.]+\\)")) since = substr($0, RSTART + length(platform) + 1, RLENGTH - length(platform) - 2)
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

# Usage: verify_system_sqlite <archive> [sdk platform target system], macOS by default:
#   verify_system_sqlite libtablepro_ffi.a iphoneos ios 18.0 iOS
verify_system_sqlite() {
    local archive="$1" sdk_name="${2:-macosx}" platform="${3:-macos}" target="${4:-$DEPLOY_TARGET}" system="${5:-macOS}"
    local header sdk defined called failed=0 name since
    sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)" || return 1
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
    available="$(sqlite_header_availability "$header" "$platform")"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        since="$(awk -v n="$name" '$1 == n { print $2; exit }' <<< "$available")"
        if [ -z "$since" ]; then
            echo "   ❌ $name is not in $header" >&2
            failed=1
        elif [ "$(printf '%s\n' "$target" "$since" | sort -V | tail -1)" != "$target" ]; then
            echo "   ❌ $name needs $system $since, above the deployment target $target" >&2
            failed=1
        fi
    done < <(sed -n 's/^_\(sqlite3_[A-Za-z0-9_]*\)$/\1/p' <<< "$called" | sort -u)
    if [ "$failed" -ne 0 ]; then
        echo "❌ FATAL: the core calls SQLite functions $system $target does not have" >&2
        return 1
    fi
    echo "   ✅ $(basename "$archive") calls the system SQLite, every function present on $system $target"
}
