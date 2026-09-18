#!/usr/bin/env bash
#
# Runs every query in DuckDBSchemaQueries.swift against the shipped static library
# with the extension directory pointed at an empty folder, which is what a Mac that
# cannot reach extensions.duckdb.org sees.
#
# The macOS libduckdb is the bare amalgamation and links no extensions, so
# current_database(), current_schema(), information_schema.key_column_usage and
# information_schema.referential_constraints all resolve through a download of
# core_functions at first use. Anchoring the metadata queries on them left an
# offline or firewalled machine with no databases, schemas, tables or columns and
# only "Binder Error: Referenced table \"system\" not found!" in the log. Run this
# after touching DuckDBSchemaQueries.swift or bumping libduckdb.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADERS="$ROOT/Plugins/DuckDBDriverPlugin/CDuckDB/include"
LIB="$ROOT/Libs/libduckdb.a"
SWIFT_FILE="$ROOT/Plugins/DuckDBDriverPlugin/DuckDBSchemaQueries.swift"

if [ ! -f "$LIB" ]; then
    echo "error: $LIB is missing. Run scripts/download-libs.sh first." >&2
    exit 1
fi

FORBIDDEN='current_database\(\)|current_schema\(\)|key_column_usage|referential_constraints'
if grep -nE "$FORBIDDEN" "$SWIFT_FILE" | grep -vE '^\s*[0-9]+:\s*///'; then
    echo "error: the lines above need the core_functions extension, which the macOS libduckdb does not link." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/extensions"

# One record per query: NAME, the SQL, then a lone %% terminator.
awk '
    /^    static let [A-Za-z]+ = """$/ {
        name = $3
        getline
        printf "%s\n", name
        while ($0 !~ /^        """$/) { print; getline }
        print "%%"
        next
    }
' "$SWIFT_FILE" > "$WORK/queries.txt"

DECLARED=$(grep -cE '^    static let [A-Za-z]+ = """$' "$SWIFT_FILE" || true)
EXTRACTED=$(grep -c '^%%$' "$WORK/queries.txt" || true)
if [ "$EXTRACTED" -ne "$DECLARED" ] || [ "$EXTRACTED" -lt 10 ]; then
    echo "error: extracted $EXTRACTED of $DECLARED queries from $SWIFT_FILE; the awk record format no longer matches." >&2
    exit 1
fi

# allTablesMetadata is built by string interpolation rather than declared as a constant, so
# the extractor above cannot see it. It is the one query the app hands straight to the user's
# editor, so it is reproduced here and the two are kept honest by a shape check below.
{
    echo "allTablesMetadata"
    cat <<'SQL'
        SELECT schema_name, table_name AS name, 'BASE TABLE' AS kind
        FROM duckdb_tables()
        WHERE database_name = 'fixture'
          AND schema_name = 'main'
          AND internal = false
        UNION ALL
        SELECT schema_name, view_name, 'VIEW'
        FROM duckdb_views()
        WHERE database_name = 'fixture'
          AND schema_name = 'main'
          AND internal = false
        ORDER BY 2
SQL
    echo "%%"
} >> "$WORK/queries.txt"

for fragment in "FROM duckdb_tables()" "FROM duckdb_views()" "ORDER BY 2"; do
    if ! grep -qF "$fragment" "$SWIFT_FILE"; then
        echo "error: allTablesMetadata in $SWIFT_FILE no longer contains '$fragment'." >&2
        echo "       Update the copy in this script so it keeps testing the real query." >&2
        exit 1
    fi
done

cat > "$WORK/probe.c" <<'PROBE'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "duckdb.h"

static duckdb_connection con;
static int failures;

static void must(const char *sql) {
    duckdb_result r;
    if (duckdb_query(con, sql, &r) == DuckDBError) {
        fprintf(stderr, "setup failed: %s\n  %s\n", sql, duckdb_result_error(&r));
        exit(2);
    }
    duckdb_destroy_result(&r);
}

/* Every query takes the catalog as $1 and, where it filters further, the schema
   as $2 and the object as $3. Binding all three is harmless for a query that
   declares fewer. */
static void check(const char *name, const char *sql) {
    duckdb_prepared_statement stmt = NULL;
    if (duckdb_prepare(con, sql, &stmt) == DuckDBError) {
        printf("FAIL %-26s prepare: %s\n", name, duckdb_prepare_error(stmt));
        duckdb_destroy_prepare(&stmt);
        failures++;
        return;
    }
    idx_t params = duckdb_nparams(stmt);
    const char *values[3] = {"fixture", "main", "child"};
    for (idx_t i = 1; i <= params && i <= 3; i++) {
        duckdb_bind_varchar(stmt, i, values[i - 1]);
    }
    duckdb_result r;
    if (duckdb_execute_prepared(stmt, &r) == DuckDBError) {
        printf("FAIL %-26s %s\n", name, duckdb_result_error(&r));
        failures++;
    } else {
        printf("ok   %-26s %llu row(s), %llu param(s)\n", name,
               (unsigned long long)duckdb_row_count(&r), (unsigned long long)params);
    }
    duckdb_destroy_result(&r);
    duckdb_destroy_prepare(&stmt);
}

int main(int argc, char **argv) {
    duckdb_database db = NULL;
    char *err = NULL;
    if (duckdb_open_ext(argv[1], &db, NULL, &err) == DuckDBError) {
        fprintf(stderr, "open failed: %s\n", err ? err : "(no message)");
        return 2;
    }
    if (duckdb_connect(db, &con) == DuckDBError) { fprintf(stderr, "connect failed\n"); return 2; }

    char buf[4096];
    snprintf(buf, sizeof buf, "SET extension_directory='%s'", argv[2]);
    must(buf);
    must("SET autoinstall_known_extensions=0");
    must("SET autoload_known_extensions=0");

    printf("linked duckdb %s, extensions unavailable\n\n", duckdb_library_version());

    FILE *f = fopen(argv[3], "r");
    if (!f) { fprintf(stderr, "cannot read %s\n", argv[3]); return 2; }

    char name[128] = {0};
    char sql[8192];
    char line[2048];
    int reading = 0;
    while (fgets(line, sizeof line, f)) {
        if (!reading) {
            line[strcspn(line, "\n")] = 0;
            snprintf(name, sizeof name, "%s", line);
            sql[0] = 0;
            reading = 1;
            continue;
        }
        if (strncmp(line, "%%", 2) == 0) {
            check(name, sql);
            reading = 0;
            continue;
        }
        strncat(sql, line, sizeof sql - strlen(sql) - 1);
    }
    fclose(f);

    duckdb_disconnect(&con);
    duckdb_close(&db);

    if (failures) {
        printf("\n%d quer%s need an extension the macOS libduckdb does not link.\n",
               failures, failures == 1 ? "y" : "ies");
        return 1;
    }
    printf("\nEvery query ran with no extensions available.\n");
    return 0;
}
PROBE

clang -O0 -I "$HEADERS" -o "$WORK/probe" "$WORK/probe.c" -Wl,-force_load,"$LIB" -lc++

FIXTURE="$WORK/fixture.duckdb"
cat > "$WORK/fixture.sql" <<'SQL'
CREATE SCHEMA sales;
CREATE TYPE mood AS ENUM ('ok', 'bad');
CREATE TABLE parent(id INTEGER PRIMARY KEY, name VARCHAR NOT NULL DEFAULT 'x');
CREATE TABLE child(cid INTEGER PRIMARY KEY, pid INTEGER REFERENCES parent(id), m mood);
CREATE TABLE combo(a INTEGER, b INTEGER, PRIMARY KEY (a, b));
CREATE TABLE sales.orders(oid INTEGER PRIMARY KEY);
CREATE INDEX idx_child_pid ON child(pid);
CREATE VIEW v_child AS SELECT cid FROM child;
SQL

cat > "$WORK/seed.c" <<'SEED'
#include <stdio.h>
#include <stdlib.h>
#include "duckdb.h"
int main(int argc, char **argv) {
    duckdb_database db = NULL; duckdb_connection con = NULL; char *err = NULL;
    if (duckdb_open_ext(argv[1], &db, NULL, &err) == DuckDBError) return 2;
    if (duckdb_connect(db, &con) == DuckDBError) return 2;
    FILE *f = fopen(argv[2], "r");
    char line[1024];
    while (fgets(line, sizeof line, f)) {
        duckdb_result r;
        if (duckdb_query(con, line, &r) == DuckDBError) {
            fprintf(stderr, "seed failed: %s\n  %s", line, duckdb_result_error(&r));
            return 2;
        }
        duckdb_destroy_result(&r);
    }
    fclose(f);
    duckdb_disconnect(&con); duckdb_close(&db);
    return 0;
}
SEED
clang -O0 -I "$HEADERS" -o "$WORK/seed" "$WORK/seed.c" -Wl,-force_load,"$LIB" -lc++
"$WORK/seed" "$FIXTURE" "$WORK/fixture.sql"

"$WORK/probe" "$FIXTURE" "$WORK/extensions" "$WORK/queries.txt"
