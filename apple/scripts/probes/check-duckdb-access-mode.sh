#!/usr/bin/env bash
#
# Measures which paths libduckdb opens with access_mode=READ_ONLY, the facts DuckDBFileKinds
# and DuckDBAccessMode hard-code. A database file honours it whatever it is called; a reader
# (CSV, TSV, JSON, JSON Lines, Parquet, also gzip or zstd compressed), an empty path and
# :memory: refuse it. Run after bumping libduckdb.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEADERS="$ROOT/Plugins/DuckDBDriverPlugin/CDuckDB/include"
LIB="$ROOT/Libs/libduckdb.a"

if [ ! -f "$LIB" ]; then
    echo "error: $LIB is missing. Run scripts/download-libs.sh first." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.c" <<'PROBE'
#include <stdio.h>
#include <string.h>
#include "duckdb.h"

static int open_db(const char *path, int read_only, duckdb_database *db, char **error) {
    duckdb_config config = NULL;
    if (read_only) {
        duckdb_create_config(&config);
        duckdb_set_config(config, "access_mode", "READ_ONLY");
    }
    duckdb_state state = duckdb_open_ext(path, db, config, error);
    if (config) duckdb_destroy_config(&config);
    return state == DuckDBSuccess;
}

int main(int argc, char **argv) {
    if (argc > 2 && strcmp(argv[1], "create") == 0) {
        duckdb_database db;
        duckdb_connection con;
        char *error = NULL;
        if (!open_db(argv[2], 0, &db, &error)) return 2;
        duckdb_connect(db, &con);
        duckdb_query(con, "CREATE TABLE t AS SELECT 1 AS a", NULL);
        duckdb_query(con, "COPY (SELECT 1 AS a) TO 'data.parquet' (FORMAT parquet)", NULL);
        duckdb_disconnect(&con);
        duckdb_close(&db);
        return 0;
    }
    for (int i = 1; i < argc; i++) {
        duckdb_database db;
        char *error = NULL;
        if (!open_db(argv[i], 1, &db, &error)) {
            printf("%s\trefused\n", argv[i]);
            if (error) duckdb_free(error);
            continue;
        }
        duckdb_connection con;
        duckdb_connect(db, &con);
        duckdb_result result;
        int wrote = duckdb_query(con, "CREATE TABLE written(a INTEGER)", &result) == DuckDBSuccess;
        duckdb_destroy_result(&result);
        printf("%s\t%s\n", argv[i], wrote ? "WRITABLE" : "read-only");
        duckdb_disconnect(&con);
        duckdb_close(&db);
    }
    return 0;
}
PROBE

cc -O1 -I "$HEADERS" "$WORK/probe.c" "$LIB" -lc++ -o "$WORK/probe"

cd "$WORK"
./probe create warehouse.duckdb
cp warehouse.duckdb warehouse.db
cp warehouse.duckdb warehouse
cp warehouse.duckdb warehouse.duckdb.bak
/usr/bin/sqlite3 app.sqlite "CREATE TABLE s(a); INSERT INTO s VALUES (1);"
cp app.sqlite app.db
printf 'a,b\n1,2\n' > rows.csv
printf 'a\tb\n1\t2\n' > rows.tsv
printf '[{"a":1}]' > rows.json
printf '{"a":1}\n' > rows.jsonl
cp rows.jsonl rows.ndjson
cp rows.csv UPPER.CSV
gzip -k rows.csv
gzip -k rows.jsonl

databases=(warehouse.duckdb warehouse.db warehouse warehouse.duckdb.bak app.sqlite app.db)
readers=(rows.csv rows.tsv rows.json rows.jsonl rows.ndjson data.parquet UPPER.CSV rows.csv.gz rows.jsonl.gz "" ":memory:")

./probe "${databases[@]}" "${readers[@]}" > measured.tsv
cat measured.tsv

failed=0
for path in "${databases[@]}"; do
    grep -qxF "$path	read-only" measured.tsv || { echo "MISMATCH: $path should open read-only" >&2; failed=1; }
done
for path in "${readers[@]}"; do
    grep -qxF "$path	refused" measured.tsv || { echo "MISMATCH: $path should refuse READ_ONLY" >&2; failed=1; }
done
if [ "$failed" -ne 0 ]; then
    echo "FAIL: update DuckDBFileKinds.opensAsReader and DuckDBAccessMode.carriesAccessMode." >&2
    exit 1
fi
echo "OK: libduckdb honours READ_ONLY on every database file and refuses it on every reader."
