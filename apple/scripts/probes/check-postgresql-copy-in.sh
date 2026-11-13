#!/usr/bin/env bash
#
# Checks what the PostgreSQL driver's copy-in (LibPQCopyIn) relies on, with the libpq the app links
# (apple/Libs/libpq.a) against a live server: rows go as CopyData without psql's `\.` line and end with
# CopyDone; pieces may split a row or a UTF-8 sequence; CRLF rows and a last row with no line break load;
# a bad row and a CopyFail both fail the COPY and abort an open block; a binary COPY shows on its
# PGRES_COPY_IN result; a refused COPY never enters copy-in; a read-only transaction refuses it with
# 25006; a cancel request mid-stream fails it with 57014. It also prints what a sent `\.` line does,
# which PostgreSQL 18 reads as data in CSV.
#
# Usage:
#   apple/scripts/probes/check-postgresql-copy-in.sh "host=127.0.0.1 port=5432 user=postgres dbname=postgres"
#
# Needs apple/scripts/download-libs.sh to have run. Creates and drops the table copy_probe. Measured on
# PostgreSQL 17.11 and 18.6 with libpq 17.4. Exits non-zero on a failure.

set -euo pipefail

CONNINFO="${1:?usage: check-postgresql-copy-in.sh <conninfo>}"
APPLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBS="$APPLE/Libs"
[ -f "$LIBS/libpq.a" ] || { echo "apple/Libs/libpq.a not found; run apple/scripts/download-libs.sh" >&2; exit 3; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/probe.c" << 'C_SOURCE'
#include <libpq-fe.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;

static void check(const char *label, int ok, const char *detail) {
    printf("%s  %s%s%s\n", ok ? "ok  " : "FAIL", label, detail ? ": " : "", detail ? detail : "");
    if (!ok) failures++;
}

static void run(PGconn *c, const char *sql) {
    PGresult *r = PQexec(c, sql);
    ExecStatusType s = PQresultStatus(r);
    if (s != PGRES_COMMAND_OK && s != PGRES_TUPLES_OK) {
        fprintf(stderr, "setup failed: %s: %s", sql, PQerrorMessage(c));
        exit(3);
    }
    PQclear(r);
}

static char *scalar(PGconn *c, const char *sql) {
    static char buf[4096];
    PGresult *r = PQexec(c, sql);
    snprintf(buf, sizeof buf, "%s", PQresultStatus(r) == PGRES_TUPLES_OK && PQntuples(r) > 0 && !PQgetisnull(r, 0, 0)
                                        ? PQgetvalue(r, 0, 0) : "<none>");
    PQclear(r);
    return buf;
}

typedef struct {
    ExecStatusType status;
    char tuples[32];
    char tag[64];
    char state[8];
    char message[512];
    int extra;
} Outcome;

// Sends `data` in pieces of `piece` bytes after a header that answered COPY_IN, ends it, reads every result.
static Outcome copy_in(PGconn *c, const char *header, const char *data, size_t length, size_t piece,
                       const char *fail_reason, int *binary) {
    Outcome o;
    memset(&o, 0, sizeof o);
    PGresult *start = PQexec(c, header);
    o.status = PQresultStatus(start);
    if (binary) *binary = PQbinaryTuples(start);
    if (o.status != PGRES_COPY_IN) {
        const char *st = PQresultErrorField(start, PG_DIAG_SQLSTATE);
        snprintf(o.state, sizeof o.state, "%s", st ? st : "");
        snprintf(o.message, sizeof o.message, "%s", PQresultErrorField(start, PG_DIAG_MESSAGE_PRIMARY) ?: "");
        PQclear(start);
        while ((start = PQgetResult(c))) { o.extra++; PQclear(start); }
        return o;
    }
    PQclear(start);
    for (size_t at = 0; at < length && !fail_reason; at += piece) {
        size_t n = length - at < piece ? length - at : piece;
        if (PQputCopyData(c, data + at, (int)n) != 1) { snprintf(o.message, sizeof o.message, "put failed"); break; }
    }
    if (PQputCopyEnd(c, fail_reason) != 1) snprintf(o.message, sizeof o.message, "end failed");
    PGresult *r = PQgetResult(c);
    o.status = PQresultStatus(r);
    snprintf(o.tuples, sizeof o.tuples, "%s", PQcmdTuples(r));
    snprintf(o.tag, sizeof o.tag, "%s", PQcmdStatus(r));
    const char *st = PQresultErrorField(r, PG_DIAG_SQLSTATE);
    snprintf(o.state, sizeof o.state, "%s", st ? st : "");
    const char *msg = PQresultErrorField(r, PG_DIAG_MESSAGE_PRIMARY);
    if (msg) snprintf(o.message, sizeof o.message, "%s", msg);
    PQclear(r);
    while ((r = PQgetResult(c))) { o.extra++; PQclear(r); }
    return o;
}

static int is_ok(Outcome o, const char *tuples) {
    return o.status == PGRES_COMMAND_OK && strcmp(o.tuples, tuples) == 0 && o.extra == 0;
}

static void describe(char *out, size_t size, Outcome o) {
    snprintf(out, size, "status=%s tuples=%s tag='%s' state=%s msg='%s' extra=%d", PQresStatus(o.status), o.tuples,
             o.tag, o.state, o.message, o.extra);
}

typedef struct { PGconn *conn; } CancelArgs;

static void *cancel_after(void *arg) {
    usleep(300000);
    PGcancel *cancel = PQgetCancel(((CancelArgs *)arg)->conn);
    char err[256];
    PQcancel(cancel, err, sizeof err);
    PQfreeCancel(cancel);
    return NULL;
}

int main(int argc, char **argv) {
    PGconn *c = PQconnectdb(argv[1]);
    if (PQstatus(c) != CONNECTION_OK) { fprintf(stderr, "no server: %s", PQerrorMessage(c)); return 3; }
    printf("libpq %d, server %d\n", PQlibVersion(), PQserverVersion(c));
    char d[1024];
    Outcome o;

    run(c, "DROP TABLE IF EXISTS copy_probe; CREATE TABLE copy_probe (a int, b text)");

    const char *rows = "1\tone\n2\ttwo\n3\t\\N\n";
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", rows, strlen(rows), 1 << 16, NULL, NULL);
    describe(d, sizeof d, o);
    check("text rows without \\. end with CopyDone as COPY 3", is_ok(o, "3") && strcmp(o.tag, "COPY 3") == 0, d);
    check("a NULL marker loads as NULL", strcmp(scalar(c, "SELECT count(*) FROM copy_probe WHERE b IS NULL"), "1") == 0, NULL);
    check("an autocommit COPY leaves the session idle", PQtransactionStatus(c) == PQTRANS_IDLE, NULL);

    const char *with_marker = "4\tfour\n\\.\n";
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", with_marker, strlen(with_marker), 1 << 16, NULL, NULL);
    describe(d, sizeof d, o);
    printf("info  text rows with the \\. line sent: %s\n", d);

    run(c, "TRUNCATE copy_probe");
    const char *csv = "a,b\n5,\"five, quoted\"\n6,\"multi\nline\"\n";
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN WITH (FORMAT csv, HEADER true)", csv, strlen(csv), 1 << 16, NULL, NULL);
    describe(d, sizeof d, o);
    check("CSV with a header line and a quoted line break is COPY 2", is_ok(o, "2"), d);
    check("the quoted line break is kept", strcmp(scalar(c, "SELECT b FROM copy_probe WHERE a = 6"), "multi\nline") == 0, NULL);

    const char *csv_marker = "7,seven\n\\.\n";
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN WITH (FORMAT csv)", csv_marker, strlen(csv_marker), 1 << 16, NULL, NULL);
    describe(d, sizeof d, o);
    printf("info  CSV rows with the \\. line sent: %s\n", d);

    run(c, "TRUNCATE copy_probe");
    const char *utf8 = "8\tcaf\xc3\xa9 \xf0\x9f\x98\x80\n9\tlast row without a line break";
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", utf8, strlen(utf8), 3, NULL, NULL);
    describe(d, sizeof d, o);
    check("3-byte pieces that split a UTF-8 sequence and a last row with no line break load", is_ok(o, "2"), d);
    check("the split sequence arrives whole", strcmp(scalar(c, "SELECT b FROM copy_probe WHERE a = 8"), "caf\xc3\xa9 \xf0\x9f\x98\x80") == 0, NULL);

    run(c, "TRUNCATE copy_probe");
    const char *crlf = "10\tten\r\n11\televen\r\n";
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", crlf, strlen(crlf), 1 << 16, NULL, NULL);
    describe(d, sizeof d, o);
    check("CRLF text rows load", is_ok(o, "2"), d);
    check("a CRLF row keeps no carriage return", strcmp(scalar(c, "SELECT b FROM copy_probe WHERE a = 10"), "ten") == 0, NULL);

    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", "", 0, 1 << 16, NULL, NULL);
    describe(d, sizeof d, o);
    check("no rows is COPY 0", is_ok(o, "0"), d);

    run(c, "BEGIN");
    const char *bad = "12\ttwelve\nx\tbad\n13\tthirteen\n";
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", bad, strlen(bad), 1 << 16, NULL, NULL);
    describe(d, sizeof d, o);
    check("a bad row fails the COPY after CopyDone with 22P02", o.status == PGRES_FATAL_ERROR && strcmp(o.state, "22P02") == 0 && o.extra == 0, d);
    check("inside a block the failed COPY leaves it aborted", PQtransactionStatus(c) == PQTRANS_INERROR, NULL);
    run(c, "ROLLBACK");

    run(c, "BEGIN");
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", rows, strlen(rows), 1 << 16, "canceled by user", NULL);
    describe(d, sizeof d, o);
    check("CopyFail answers 57014 'COPY from stdin failed: canceled by user'",
          o.status == PGRES_FATAL_ERROR && strcmp(o.state, "57014") == 0 && strstr(o.message, "canceled by user") != NULL, d);
    check("CopyFail aborts the block", PQtransactionStatus(c) == PQTRANS_INERROR, NULL);
    run(c, "ROLLBACK");

    run(c, "BEGIN");
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", rows, strlen(rows), 1 << 16, NULL, NULL);
    check("a COPY inside a block leaves it open", is_ok(o, "3") && PQtransactionStatus(c) == PQTRANS_INTRANS, NULL);
    run(c, "ROLLBACK");

    int binary = 0;
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN WITH (FORMAT binary)", "", 0, 1, "binary COPY data cannot come from a script", &binary);
    describe(d, sizeof d, o);
    check("a binary COPY reports binary tuples on its COPY_IN result", binary == 1, NULL);
    check("ending a binary COPY with CopyFail fails it with 57014", o.status == PGRES_FATAL_ERROR && strcmp(o.state, "57014") == 0, d);

    o = copy_in(c, "COPY no_such_table FROM STDIN", rows, strlen(rows), 1 << 16, NULL, NULL);
    describe(d, sizeof d, o);
    check("a COPY the server refuses never enters COPY_IN (42P01)", o.status == PGRES_FATAL_ERROR && strcmp(o.state, "42P01") == 0, d);

    run(c, "START TRANSACTION READ ONLY; SELECT 1");
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", rows, strlen(rows), 1 << 16, NULL, NULL);
    describe(d, sizeof d, o);
    check("a read-only transaction refuses the COPY before COPY_IN (25006)", o.status == PGRES_FATAL_ERROR && strcmp(o.state, "25006") == 0, d);
    run(c, "ROLLBACK");

    // Cancel while rows stream: the server keeps reading pieces and answers 57014 after CopyDone.
    size_t big = 64u * 1024u * 1024u;
    char *lots = malloc(big);
    size_t usable = big - (big % 7);
    for (size_t i = 0; i + 7 <= usable; i += 7) memcpy(lots + i, "1\tabcd\n", 7);
    pthread_t thread;
    CancelArgs args = { c };
    pthread_create(&thread, NULL, cancel_after, &args);
    o = copy_in(c, "COPY copy_probe (a, b) FROM STDIN", lots, usable, 1 << 16, NULL, NULL);
    pthread_join(thread, NULL);
    describe(d, sizeof d, o);
    check("a cancel request mid-stream fails the COPY with 57014", o.status == PGRES_FATAL_ERROR && strcmp(o.state, "57014") == 0, d);
    free(lots);

    run(c, "DROP TABLE copy_probe");
    PQfinish(c);
    printf("%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
C_SOURCE

clang -O1 -o "$WORK_DIR/probe" "$WORK_DIR/probe.c" \
    -I"$APPLE/Plugins/PostgreSQLDriverPlugin/CLibPQ/include" \
    "$LIBS/libpq.a" "$LIBS/libpgcommon.a" "$LIBS/libpgport.a" \
    -L"$LIBS/dylibs" -lssl.3 -lcrypto.3 -lz -framework GSS -Wl,-rpath,"$LIBS/dylibs"

"$WORK_DIR/probe" "$CONNINFO"
