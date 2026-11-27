#!/usr/bin/env bash
#
# Shows why LibSSH2KeepAlive sends only into a socket with room, against the vendored libssh2 and a
# real OpenSSH server.
#
# libssh2_keepalive_send builds its packet on its own stack (keepalive.c) and counts a send that would
# block as sent. libssh2 keeps a packet it could not send whole and refuses every other send until a call
# with the same buffer address finishes it (transport_send_existing in transport.c). So a keep-alive that
# blocks stops every channel write on the session, the next keep-alive comes only an interval later, and
# from another stack frame it finishes nothing. The probe makes one send would-block through libssh2's
# send callback, then counts the channel writes refused while the socket is writable. Rerun after a
# libssh2 bump: exit 1 means the keep-alive no longer blocks the session and the guard can go.
#
# Usage:
#   scripts/probes/check-libssh2-keepalive-pending.sh
#
# Needs Docker. Starts a throwaway OpenSSH container and removes it on exit.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/openssh-fixture.sh
source "$ROOT/scripts/lib/openssh-fixture.sh"

CONTAINER="tp-keepalive-pending"
PORT="${TABLEPRO_KEEPALIVE_PENDING_PORT:-22024}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; docker rm -f -v "$CONTAINER" > /dev/null 2>&1 || true' EXIT

docker rm -f -v "$CONTAINER" > /dev/null 2>&1 || true
docker run -d --name "$CONTAINER" -p "127.0.0.1:$PORT:2222" \
    -e USER_NAME=tp -e USER_PASSWORD=tppass -e PASSWORD_ACCESS=true -e SUDO_ACCESS=false \
    "$OPENSSH_FIXTURE_IMAGE_10" > /dev/null
openssh_wait_for_banner 127.0.0.1 "$PORT" 60 || { echo "no SSH banner within 60s" >&2; exit 2; }

cat > "$WORK/probe.c" << 'PROBE'
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include "libssh2.h"

static int refuse_next_send = 0;

static LIBSSH2_SEND_FUNC(gated_send) {
    (void)abstract;
    if (refuse_next_send) {
        refuse_next_send = 0;
        return -EAGAIN;
    }
    ssize_t rc = send(socket, buffer, length, flags);
    return rc < 0 ? -errno : rc;
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

__attribute__((noinline)) static int keepalive_here(LIBSSH2_SESSION *s) {
    int next = 0;
    return libssh2_keepalive_send(s, &next);
}

__attribute__((noinline)) static int keepalive_deeper(LIBSSH2_SESSION *s) {
    volatile char pad[512];
    pad[0] = 1;
    return keepalive_here(s) + pad[0] - 1;
}

static int refused_writes(LIBSSH2_CHANNEL *c, int sock, double seconds, int *accepted) {
    const char *line = "ping\n";
    int refused = 0;
    double until = now() + seconds;
    *accepted = 0;
    while (now() < until) {
        ssize_t rc = libssh2_channel_write(c, line, strlen(line));
        if (rc > 0) { *accepted = 1; return refused; }
        if (rc != LIBSSH2_ERROR_EAGAIN) { printf("write failed %zd\n", rc); exit(2); }
        refused++;
        struct pollfd p = { sock, POLLOUT, 0 };
        if (poll(&p, 1, 100) <= 0) { puts("socket not writable"); exit(2); }
    }
    return refused;
}

int main(int argc, char **argv) {
    int port = atoi(argv[1]);
    libssh2_init(0);
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (connect(sock, (struct sockaddr *)&a, sizeof(a))) { puts("tcp connect failed"); exit(2); }
    LIBSSH2_SESSION *s = libssh2_session_init();
    if (libssh2_session_handshake(s, sock)) { puts("handshake failed"); exit(2); }
    if (libssh2_userauth_password(s, "tp", "tppass")) { puts("auth failed"); exit(2); }
    LIBSSH2_CHANNEL *c = libssh2_channel_open_session(s);
    if (!c || libssh2_channel_exec(c, "cat")) { puts("could not start cat"); exit(2); }
    libssh2_session_callback_set2(s, LIBSSH2_CALLBACK_SEND, (libssh2_cb_generic *)gated_send);
    libssh2_session_set_blocking(s, 0);
    libssh2_keepalive_config(s, 1, 2);
    sleep(3);

    refuse_next_send = 1;
    int rc = keepalive_here(s);
    int accepted;
    int blocked = refused_writes(c, sock, 3.0, &accepted);
    printf("keep-alive whose send would block: rc %d; channel writes refused over 3 s with the socket writable: %d\n", rc, blocked);
    int pending = blocked > 0 && !accepted;

    sleep(2);
    rc = keepalive_deeper(s);
    int refusedAfterOther = refused_writes(c, sock, 1.0, &accepted);
    printf("after the next keep-alive from another stack frame (rc %d): refused %d, accepted %d\n", rc, refusedAfterOther, accepted);
    int stillPending = refusedAfterOther > 0 && !accepted;

    sleep(2);
    rc = keepalive_here(s);
    int refusedAfterSame = refused_writes(c, sock, 1.0, &accepted);
    printf("after a keep-alive from the first frame (rc %d): refused %d, accepted %d\n", rc, refusedAfterSame, accepted);
    libssh2_exit();
    return pending && stillPending && accepted ? 0 : 1;
}
PROBE

clang -w -arch arm64 -o "$WORK/probe" "$WORK/probe.c" \
    -I "$ROOT/TablePro/Core/SSH/CLibSSH2/include" \
    "$ROOT/Libs/libssh2_arm64.a" "$ROOT/Libs/libssl_arm64.a" "$ROOT/Libs/libcrypto_arm64.a" \
    -lz -framework Security -framework CoreFoundation

"$WORK/probe" "$PORT"
