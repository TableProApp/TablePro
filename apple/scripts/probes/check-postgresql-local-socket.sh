#!/usr/bin/env bash
#
# Check the libpq facts PostgreSQLLocalSocket.swift and the ~/.pgpass rule hard-code, against the
# libpq the plugin links and a server that listens on its socket only.
#
# - `host=<directory>` dials `<directory>/.s.PGSQL.<port>`; the socket file itself as `host` fails.
# - No sslmode encrypts a socket connection, and a missing root certificate does not stop it.
# - A comma in `host` makes two hosts, so a directory with a comma cannot be named.
# - The default socket directory is /tmp, which ~/.pgpass looks up as `localhost`.
# - pg_dump takes the directory with -h.
#
# Usage:
#   scripts/probes/check-postgresql-local-socket.sh
#
# Needs initdb, pg_ctl and pg_dump (brew install postgresql@17) and apple/Libs from
# download-libs.sh. Skips (exit 3) without them. Exits non-zero when a fact no longer holds.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$ROOT/Libs"
INCLUDE="$ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ/include"
PORT=54619

for tool in initdb pg_ctl pg_dump; do
    command -v "$tool" >/dev/null || { echo "skip: $tool not on PATH" >&2; exit 3; }
done
[ -f "$LIBS/libpq_arm64.a" ] || { echo "skip: run scripts/download-libs.sh" >&2; exit 3; }

# sun_path holds 103 bytes, so the socket lives in a short directory, not under $TMPDIR.
WORK="$(mktemp -d)"
SOCKET_DIR="$(mktemp -d /tmp/tp-pgsock.XXXX)"
cleanup() {
    pg_ctl -D "$WORK/data" -m immediate stop >/dev/null 2>&1
    rm -rf "$WORK" "$SOCKET_DIR"
}
trap cleanup EXIT

initdb -D "$WORK/data" -U "$(whoami)" --auth-local=peer --auth-host=reject >/dev/null || exit 1
cat >>"$WORK/data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$SOCKET_DIR'
port = $PORT
EOF
pg_ctl -D "$WORK/data" -l "$WORK/server.log" -w start >/dev/null || { cat "$WORK/server.log"; exit 1; }

cat >"$WORK/probe.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libpq-fe.h"

static int failures = 0;

static void expect(int ok, const char *fact) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", fact);
    if (!ok) failures++;
}

static PGconn *open_with(const char *dir, const char *extra) {
    char conninfo[512];
    snprintf(conninfo, sizeof conninfo, "host='%s' port=%s dbname=postgres connect_timeout=3 %s",
             dir, getenv("PROBE_PORT"), extra);
    return PQconnectdb(conninfo);
}

int main(void) {
    const char *dir = getenv("PROBE_DIR");
    char file[256];
    snprintf(file, sizeof file, "%s/.s.PGSQL.%s", dir, getenv("PROBE_PORT"));

    PGconn *conn = open_with(dir, "");
    expect(PQstatus(conn) == CONNECTION_OK, "the directory as host connects (peer, no user)");
    PQfinish(conn);

    conn = open_with(file, "");
    expect(PQstatus(conn) != CONNECTION_OK, "the socket file as host fails");
    PQfinish(conn);

    conn = open_with(dir, "sslmode=verify-full sslrootcert=/nonexistent");
    expect(PQstatus(conn) == CONNECTION_OK && !PQsslInUse(conn), "verify-full over a socket connects without TLS");
    PQfinish(conn);

    char comma[300];
    snprintf(comma, sizeof comma, "%s,/nonexistent", dir);
    conn = open_with(comma, "");
    expect(PQstatus(conn) == CONNECTION_OK && strcmp(PQhost(conn), dir) == 0, "a comma splits host into two hosts");
    PQfinish(conn);

    conn = PQconnectStart("dbname=postgres");
    expect(strcmp(PQhost(conn), "/tmp") == 0, "the default socket directory is /tmp");
    PQfinish(conn);

    setenv("PGPASSFILE", getenv("PROBE_PGPASS"), 1);
    conn = PQconnectStart("host=/tmp port=5432 dbname=db user=u");
    expect(strcmp(PQpass(conn), "by-localhost") == 0, "~/.pgpass looks /tmp up as localhost");
    PQfinish(conn);
    conn = PQconnectStart("host=/var/run/postgresql port=5432 dbname=db user=u");
    expect(strcmp(PQpass(conn), "by-path") == 0, "~/.pgpass looks another directory up by its path");
    PQfinish(conn);

    return failures == 0 ? 0 : 1;
}
EOF

printf 'localhost:5432:*:u:by-localhost\n/var/run/postgresql:5432:*:u:by-path\n' >"$WORK/pgpass"
chmod 600 "$WORK/pgpass"

clang -I"$INCLUDE" -o "$WORK/probe" "$WORK/probe.c" \
    "$LIBS/libpq_arm64.a" "$LIBS/libpgcommon_arm64.a" "$LIBS/libpgport_arm64.a" \
    "$LIBS/libssl_arm64.a" "$LIBS/libcrypto_arm64.a" || exit 1

status=0
PROBE_DIR="$SOCKET_DIR" PROBE_PORT="$PORT" PROBE_PGPASS="$WORK/pgpass" "$WORK/probe" || status=1

if pg_dump --no-password -h "$SOCKET_DIR" -p "$PORT" -Fc -d postgres -f "$WORK/out.dump"; then
    echo "ok   pg_dump -h <directory> dumps over the socket"
else
    echo "FAIL pg_dump -h <directory> dumps over the socket"
    status=1
fi

exit "$status"
