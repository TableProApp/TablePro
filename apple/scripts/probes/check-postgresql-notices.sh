#!/usr/bin/env bash
#
# Check the libpq notice facts LibPQServerMessageSink and LibPQNoticeOutput rely on, against the libpq the plugin
# links and a live server.
#
# - RAISE NOTICE, WARNING and INFO reach the receiver as "<SEVERITY>:  <message>\n" in PQresultErrorMessage.
# - DETAIL and HINT follow as lines of their own, and a newline inside the message stays.
# - PL/pgSQL sets CONTEXT, and libpq's default context visibility leaves it out of a notice's text.
# - A notice raised before an error still arrives.
# - libpq's own notices carry no SQLSTATE.
#
# Usage:
#   scripts/probes/check-postgresql-notices.sh [conninfo]
#
# conninfo defaults to "host=localhost dbname=postgres"; PGUSER and PGPASSWORD apply. Expects English server
# messages. Needs apple/Libs from download-libs.sh. Skips (exit 3) without them or without a server. Exits non-zero
# when a fact no longer holds.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$ROOT/Libs"
INCLUDE="$ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ/include"
CONNINFO="${1:-host=localhost dbname=postgres}"

[ -f "$LIBS/libpq_arm64.a" ] || { echo "skip: run scripts/download-libs.sh" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/probe.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include "libpq-fe.h"

static int failures = 0;
static char text[4096];
static int notices = 0;
static int without_sqlstate = 0;
static int with_context_field = 0;

static void receiver(void *arg, const PGresult *res) {
    (void)arg;
    size_t used = strlen(text);
    snprintf(text + used, sizeof text - used, "%s", PQresultErrorMessage(res));
    notices++;
    if (!PQresultErrorField(res, PG_DIAG_SQLSTATE)) without_sqlstate++;
    if (PQresultErrorField(res, PG_DIAG_CONTEXT)) with_context_field++;
}

static void reset(void) {
    text[0] = '\0';
    notices = without_sqlstate = with_context_field = 0;
}

static void expect(int ok, const char *fact) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", fact);
    if (!ok) {
        printf("     received: \"%s\"\n", text);
        failures++;
    }
}

static void expect_text(PGconn *conn, const char *sql, const char *expected, const char *fact) {
    reset();
    PQclear(PQexec(conn, sql));
    expect(strcmp(text, expected) == 0 && without_sqlstate == 0, fact);
}

int main(int argc, char **argv) {
    PGconn *conn = PQconnectdb(argv[1]);
    if (PQstatus(conn) != CONNECTION_OK) {
        fprintf(stderr, "skip: %s", PQerrorMessage(conn));
        return 3;
    }
    PQsetNoticeReceiver(conn, receiver, NULL);

    expect_text(conn, "DO $$ BEGIN RAISE NOTICE 'step 1 done'; END $$",
                "NOTICE:  step 1 done\n", "RAISE NOTICE is \"NOTICE:  <message>\" plus one newline, with a SQLSTATE");
    expect_text(conn, "DO $$ BEGIN RAISE WARNING 'w'; RAISE INFO 'i'; END $$",
                "WARNING:  w\nINFO:  i\n", "RAISE WARNING and RAISE INFO carry their own severity");
    expect_text(conn, "DO $$ BEGIN RAISE NOTICE 'extras' USING DETAIL = 'the detail', HINT = 'the hint'; END $$",
                "NOTICE:  extras\nDETAIL:  the detail\nHINT:  the hint\n", "DETAIL and HINT are lines of their own");
    expect_text(conn, "DO $$ BEGIN RAISE NOTICE E'line1\\nline2'; END $$",
                "NOTICE:  line1\nline2\n", "a newline inside the message stays");
    expect(with_context_field == 1 && strstr(text, "CONTEXT:") == NULL,
           "PL/pgSQL sets CONTEXT and the text leaves it out");

    reset();
    PGresult *failed = PQexec(conn, "DO $$ BEGIN RAISE NOTICE 'before the error'; RAISE EXCEPTION 'boom'; END $$");
    expect(PQresultStatus(failed) == PGRES_FATAL_ERROR && strcmp(text, "NOTICE:  before the error\n") == 0,
           "a notice raised before an error arrives, and the error does not");
    PQclear(failed);

    PGresult *one = PQexec(conn, "SELECT 1");
    reset();
    (void)PQgetvalue(one, 5, 0);
    PQclear(one);
    expect(notices == 1 && without_sqlstate == 1 && strncmp(text, "NOTICE:  ", 9) != 0,
           "libpq's own notice has no SQLSTATE and no severity prefix");

    PQfinish(conn);
    return failures == 0 ? 0 : 1;
}
EOF

clang -I"$INCLUDE" -o "$WORK/probe" "$WORK/probe.c" \
    "$LIBS/libpq_arm64.a" "$LIBS/libpgcommon_arm64.a" "$LIBS/libpgport_arm64.a" \
    "$LIBS/libssl_arm64.a" "$LIBS/libcrypto_arm64.a" -lz -framework GSS || exit 1

"$WORK/probe" "$CONNINFO"
