#!/usr/bin/env bash
#
# Measures the libduckdb behavior DuckDBConnection.swift and DuckDBResultReader.swift read results by.
#
# A SELECT runs as a streaming result, so a result past PluginRowLimits.emergencyMax rows is exported whole and a
# capped read stops at its cap. A streaming result keeps its connection busy until it ends, so a second connection
# renders each chunk as text. Run this after bumping libduckdb. It checks that:
#   - a streaming result hands back every row of a table larger than the old 5,000,000 row cap
#   - the connection refuses another statement while the result is open, and takes one once it is destroyed
#   - a table function on a second connection renders a chunk fetched from the first, re-binding on every execution
#   - a time zone set on one connection does not reach the other
#   - a statement that changes rows does not stream and reports its row count
#   - dropping an unfinished SELECT that may write aborts the transaction it runs in, and draining it does not
#   - an empty streaming result still reports its columns
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
static duckdb_result *source = NULL;
static duckdb_data_chunk pending = NULL;
static int binds = 0;

static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) failures++;
}

static void reader_bind(duckdb_bind_info info) {
    binds++;
    if (!source) { duckdb_bind_set_error(info, "No result is being read"); return; }
    for (idx_t i = 0; i < duckdb_column_count(source); i++) {
        duckdb_logical_type type = duckdb_column_logical_type(source, i);
        char name[16];
        snprintf(name, sizeof name, "c%llu", (unsigned long long)i + 1);
        duckdb_bind_add_result_column(info, name, type);
        duckdb_destroy_logical_type(&type);
    }
}
static void reader_init(duckdb_init_info info) { duckdb_init_set_max_threads(info, 1); }
static void reader_scan(duckdb_function_info info, duckdb_data_chunk out) {
    (void)info;
    if (!pending) { duckdb_data_chunk_set_size(out, 0); return; }
    for (idx_t i = 0; i < duckdb_data_chunk_get_column_count(pending); i++) {
        duckdb_vector_reference_vector(duckdb_data_chunk_get_vector(out, i), duckdb_data_chunk_get_vector(pending, i));
    }
    duckdb_data_chunk_set_size(out, duckdb_data_chunk_get_size(pending));
    pending = NULL;
}

static int run(duckdb_connection c, const char *sql, duckdb_error_type *type) {
    duckdb_result r;
    int ok = duckdb_query(c, sql, &r) == DuckDBSuccess;
    if (type) *type = ok ? DUCKDB_ERROR_INVALID : duckdb_result_error_type(&r);
    duckdb_destroy_result(&r);
    return ok;
}
static void text(duckdb_connection c, const char *sql, char *out, size_t size) {
    duckdb_result r;
    out[0] = '\0';
    if (duckdb_query(c, sql, &r) == DuckDBSuccess) {
        char *v = duckdb_value_varchar(&r, 0, 0);
        if (v) { snprintf(out, size, "%s", v); duckdb_free(v); }
    }
    duckdb_destroy_result(&r);
}

int main(void) {
    duckdb_database db;
    duckdb_connection session, render;
    if (duckdb_open(NULL, &db) != DuckDBSuccess) return 2;
    if (duckdb_connect(db, &session) != DuckDBSuccess || duckdb_connect(db, &render) != DuckDBSuccess) return 2;
    fprintf(stderr, "libduckdb %s\n", duckdb_library_version());

    duckdb_table_function reader = duckdb_create_table_function();
    duckdb_table_function_set_name(reader, "_probe_reader");
    duckdb_table_function_set_bind(reader, reader_bind);
    duckdb_table_function_set_init(reader, reader_init);
    duckdb_table_function_set_function(reader, reader_scan);
    check(duckdb_register_table_function(render, reader) == DuckDBSuccess, "the reader registers on the second connection");
    duckdb_destroy_table_function(&reader);

    run(session, "CREATE TABLE t AS SELECT i, DATE '2020-01-01' AS d, TIMESTAMPTZ '2026-08-14 23:59:00+00' AS tz "
                 "FROM range(5000100) r(i)", NULL);
    run(session, "SET TimeZone = 'Asia/Tokyo'", NULL);
    run(render, "SET TimeZone = 'UTC'", NULL);
    char a[64], b[64];
    text(session, "SELECT CAST(TIMESTAMPTZ '2026-08-14 23:59:00+00' AS VARCHAR)", a, sizeof a);
    text(render, "SELECT CAST(TIMESTAMPTZ '2026-08-14 23:59:00+00' AS VARCHAR)", b, sizeof b);
    check(strcmp(a, b) != 0, "a time zone belongs to one connection");
    text(session, "SELECT value FROM duckdb_settings() WHERE name = 'TimeZone'", a, sizeof a);
    check(strcmp(a, "Asia/Tokyo") == 0, "duckdb_settings() reports the session time zone");
    run(render, "SET TimeZone = 'Asia/Tokyo'", NULL);

    duckdb_prepared_statement select;
    duckdb_result result;
    duckdb_prepare(session, "SELECT * FROM t", &select);
    check(duckdb_prepared_statement_type(select) == DUCKDB_STATEMENT_TYPE_SELECT, "a SELECT prepares as a SELECT");
    check(duckdb_prepared_statement_column_type(select, 2) == DUCKDB_TYPE_TIMESTAMP_TZ, "a prepared statement knows its column types");
    check(duckdb_execute_prepared_streaming(select, &result) == DuckDBSuccess && duckdb_result_is_streaming(result), "a SELECT streams");
    duckdb_destroy_prepare(&select);

    duckdb_error_type busy;
    check(!run(session, "SELECT 1", &busy) && busy == DUCKDB_ERROR_RESOURCE_IN_USE, "an open streaming result keeps its connection busy");

    source = &result;
    duckdb_prepared_statement projection;
    check(duckdb_prepare(render, "SELECT c1, CAST(c2 AS VARCHAR), CAST(c3 AS VARCHAR) FROM _probe_reader()", &projection) == DuckDBSuccess,
          "the projection prepares against the open result");
    int bindsAfterPrepare = binds;
    unsigned long long total = 0, rendered = 0;
    int firstText = 0;
    duckdb_data_chunk chunk;
    while ((chunk = duckdb_fetch_chunk(result)) != NULL) {
        total += duckdb_data_chunk_get_size(chunk);
        pending = chunk;
        duckdb_result out;
        if (duckdb_execute_prepared(projection, &out) == DuckDBSuccess) {
            duckdb_data_chunk part;
            while ((part = duckdb_fetch_chunk(out)) != NULL) {
                if (rendered == 0) {
                    duckdb_string_t *cells = (duckdb_string_t *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(part, 2));
                    firstText = duckdb_string_t_length(cells[0]) == 22
                        && memcmp(duckdb_string_t_data(&cells[0]), "2026-08-15 08:59:00+09", 22) == 0;
                }
                rendered += duckdb_data_chunk_get_size(part);
                duckdb_destroy_data_chunk(&part);
            }
        }
        duckdb_destroy_result(&out);
        duckdb_destroy_data_chunk(&chunk);
    }
    source = NULL;
    check(duckdb_result_error(&result) == NULL && total == 5000100, "a streaming result hands back every row past 5,000,000");
    check(rendered == total, "the second connection renders every chunk");
    check(firstText, "the rendered text uses the aligned time zone");
    check(binds > bindsAfterPrepare + 1, "the table function binds again on every execution");
    duckdb_destroy_prepare(&projection);
    duckdb_destroy_result(&result);

    duckdb_prepare(session, "SELECT * FROM t", &select);
    duckdb_execute_prepared_streaming(select, &result);
    chunk = duckdb_fetch_chunk(result);
    duckdb_destroy_data_chunk(&chunk);
    duckdb_destroy_result(&result);
    check(run(session, "SELECT 1", NULL), "a destroyed unfinished result frees the connection");

    run(session, "BEGIN", NULL);
    run(session, "INSERT INTO t VALUES (-1, NULL, NULL)", NULL);
    duckdb_execute_prepared_streaming(select, &result);
    chunk = duckdb_fetch_chunk(result);
    duckdb_destroy_data_chunk(&chunk);
    duckdb_destroy_result(&result);
    check(run(session, "SELECT 1", NULL), "dropping an unfinished read-only SELECT keeps the transaction");
    run(session, "ROLLBACK", NULL);
    duckdb_destroy_prepare(&select);

    run(session, "CREATE SEQUENCE sq", NULL);
    duckdb_prepared_statement writing;
    duckdb_prepare(session, "SELECT nextval('sq') FROM t", &writing);
    run(session, "BEGIN", NULL);
    duckdb_execute_prepared_streaming(writing, &result);
    chunk = duckdb_fetch_chunk(result);
    duckdb_destroy_data_chunk(&chunk);
    duckdb_destroy_result(&result);
    duckdb_error_type aborted;
    check(!run(session, "SELECT 1", &aborted) && aborted == DUCKDB_ERROR_TRANSACTION, "dropping an unfinished SELECT that may write aborts the transaction");
    run(session, "ROLLBACK", NULL);

    run(session, "BEGIN", NULL);
    duckdb_execute_prepared_streaming(writing, &result);
    while ((chunk = duckdb_fetch_chunk(result)) != NULL) duckdb_destroy_data_chunk(&chunk);
    duckdb_destroy_result(&result);
    check(run(session, "SELECT 1", NULL), "draining it keeps the transaction");
    run(session, "ROLLBACK", NULL);
    duckdb_destroy_prepare(&writing);

    duckdb_prepared_statement insert;
    duckdb_prepare(session, "INSERT INTO t SELECT * FROM t LIMIT 5", &insert);
    duckdb_execute_prepared_streaming(insert, &result);
    check(!duckdb_result_is_streaming(result) && duckdb_rows_changed(&result) == 5, "a statement that changes rows does not stream and reports its count");
    duckdb_destroy_result(&result);
    duckdb_destroy_prepare(&insert);

    duckdb_prepare(session, "SELECT * FROM t WHERE i < -5", &select);
    duckdb_execute_prepared_streaming(select, &result);
    chunk = duckdb_fetch_chunk(result);
    check(chunk == NULL && duckdb_result_error(&result) == NULL && duckdb_column_count(&result) == 3, "an empty streaming result reports its columns");
    duckdb_destroy_result(&result);
    duckdb_destroy_prepare(&select);

    duckdb_disconnect(&render);
    duckdb_disconnect(&session);
    duckdb_close(&db);
    return failures == 0 ? 0 : 1;
}
PROBE

cc -O1 -I "$HEADERS" "$WORK/probe.c" -Wl,-force_load,"$LIB" -lc++ -o "$WORK/probe"
if "$WORK/probe"; then
    echo "OK: libduckdb streams, renders and aborts the way the DuckDB driver reads results."
    exit 0
fi
echo "error: libduckdb no longer behaves the way DuckDBConnection.swift reads results." >&2
exit 1
