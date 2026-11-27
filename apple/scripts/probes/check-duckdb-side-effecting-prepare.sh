#!/usr/bin/env bash
#
# Measures the libduckdb behavior DuckDBPreparedRun.swift, DuckDBConnection.swift and the core's DuckDB driver prepare
# statements by (core/docs/decisions/0040-duckdb-prepares-inside-a-transaction-it-runs-in.md). Run this after bumping
# libduckdb. It checks that:
#   - a prepare whose binding takes a sequence value invalidates the database outside a transaction, extracted or not
#   - inside a transaction the same prepare, run and committed, keeps the database and takes the value once
#   - a prepare left unrun inside a transaction invalidates the database at COMMIT, and a ROLLBACK keeps it
#   - duckdb_query takes the value once, and a ROLLBACK keeps a taken value
#   - a read left unfinished inside a transaction aborts it when it takes sequence values, and a COMMIT ends it
#   - statements other than BEGIN, COMMIT and ROLLBACK run alike inside a transaction
#   - the words the Swift apps stream for prepare as a SELECT
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEADERS="$ROOT/Plugins/DuckDBDriverPlugin/CDuckDB/include"
LIB="$ROOT/Libs/libduckdb.a"

if [ ! -f "$LIB" ]; then
    echo "error: $LIB is missing. Run scripts/download-libs.sh first." >&2
    exit 3
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.c" <<'PROBE'
#include <stdio.h>
#include <string.h>
#include "duckdb.h"

static int failures = 0;
static duckdb_database db;
static duckdb_connection c;
static char path[1024];

static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) failures++;
}

static int run(const char *sql) {
    duckdb_result r;
    int ok = duckdb_query(c, sql, &r) == DuckDBSuccess;
    duckdb_destroy_result(&r);
    return ok;
}

static long long number(const char *sql) {
    duckdb_result r;
    long long value = -1;
    if (duckdb_query(c, sql, &r) == DuckDBSuccess && duckdb_row_count(&r) > 0) value = duckdb_value_int64(&r, 0, 0);
    duckdb_destroy_result(&r);
    return value;
}

static void fresh(void) {
    char wal[1100];
    snprintf(wal, sizeof wal, "%s.wal", path);
    remove(path);
    remove(wal);
    duckdb_open(path, &db);
    duckdb_connect(db, &c);
    run("CREATE SEQUENCE seq START 20; CREATE TABLE t AS SELECT 1 AS a");
}

static void done(void) {
    duckdb_disconnect(&c);
    duckdb_close(&db);
}

static int alive(void) { return run("SELECT count(*) FROM t"); }

static int prepare_and_run(const char *sql) {
    duckdb_prepared_statement s;
    int ok = duckdb_prepare(c, sql, &s) == DuckDBSuccess;
    if (ok) {
        duckdb_result r;
        ok = duckdb_execute_prepared(s, &r) == DuckDBSuccess;
        duckdb_destroy_result(&r);
    }
    duckdb_destroy_prepare(&s);
    return ok;
}

int main(int argc, char **argv) {
    snprintf(path, sizeof path, "%s/probe.duckdb", argv[1]);
    duckdb_prepared_statement s;
    fprintf(stderr, "libduckdb %s\n", duckdb_library_version());

    const char *binding_writes[] = {"SET threads = nextval('seq')", "SELECT * FROM range(nextval('seq'))", NULL};
    for (int i = 0; binding_writes[i]; i++) {
        fresh();
        duckdb_prepare(c, binding_writes[i], &s);
        duckdb_destroy_prepare(&s);
        check(!alive(), "a prepare whose binding takes a sequence value outside a transaction invalidates the database");
        done();
    }

    fresh();
    duckdb_extracted_statements extracted;
    duckdb_extract_statements(c, "SELECT * FROM range(nextval('seq'))", &extracted);
    duckdb_prepare_extracted_statement(c, extracted, 0, &s);
    duckdb_destroy_prepare(&s);
    duckdb_destroy_extracted(&extracted);
    check(!alive(), "an extracted statement prepares the same way");
    done();

    fresh();
    run("BEGIN TRANSACTION");
    int ran = prepare_and_run("SELECT * FROM range(nextval('seq'))");
    check(ran && run("COMMIT") && alive() && number("SELECT currval('seq')") == 20,
          "inside a transaction the prepare runs, commits and takes the value once");
    done();

    fresh();
    run("BEGIN TRANSACTION");
    duckdb_prepare(c, "SET threads = nextval('seq')", &s);
    duckdb_destroy_prepare(&s);
    check(!run("COMMIT") && !alive(), "a prepare left unrun inside a transaction invalidates the database at COMMIT");
    done();

    fresh();
    run("BEGIN TRANSACTION");
    duckdb_prepare(c, "SET threads = nextval('seq')", &s);
    duckdb_destroy_prepare(&s);
    check(run("ROLLBACK") && alive(), "a ROLLBACK after it keeps the database");
    check(number("SELECT nextval('seq')") == 21, "a ROLLBACK keeps a sequence value taken");
    done();

    fresh();
    check(run("SET memory_limit = nextval('seq') || 'GB'") && number("SELECT currval('seq')") == 20 && alive(),
          "duckdb_query takes the value once and keeps the database");
    done();

    fresh();
    run("BEGIN TRANSACTION");
    duckdb_prepare(c, "SELECT nextval('seq') FROM range(1000000)", &s);
    duckdb_result r;
    duckdb_execute_prepared_streaming(s, &r);
    duckdb_data_chunk chunk = duckdb_fetch_chunk(r);
    duckdb_destroy_data_chunk(&chunk);
    duckdb_destroy_result(&r);
    duckdb_destroy_prepare(&s);
    check(!run("SELECT 1"), "a read left unfinished inside a transaction aborts it when it takes sequence values");
    check(run("COMMIT") && !run("ROLLBACK"), "a COMMIT of the aborted transaction ends it");
    check(alive() && number("SELECT nextval('seq')") > 20, "its values stay taken");
    done();

    const char *alike[] = {
        "CHECKPOINT", "FORCE CHECKPOINT", "VACUUM", "ANALYZE", "ATTACH ':memory:' AS x", "SET threads = 4",
        "RESET threads", "PRAGMA enable_profiling", "LOAD parquet", "CREATE TABLE u (a INT)", "DROP TABLE t",
        "CREATE TEMP TABLE tt (a INT)", "INSERT INTO t VALUES (3)", "SUMMARIZE t", "SHOW TABLES", NULL,
    };
    for (int i = 0; alike[i]; i++) {
        fresh();
        int outside = prepare_and_run(alike[i]);
        done();
        fresh();
        run("BEGIN TRANSACTION");
        int inside = prepare_and_run(alike[i]) && run("COMMIT");
        done();
        char what[200];
        snprintf(what, sizeof what, "%s runs alike inside a transaction", alike[i]);
        check(outside && inside, what);
    }

    fresh();
    const char *streamed[] = {"SELECT 1", "(SELECT 1)", "WITH x AS (SELECT 1) SELECT * FROM x", "FROM t", "VALUES (1)",
                              "TABLE t", "UNPIVOT t ON a INTO NAME k VALUE v", NULL};
    for (int i = 0; streamed[i]; i++) {
        int select = duckdb_prepare(c, streamed[i], &s) == DuckDBSuccess
            && duckdb_prepared_statement_type(s) == DUCKDB_STATEMENT_TYPE_SELECT;
        duckdb_destroy_prepare(&s);
        char what[200];
        snprintf(what, sizeof what, "%s prepares as a SELECT", streamed[i]);
        check(select, what);
    }
    done();
    return failures == 0 ? 0 : 1;
}
PROBE

cc -O1 -I "$HEADERS" "$WORK/probe.c" -Wl,-force_load,"$LIB" -lc++ -o "$WORK/probe"
if "$WORK/probe" "$WORK"; then
    echo "OK: libduckdb prepares, commits and streams the way the DuckDB drivers prepare statements."
    exit 0
fi
echo "error: libduckdb no longer prepares the way ADR 0040 records." >&2
exit 1
