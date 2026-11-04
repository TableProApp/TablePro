#!/usr/bin/env bash
#
# Checks that the storage version DuckDBStorageCompatibility pins keeps the files a connection writes readable by
# DuckDB 1.x: the file it creates, one it attaches, and a .duckdb backup. Run after bumping libduckdb.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEADERS="$ROOT/Plugins/DuckDBDriverPlugin/CDuckDB/include"
LIB="$ROOT/Libs/libduckdb.a"
SOURCE="$ROOT/Plugins/DuckDBDriverPlugin/DuckDBStorageCompatibility.swift"

if [ ! -f "$LIB" ]; then
    echo "error: $LIB is missing. Run scripts/download-libs.sh first." >&2
    exit 1
fi
OPTION="$(sed -n 's/.*static let configurationOption = "\(.*\)".*/\1/p' "$SOURCE")"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$SOURCE")"
[ -n "$OPTION" ] && [ -n "$VERSION" ] || {
    echo "error: no configurationOption or version in $SOURCE" >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.c" << 'PROBE'
#include <stdio.h>
#include <string.h>
#include "duckdb.h"

static int run(duckdb_connection con, const char *sql) {
    duckdb_result r;
    int failed = duckdb_query(con, sql, &r) == DuckDBError;
    if (failed) fprintf(stderr, "%s: %s\n", sql, duckdb_result_error(&r));
    duckdb_destroy_result(&r);
    return failed;
}

// write <dir> <option> <version>, or write <dir> with nothing pinned
static int write_files(const char *dir, const char *option, const char *version) {
    duckdb_config config;
    duckdb_database db;
    duckdb_connection con;
    char path[1024], sql[2048];
    duckdb_create_config(&config);
    if (option && duckdb_set_config(config, option, version) == DuckDBError) {
        fprintf(stderr, "%s = %s rejected\n", option, version);
        return 1;
    }
    snprintf(path, sizeof path, "%s/created.duckdb", dir);
    if (duckdb_open_ext(path, &db, config, NULL) == DuckDBError) return 1;
    duckdb_destroy_config(&config);
    duckdb_connect(db, &con);
    int failed = run(con, "CREATE TABLE t AS SELECT range AS i FROM range(1000)");
    snprintf(sql, sizeof sql, "ATTACH '%s/attached.duckdb' AS attached", dir);
    failed |= run(con, sql) || run(con, "CREATE TABLE attached.t AS SELECT 1 AS i");
    snprintf(sql, sizeof sql, "ATTACH '%s/backup.duckdb' AS backup", dir);
    failed |= run(con, sql) || run(con, "COPY FROM DATABASE created TO backup") || run(con, "DETACH backup");
    duckdb_disconnect(&con);
    duckdb_close(&db);
    return failed;
}

// read <file>: the storage version DuckDB records for it
static int read_version(const char *file) {
    duckdb_database db;
    duckdb_connection con;
    duckdb_result r;
    char sql[2048];
    if (duckdb_open(NULL, &db) == DuckDBError || duckdb_connect(db, &con) == DuckDBError) return 1;
    snprintf(sql, sizeof sql, "ATTACH '%s' AS f (READ_ONLY)", file);
    if (run(con, sql)) return 1;
    if (duckdb_query(con, "SELECT tags['storage_version'] FROM duckdb_databases() WHERE database_name = 'f'", &r) == DuckDBError) return 1;
    char *value = duckdb_value_varchar(&r, 0, 0);
    printf("%s\n", value ? value : "");
    duckdb_free(value);
    duckdb_destroy_result(&r);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 3 && strcmp(argv[1], "write") == 0) return write_files(argv[2], argc > 4 ? argv[3] : NULL, argc > 4 ? argv[4] : NULL);
    if (argc == 3 && strcmp(argv[1], "read") == 0) return read_version(argv[2]);
    return 3;
}
PROBE
cc -O1 -Wno-deprecated-declarations -I "$HEADERS" "$WORK/probe.c" -Wl,-force_load,"$LIB" -lc++ -o "$WORK/probe"

mkdir "$WORK/pinned" "$WORK/default"
"$WORK/probe" write "$WORK/pinned" "$OPTION" "$VERSION"
"$WORK/probe" write "$WORK/default"

failed=0
for file in created attached backup; do
    pinned="$("$WORK/probe" read "$WORK/pinned/$file.duckdb")"
    default="$("$WORK/probe" read "$WORK/default/$file.duckdb")"
    printf '%-9s %s = %s: %-8s unpinned: %s\n' "$file" "$OPTION" "$VERSION" "$pinned" "$default"
    case "$pinned" in
        v1.*) ;;
        *)
            echo "MISMATCH: $file.duckdb needs DuckDB $pinned, so DuckDB 1.x cannot open it" >&2
            failed=1
            ;;
    esac
done

if [ "$failed" -ne 0 ]; then
    echo "FAIL: update DuckDBStorageCompatibility.version to a value this libduckdb maps to a 1.x storage version." >&2
    exit 1
fi
echo "OK: every file a pinned connection writes stays readable by DuckDB 1.x."
