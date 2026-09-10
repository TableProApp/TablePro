#!/usr/bin/env bash
#
# Measures the two libssh2 SFTP behaviours TablePro's transfer code depends on, against the
# vendored archive and a real OpenSSH server.
#
# Both are invisible in the header, which carries no doc comments at all, and both are the kind of
# thing a dependency bump can change silently:
#
#   1. libssh2_sftp_write returns SHORT constantly. A loop that advances its offset by the length it
#      requested rather than the length returned writes a truncated file and reports no error at any
#      point. Measured once at 4,224,304 of 8,388,608 bytes.
#   2. libssh2_sftp_rename_ex cannot replace an existing file against OpenSSH. Its OVERWRITE, ATOMIC
#      and NATIVE flags are SFTP v5, OpenSSH speaks v3, and the header's own libssh2_sftp_rename()
#      convenience macro passes exactly those flags. Only posix_rename_ex replaces a file.
#
# Usage:
#   scripts/check-sftp-contract.sh            # start a throwaway server, measure, tear it down
#   scripts/check-sftp-contract.sh --keep     # leave the server running afterwards
#
# Exits non-zero if either behaviour has changed, which means the transfer code needs re-reading
# rather than the script needs updating.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP="${1:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ "$KEEP" = "--keep" ] || "$ROOT/scripts/sftp-test-server.sh" down > /dev/null 2>&1 || true' EXIT

"$ROOT/scripts/sftp-test-server.sh" up

cat > "$WORK/probe.c" <<'PROBE'
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "libssh2.h"
#include "libssh2_sftp.h"

static int failures = 0;

int main(void) {
    libssh2_init(0);
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(22022);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (connect(sock, (struct sockaddr *)&a, sizeof(a))) { puts("tcp connect failed"); return 2; }

    LIBSSH2_SESSION *ses = libssh2_session_init();
    if (libssh2_session_handshake(ses, sock)) { puts("handshake failed"); return 2; }
    if (libssh2_userauth_password(ses, "tp", "tppass")) { puts("auth failed"); return 2; }
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(ses);
    if (!sftp) { puts("sftp subsystem refused"); return 2; }

    printf("libssh2 %s, SFTP protocol v%d\n", libssh2_version(0), LIBSSH2_SFTP_VERSION);

    /* 1. Short writes. */
    const char *path = "/config/contract.bin";
    const size_t total = 2u * 1024 * 1024, chunk = 32768;
    static char block[32768];
    memset(block, 'x', sizeof(block));

    LIBSSH2_SFTP_HANDLE *h = libssh2_sftp_open_ex(
        sftp, path, (unsigned)strlen(path),
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC, 0644, LIBSSH2_SFTP_OPENFILE);
    if (!h) { puts("open for write failed"); return 2; }

    size_t offset = 0; int shorts = 0;
    while (offset < total) {
        size_t want = (total - offset < chunk) ? (total - offset) : chunk;
        ssize_t n = libssh2_sftp_write(h, block, want);
        if (n < 0) { puts("write failed"); return 2; }
        if ((size_t)n != want) shorts++;
        offset += (size_t)n;
    }
    libssh2_sftp_close_handle(h);

    if (shorts > 0) {
        printf("  PASS  libssh2_sftp_write still returns short (%d times in %zu bytes)\n", shorts, total);
    } else {
        printf("  CHANGED  libssh2_sftp_write returned no short writes; re-read the upload loop\n");
        failures++;
    }

    /* 2. rename_ex cannot replace; posix_rename_ex can. */
    const char *src = "/config/contract-src.bin";
    h = libssh2_sftp_open_ex(sftp, src, (unsigned)strlen(src),
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC, 0644, LIBSSH2_SFTP_OPENFILE);
    libssh2_sftp_write(h, "replacement", 11);
    libssh2_sftp_close_handle(h);

    int rc = libssh2_sftp_rename_ex(sftp, src, (unsigned)strlen(src), path, (unsigned)strlen(path),
        LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE);
    if (rc != 0) {
        printf("  PASS  rename_ex still refuses an existing destination (rc=%d)\n", rc);
    } else {
        printf("  CHANGED  rename_ex replaced a file; the posix_rename requirement may have relaxed\n");
        failures++;
    }

    rc = libssh2_sftp_posix_rename_ex(sftp, src, strlen(src), path, strlen(path));
    if (rc == 0) {
        puts("  PASS  posix_rename_ex still replaces an existing file");
    } else {
        printf("  CHANGED  posix_rename_ex failed (rc=%d); atomic write-back has no primitive\n", rc);
        failures++;
    }

    libssh2_sftp_unlink_ex(sftp, path, (unsigned)strlen(path));
    libssh2_sftp_shutdown(sftp);
    libssh2_session_disconnect(ses, "done");
    libssh2_session_free(ses);
    close(sock);
    libssh2_exit();
    return failures == 0 ? 0 : 1;
}
PROBE

clang -w -arch arm64 -o "$WORK/probe" "$WORK/probe.c" \
    -I "$ROOT/TablePro/Core/SSH/CLibSSH2/include" \
    "$ROOT/Libs/libssh2_arm64.a" "$ROOT/Libs/libssl_arm64.a" "$ROOT/Libs/libcrypto_arm64.a" \
    -lz -framework Security -framework CoreFoundation

"$WORK/probe"
echo "SFTP contract unchanged."
