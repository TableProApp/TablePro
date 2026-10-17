# Shared helpers for the native library build scripts.
#
# Sourced, never executed. A script picks this up with:
#
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos.sh"    # macOS builds
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh" # iOS builds
#
# Holds only what both the macOS and the iOS builds use. The macOS-only helpers live in macos.sh,
# which sources this.
#
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034  # the constants below are read by the scripts that source this

[ -n "${TABLEPRO_LIB_COMMON_SOURCED:-}" ] && return 0
TABLEPRO_LIB_COMMON_SOURCED=1

TABLEPRO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TABLEPRO_LIB_DIR/../.." && pwd)"
# Overridable so a rebuild can stage into a scratch directory and be verified before it
# replaces the archives every worktree links against.
LIBS_DIR="${LIBS_DIR:-$REPO_ROOT/Libs}"

# OpenSSL is built from source on both platforms so it carries the right deployment target; a
# Homebrew build targets whatever macOS that machine runs, which is what produced the
# "Symbol not found" crashes these scripts exist to avoid. Digests from https://openssl.org/source/.
OPENSSL_VERSION="3.4.3"
OPENSSL_SHA256="fa727ed1399a64e754030a033435003991aee36bda9a5b080995cb2ac5cf7f37"

# Runs a command silently and shows its output only when it fails.
run_quiet() {
    local logfile
    logfile=$(mktemp)
    if ! "$@" > "$logfile" 2>&1; then
        echo "FAILED: $*" >&2
        tail -50 "$logfile" >&2
        rm -f "$logfile"
        return 1
    fi
    rm -f "$logfile"
}

# Verifies a downloaded file against a checksum the caller pins.
verify_sha256() {
    local file="$1" expected="$2"
    echo "$expected  $file" | shasum -a 256 -c - > /dev/null || {
        echo "ERROR: checksum mismatch for $file" >&2
        echo "       expected $expected" >&2
        echo "       actual   $(shasum -a 256 "$file" | cut -d' ' -f1)" >&2
        return 1
    }
}
