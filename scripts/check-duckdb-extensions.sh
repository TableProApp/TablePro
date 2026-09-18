#!/usr/bin/env bash
#
# Asserts that the shipped Libs/libduckdb.a actually links the extensions
# scripts/duckdb-macos-extensions.cmake declares.
#
# The two drifted apart once and nothing caught it. The cmake file listed
# core_functions, json, parquet, icu and autocomplete, and the published library
# linked none of them, so `sum`, `avg`, `round`, `json_extract` and
# `COPY ... (FORMAT PARQUET)` all failed with "not in the catalog, but it exists
# in the <name> extension" on any Mac that could not reach extensions.duckdb.org.
# The config was right and the binary was stale, which is invisible unless
# something asks the binary.
#
# Run after bumping DUCKDB_VERSION in build-duckdb.sh, after editing
# duckdb-macos-extensions.cmake, and before publishing a rebuilt libduckdb.
#
# Usage: scripts/check-duckdb-extensions.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADERS="$ROOT/Plugins/DuckDBDriverPlugin/CDuckDB/include"
LIB="$ROOT/Libs/libduckdb.a"
EXTENSION_CONFIG="$ROOT/scripts/duckdb-macos-extensions.cmake"

if [ ! -f "$LIB" ]; then
    echo "error: $LIB is missing. Run scripts/download-libs.sh first." >&2
    exit 1
fi

# One probe query per extension, chosen so it fails with a catalog error rather
# than a syntax error when the extension is absent.
probe_for() {
    case "$1" in
        core_functions) echo "SELECT sum(1)" ;;
        json) echo "SELECT json_extract('{\\\"a\\\":1}', '\$.a')" ;;
        parquet) echo "COPY (SELECT 1 AS a) TO '\$TMP/probe.parquet' (FORMAT PARQUET)" ;;
        icu) echo "SELECT strftime(DATE '2020-01-01', '%Y')" ;;
        autocomplete) echo "SELECT * FROM sql_auto_complete('SEL')" ;;
        *) echo "" ;;
    esac
}

EXTENSIONS="$(sed -nE 's/^duckdb_extension_load\(([a-z_]+)\)?.*/\1/p' "$EXTENSION_CONFIG" | sort -u)"
if [ -z "$EXTENSIONS" ]; then
    echo "error: no duckdb_extension_load entries found in $EXTENSION_CONFIG" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d /tmp/duckdb-ext-check.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

{
    echo '#include <stdio.h>'
    echo '#include <string.h>'
    echo '#include "duckdb.h"'
    echo 'int main(void) {'
    echo '  duckdb_database db; duckdb_connection con; int failures = 0;'
    echo '  if (duckdb_open(NULL, &db) == DuckDBError) { printf("open failed\n"); return 2; }'
    echo '  if (duckdb_connect(db, &con) == DuckDBError) { printf("connect failed\n"); return 2; }'
    for extension in $EXTENSIONS; do
        query="$(probe_for "$extension")"
        [ -z "$query" ] && continue
        query="${query//\$TMP/$WORK_DIR}"
        echo "  { duckdb_result r;"
        echo "    if (duckdb_query(con, \"$query\", &r) == DuckDBError) {"
        echo "      printf(\"%-16s MISSING  %s\n\", \"$extension\", duckdb_result_error(&r)); failures++;"
        echo "    } else { printf(\"%-16s linked\n\", \"$extension\"); }"
        echo "    duckdb_destroy_result(&r); }"
    done
    echo '  duckdb_disconnect(&con); duckdb_close(&db);'
    echo '  if (failures > 0) {'
    echo '    printf("\n%d extension(s) the build config declares are not in the library.\n", failures);'
    echo '    printf("Rebuild with scripts/build-duckdb.sh both, then publish with scripts/publish-libs.sh.\n");'
    echo '    return 1;'
    echo '  }'
    echo '  printf("\nEvery declared extension is linked in.\n");'
    echo '  return 0;'
    echo '}'
} > "$WORK_DIR/probe.c"

ARCH="$(uname -m)"
clang -arch "$ARCH" -I "$HEADERS" "$WORK_DIR/probe.c" "$LIB" -lc++ -o "$WORK_DIR/probe"
"$WORK_DIR/probe"
