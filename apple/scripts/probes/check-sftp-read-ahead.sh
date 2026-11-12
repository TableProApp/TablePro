#!/usr/bin/env bash
#
# Measures how the buffer passed to libssh2_sftp_read sets SFTP download speed over a link with
# latency, against the vendored libssh2 and a real OpenSSH server.
#
# libssh2 keeps buffer_size * 4 bytes of FXP_READ requests in flight (sftp_read in src/sftp.c,
# capped at four channel windows), so a download moves about four buffers per round trip. On
# loopback that never shows. LibSSH2SFTPSession sizes its download buffer on this; rerun after a
# libssh2 bump.
#
# Usage:
#   scripts/probes/check-sftp-read-ahead.sh [delay-ms] [size-mb]   # default 50 ms, 32 MB
#
# Needs Docker. Starts a throwaway OpenSSH container with NET_ADMIN, delays every packet the server
# sends with tc netem, which adds that much to each round trip, and removes the container on exit. Exits non-zero if a 2 MB buffer is not at least three times
# faster than a 32 KB one.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/openssh-fixture.sh
source "$ROOT/scripts/lib/openssh-fixture.sh"

DELAY_MS="${1:-50}"
SIZE_MB="${2:-32}"
CONTAINER="tp-sftp-read-ahead"
PORT="${TABLEPRO_SFTP_READ_AHEAD_PORT:-22023}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; docker rm -f -v "$CONTAINER" > /dev/null 2>&1 || true' EXIT

docker rm -f -v "$CONTAINER" > /dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --cap-add NET_ADMIN \
    -p "127.0.0.1:$PORT:2222" \
    -e USER_NAME=tp -e USER_PASSWORD=tppass -e PASSWORD_ACCESS=true -e SUDO_ACCESS=false \
    "$OPENSSH_FIXTURE_IMAGE_10" > /dev/null
openssh_wait_for_banner 127.0.0.1 "$PORT" 60 || { echo "no SSH banner within 60s" >&2; exit 2; }

docker exec "$CONTAINER" sh -c "apk add --no-cache iproute2 > /dev/null && tc qdisc add dev eth0 root netem delay ${DELAY_MS}ms"
docker exec "$CONTAINER" sh -c "head -c $((SIZE_MB * 1024 * 1024)) /dev/urandom > /config/read-ahead.bin && chmod 644 /config/read-ahead.bin"

cat > "$WORK/probe.c" << 'PROBE'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "libssh2.h"
#include "libssh2_sftp.h"

static double download(int port, size_t buffer_size, size_t *bytes) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (connect(sock, (struct sockaddr *)&a, sizeof(a))) { puts("tcp connect failed"); exit(2); }
    LIBSSH2_SESSION *ses = libssh2_session_init();
    if (libssh2_session_handshake(ses, sock)) { puts("handshake failed"); exit(2); }
    if (libssh2_userauth_password(ses, "tp", "tppass")) { puts("auth failed"); exit(2); }
    LIBSSH2_SFTP *sftp = libssh2_sftp_init(ses);
    if (!sftp) { puts("sftp refused"); exit(2); }
    const char *path = "/config/read-ahead.bin";
    LIBSSH2_SFTP_HANDLE *h = libssh2_sftp_open_ex(sftp, path, (unsigned)strlen(path), LIBSSH2_FXF_READ, 0, LIBSSH2_SFTP_OPENFILE);
    if (!h) { puts("open failed"); exit(2); }
    char *buffer = malloc(buffer_size);
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    *bytes = 0;
    for (;;) {
        ssize_t n = libssh2_sftp_read(h, buffer, buffer_size);
        if (n == 0) break;
        if (n < 0) { printf("read failed %zd\n", n); exit(2); }
        *bytes += (size_t)n;
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    free(buffer);
    libssh2_sftp_close_handle(h);
    libssh2_sftp_shutdown(sftp);
    libssh2_session_disconnect(ses, "done");
    libssh2_session_free(ses);
    close(sock);
    return (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) / 1e9;
}

int main(int argc, char **argv) {
    int port = atoi(argv[1]);
    libssh2_init(0);
    size_t sizes[] = { 32 * 1024, 256 * 1024, 1024 * 1024, 2 * 1024 * 1024 };
    double rates[4];
    for (int i = 0; i < 4; i++) {
        size_t bytes = 0;
        double seconds = download(port, sizes[i], &bytes);
        rates[i] = (double)bytes / seconds / (1024.0 * 1024.0);
        printf("buffer %5zu KB: %zu bytes in %.2f s, %.1f MB/s\n", sizes[i] / 1024, bytes, seconds, rates[i]);
    }
    libssh2_exit();
    return rates[3] >= rates[0] * 3 ? 0 : 1;
}
PROBE

clang -w -arch arm64 -o "$WORK/probe" "$WORK/probe.c" \
    -I "$ROOT/TablePro/Core/SSH/CLibSSH2/include" \
    "$ROOT/Libs/libssh2_arm64.a" "$ROOT/Libs/libssl_arm64.a" "$ROOT/Libs/libcrypto_arm64.a" \
    -lz -framework Security -framework CoreFoundation

echo "libssh2 SFTP download, ${DELAY_MS} ms added to each round trip, ${SIZE_MB} MB file:"
"$WORK/probe" "$PORT"
