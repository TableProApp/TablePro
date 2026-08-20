#!/usr/bin/env bash
#
# Measures which DuckDB logical types the deprecated duckdb_value_* row API can
# render, then checks that DuckDBTypeRendering.swift agrees.
#
# The Swift table decides which columns are re-read through CAST(col AS VARCHAR).
# A type listed as renderable that the C API cannot actually render produces a
# zero-valued default in the grid instead of the stored value (#2130). Run this
# after bumping libduckdb.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADERS="$ROOT/Plugins/DuckDBDriverPlugin/CDuckDB/include"
LIB="$ROOT/Libs/libduckdb.a"
SWIFT_FILE="$ROOT/Plugins/DuckDBDriverPlugin/DuckDBTypeRendering.swift"

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

typedef struct {
    const char *name;
    const char *expr;
    const char *expected;
} Case;

static const Case cases[] = {
    {"BOOLEAN", "CAST(true AS BOOLEAN)", "true"},
    {"TINYINT", "CAST(1 AS TINYINT)", "1"},
    {"SMALLINT", "CAST(1 AS SMALLINT)", "1"},
    {"INTEGER", "CAST(1 AS INTEGER)", "1"},
    {"BIGINT", "CAST(1 AS BIGINT)", "1"},
    {"UTINYINT", "CAST(1 AS UTINYINT)", "1"},
    {"USMALLINT", "CAST(1 AS USMALLINT)", "1"},
    {"UINTEGER", "CAST(1 AS UINTEGER)", "1"},
    {"UBIGINT", "CAST(1 AS UBIGINT)", "1"},
    {"FLOAT", "CAST(1.5 AS FLOAT)", "1.5"},
    {"DOUBLE", "CAST(1.5 AS DOUBLE)", "1.5"},
    {"DECIMAL", "CAST(1.5 AS DECIMAL(10,2))", "1.50"},
    {"HUGEINT", "CAST(1 AS HUGEINT)", "1"},
    {"UHUGEINT", "CAST(1 AS UHUGEINT)", "1"},
    {"VARCHAR", "CAST('x' AS VARCHAR)", "x"},
    {"BLOB", "CAST('x' AS BLOB)", "x"},
    {"DATE", "DATE '2026-08-14'", "2026-08-14"},
    {"TIME", "TIME '23:59:00.127'", "23:59:00.127"},
    {"TIME_NS", "CAST('23:59:00.123456789' AS TIME_NS)", "23:59:00.123456789"},
    {"INTERVAL", "CAST('1 day' AS INTERVAL)", "1 day"},
    {"TIMESTAMP", "TIMESTAMP '2026-08-14 23:59:00.127'", "2026-08-14 23:59:00.127"},
    {"TIMESTAMP_S", "CAST('2026-08-14 23:59:00' AS TIMESTAMP_S)", ""},
    {"TIMESTAMP_MS", "CAST('2026-08-14 23:59:00.127' AS TIMESTAMP_MS)", ""},
    {"TIMESTAMP_NS", "CAST('2026-08-14 23:59:00.123456789' AS TIMESTAMP_NS)", ""},
    {"TIMESTAMPTZ", "TIMESTAMPTZ '2026-08-14 23:59:00.127+00'", ""},
    {"TIMETZ", "TIMETZ '23:59:00.127+02'", ""},
    {"BIT", "CAST('101' AS BIT)", ""},
    {"UUID", "CAST('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11' AS UUID)", ""},
    {"ENUM", "CAST('a' AS ENUM('a','b'))", ""},
    {"LIST", "CAST('[1, 2, 3]' AS INTEGER[])", ""},
    {"ARRAY", "CAST('[1, 2, 3]' AS INTEGER[3])", ""},
    {"STRUCT", "CAST('{\"a\": 1}' AS STRUCT(a INTEGER))", ""},
    {"MAP", "CAST('{a=1}' AS MAP(VARCHAR, INTEGER))", ""},
    {"UNION", "CAST(1 AS UNION(num INTEGER, str VARCHAR))", ""},
    {"BIGNUM", "CAST(1 AS BIGNUM)", ""},
    {"GEOMETRY", "ST_Point(1, 2)", ""},
};

int main(void) {
    duckdb_database db;
    duckdb_connection con;
    if (duckdb_open(NULL, &db) != DuckDBSuccess) {
        return 2;
    }
    if (duckdb_connect(db, &con) != DuckDBSuccess) {
        return 2;
    }
    fprintf(stderr, "libduckdb %s\n", duckdb_library_version());

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        char sql[512];
        snprintf(sql, sizeof(sql), "SELECT %s AS v", cases[i].expr);
        duckdb_result r;
        if (duckdb_query(con, sql, &r) != DuckDBSuccess) {
            printf("%s\tSKIP\n", cases[i].name);
            duckdb_destroy_result(&r);
            continue;
        }
        char *value = duckdb_value_varchar(&r, 0, 0);
        if (!value) {
            printf("%s\tNULL\n", cases[i].name);
        } else if (cases[i].expected[0] != '\0' && strcmp(value, cases[i].expected) != 0) {
            printf("%s\tWRONG(%s)\n", cases[i].name, value);
        } else {
            printf("%s\tRENDERS\n", cases[i].name);
        }
        if (value) {
            duckdb_free(value);
        }
        duckdb_destroy_result(&r);
    }

    duckdb_disconnect(&con);
    duckdb_close(&db);
    return 0;
}
PROBE

cc -O1 -I "$HEADERS" "$WORK/probe.c" "$LIB" -lc++ -o "$WORK/probe"
"$WORK/probe" > "$WORK/measured.tsv"

# Swift case identifier -> DuckDB type name, e.g. timestampMilliseconds=TIMESTAMP_MS
sed -nE 's/^[[:space:]]*case ([a-zA-Z]+) = "([A-Z_0-9]+)"$/\1=\2/p' "$SWIFT_FILE" > "$WORK/raw_values"

# The identifiers Swift declares as unrenderable.
sed -n '/typesTheValueAPICannotRender/,/^    \]/p' "$SWIFT_FILE" \
    | sed -nE 's/^[[:space:]]*\.([a-zA-Z]+),$/\1/p' > "$WORK/declared_ids"

while read -r identifier; do
    grep "^${identifier}=" "$WORK/raw_values" | cut -d= -f2
done < "$WORK/declared_ids" | sort > "$WORK/declared_all.txt"

if grep -q 'WRONG(' "$WORK/measured.tsv"; then
    echo "error: the value API rendered the wrong text for a type it claims to support." >&2
    grep 'WRONG(' "$WORK/measured.tsv" >&2
    exit 1
fi

awk -F'\t' '$2 != "SKIP" { print $1 }' "$WORK/measured.tsv" | sort > "$WORK/probed.txt"
awk -F'\t' '$2 == "NULL" { print $1 }' "$WORK/measured.tsv" | sort > "$WORK/measured.txt"
awk -F'\t' '$2 == "SKIP" { print "  skipped (needs an extension): " $1 }' "$WORK/measured.tsv" >&2

comm -12 "$WORK/declared_all.txt" "$WORK/probed.txt" > "$WORK/declared.txt"

if diff -u "$WORK/declared.txt" "$WORK/measured.txt" > "$WORK/diff.txt"; then
    echo "OK: DuckDBTypeRendering.swift matches libduckdb for $(wc -l < "$WORK/measured.tsv" | tr -d ' ') probed types."
    exit 0
fi

echo "error: DuckDBTypeRendering.swift disagrees with libduckdb." >&2
echo "  '-' lines are declared unrenderable but render fine (a needless CAST)." >&2
echo "  '+' lines render as NULL but are declared renderable (a #2130-class bug)." >&2
sed '1,2d' "$WORK/diff.txt" >&2
exit 1
