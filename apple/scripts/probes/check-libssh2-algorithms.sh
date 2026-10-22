#!/usr/bin/env bash
#
# Lists the SSH methods an older libs-<n> release's libssh2 offered and Libs/libssh2.a does not, and
# the other way round, by key exchange, host key, cipher and MAC. Each list comes from
# libssh2_session_supported_algs, the lists a handshake offers.
#
# SSHNegotiationFailure in TableProSSHTransport tells the user a server offers only methods TablePro
# no longer supports from a list written by hand. Run this after rebuilding libssh2 and compare.
#
# Usage: scripts/probes/check-libssh2-algorithms.sh [libs-<n>]   # default libs-2, which 0.83.0-beta.1 ships
#
# Needs gh, or curl, to fetch that release's macOS archive.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OLD="${1:-libs-2}"
REPO="TableProApp/TablePro"
HEADERS="$ROOT/TablePro/Core/SSH/CLibSSH2/include"
ARCHIVE="tablepro-libs-${OLD#libs-}.tar.gz"

for required in "$ROOT/Libs/libssh2.a" "$ROOT/Libs/libssl.a" "$ROOT/Libs/libcrypto.a" "$HEADERS/libssh2.h"; do
    if [ ! -e "$required" ]; then
        echo "error: $required is missing. Run scripts/download-libs.sh first." >&2
        exit 1
    fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/old"

if command -v gh > /dev/null 2>&1; then
    gh release download "$OLD" --repo "$REPO" --pattern "$ARCHIVE" --dir "$WORK" > /dev/null
else
    curl -fsSL -o "$WORK/$ARCHIVE" "https://github.com/$REPO/releases/download/$OLD/$ARCHIVE"
fi
tar xzf "$WORK/$ARCHIVE" -C "$WORK/old" 'libssh2*.a' 'libssl*.a' 'libcrypto*.a'

cat > "$WORK/algorithms.c" << 'EOF'
#include <stdio.h>
#include <libssh2.h>

static void print(LIBSSH2_SESSION *session, int type, const char *label) {
    const char **names = NULL;
    int count = libssh2_session_supported_algs(session, type, &names);
    for (int index = 0; index < count; index++) {
        printf("%-8s %s\n", label, names[index]);
    }
    if (count > 0) {
        libssh2_free(session, names);
    }
}

int main(void) {
    libssh2_init(0);
    LIBSSH2_SESSION *session = libssh2_session_init();
    print(session, LIBSSH2_METHOD_KEX, "kex");
    print(session, LIBSSH2_METHOD_HOSTKEY, "hostkey");
    print(session, LIBSSH2_METHOD_CRYPT_CS, "cipher");
    print(session, LIBSSH2_METHOD_MAC_CS, "mac");
    fprintf(stderr, "libssh2 %s\n", libssh2_version(0));
    libssh2_session_free(session);
    libssh2_exit();
    return 0;
}
EOF

list() {
    local libs="$1" name="$2"
    clang -arch "$(uname -m)" -mmacosx-version-min=13.0 -I "$HEADERS" "$WORK/algorithms.c" \
        "$libs/libssh2.a" "$libs/libssl.a" "$libs/libcrypto.a" -lz -o "$WORK/$name-probe"
    "$WORK/$name-probe" 2> "$WORK/$name.version" | sort > "$WORK/$name.txt"
}

list "$WORK/old" old
list "$ROOT/Libs" current

echo "$OLD: $(cat "$WORK/old.version"), Libs/: $(cat "$WORK/current.version")"
echo ""
echo "Offered by $OLD, not by Libs/:"
comm -23 "$WORK/old.txt" "$WORK/current.txt"
echo ""
echo "Offered by Libs/, not by $OLD:"
comm -13 "$WORK/old.txt" "$WORK/current.txt"
