#!/usr/bin/env bash
#
# Checks the facts DuckDBIsolatedImport.swift relies on, against the shipped Libs/libduckdb.a and
# with the open options and SET statements read from that file:
#
# - An export folder whose schema.sql writes, reads, attaches, loads, installs or reconfigures fails
#   inside the locked instance, and nothing lands outside the folder or in ~/.duckdb.
# - A genuine export restored through the locked instance, then ATTACH (READ_ONLY) and
#   COPY FROM DATABASE (SCHEMA) and (DATA) as prepared statements, matches IMPORT DATABASE run in
#   the session.
#
# Not checked: foreign keys. DuckDB 1.5 inserts COPY FROM DATABASE (DATA) tables in parallel, so a
# child table can fail its key at random; DuckDB 2.0.0 orders them (duckdb/duckdb c111e955fb).
#
# Usage: scripts/probes/check-duckdb-isolated-import.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEADERS="$ROOT/Plugins/DuckDBDriverPlugin/CDuckDB/include"
LIB="$ROOT/Libs/libduckdb.a"
SWIFT_FILE="$ROOT/Plugins/DuckDBDriverPlugin/DuckDBIsolatedImport.swift"

if [ ! -f "$LIB" ]; then
    echo "error: $LIB is missing. Run scripts/download-libs.sh first." >&2
    exit 1
fi

WORK="$(cd "$(mktemp -d /tmp/duckdb-isolated-import.XXXXXX)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/harness.c" << 'HARNESS'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "duckdb.h"

// harness [-q] [-o name=value]... <db> <statement>...: one line per statement, OK or ERR, then rows.
int main(int argc, char **argv) {
    duckdb_config config;
    int prepared = 1, i = 1;
    duckdb_create_config(&config);
    for (; i < argc; i++) {
        if (strcmp(argv[i], "-q") == 0) { prepared = 0; continue; }
        if (strcmp(argv[i], "-o") != 0) break;
        char *option = strdup(argv[++i]), *value = strchr(option, '=');
        *value++ = 0;
        if (duckdb_set_config(config, option, value) == DuckDBError) { printf("REJECTED %s\n", option); return 2; }
    }
    duckdb_database db; duckdb_connection con; char *error = NULL;
    if (duckdb_open_ext(argv[i++], &db, config, &error) == DuckDBError) { printf("OPEN %s\n", error); return 2; }
    duckdb_connect(db, &con);
    for (; i < argc; i++) {
        duckdb_result r;
        duckdb_prepared_statement st = NULL;
        duckdb_state state;
        if (prepared) {
            if (duckdb_prepare(con, argv[i], &st) == DuckDBError) {
                printf("ERR %s\n", duckdb_prepare_error(st));
                duckdb_destroy_prepare(&st);
                continue;
            }
            state = duckdb_execute_prepared(st, &r);
        } else {
            state = duckdb_query(con, argv[i], &r);
        }
        if (state == DuckDBError) {
            char *message = strdup(duckdb_result_error(&r));
            for (char *c = message; *c; c++) if (*c == '\n') *c = ' ';
            printf("ERR %s\n", message);
            free(message);
        } else {
            printf("OK\n");
            for (idx_t row = 0; row < duckdb_row_count(&r); row++) {
                for (idx_t col = 0; col < duckdb_column_count(&r); col++) {
                    char *v = duckdb_value_varchar(&r, col, row);
                    printf("%s%s", col ? " | " : "  ", v ? v : "NULL");
                    duckdb_free(v);
                }
                printf("\n");
            }
        }
        duckdb_destroy_result(&r);
        duckdb_destroy_prepare(&st);
    }
    duckdb_disconnect(&con);
    duckdb_close(&db);
    return 0;
}
HARNESS
cc -O1 -w -I "$HEADERS" "$WORK/harness.c" "$LIB" -lc++ -o "$WORK/harness"

OPEN_OPTIONS=()
while read -r option; do
    OPEN_OPTIONS+=(-o "$option")
done < <(sed -nE 's/^ *\("([a-z_]+)", "([a-z]+)"\),$/\1=\2/p' "$SWIFT_FILE")
LOCKDOWN="$(sed -nE 's/^ *"(SET [^"]*)",$/\1/p' "$SWIFT_FILE")"
if [ "${#OPEN_OPTIONS[@]}" -ne 6 ] || [ "$(printf '%s\n' "$LOCKDOWN" | wc -l | tr -d ' ')" -ne 3 ]; then
    echo "error: could not read three open options and three SET statements from $SWIFT_FILE" >&2
    exit 1
fi

export HOME="$WORK/home"
mkdir -p "$HOME" "$WORK/outside" "$WORK/h" "$WORK/run"

# The sequence DuckDBIsolatedImport runs: open options, the SET statements, then IMPORT DATABASE.
isolated_import() {
    local folder="$1" db="$2"
    shift 2
    local quoted statements=()
    quoted="'$(printf '%s' "$folder" | sed "s/'/''/g")'"
    while IFS= read -r statement; do
        statements+=("${statement//\\(DuckDBSchemaQueries.quoteLiteral(folder))/$quoted}")
    done <<< "$LOCKDOWN"
    "$WORK/harness" -q "${OPEN_OPTIONS[@]}" "$db" "${statements[@]}" "IMPORT DATABASE $quoted" "$@"
}

secret="$WORK/secret.txt"
echo "TOP SECRET" > "$secret"
echo "original" > "$WORK/outside/victim.csv"
echo "not an extension" > "$WORK/outside/fake.duckdb_extension"
hostile() {
    mkdir -p "$WORK/h/$1"
    printf '%s\n' "$2" > "$WORK/h/$1/schema.sql"
    : > "$WORK/h/$1/load.sql"
}
hostile copy_out "COPY (SELECT 'pwned' AS x) TO '$WORK/outside/copy_out.csv';"
hostile copy_dotdot "COPY (SELECT 'pwned' AS x) TO '$WORK/h/copy_dotdot/../../outside/dotdot.csv';"
hostile copy_relative "COPY (SELECT 'pwned' AS x) TO 'relative_out.csv';"
hostile symlink_dir "COPY (SELECT 'pwned' AS x) TO '$WORK/h/symlink_dir/escape/through_link.csv';"
ln -s "$WORK/outside" "$WORK/h/symlink_dir/escape"
hostile symlink_file_write "COPY (SELECT 'pwned' AS x) TO '$WORK/h/symlink_file_write/victim.csv' (HEADER false);"
ln -s "$WORK/outside/victim.csv" "$WORK/h/symlink_file_write/victim.csv"
hostile symlink_file_read "CREATE TABLE stolen AS SELECT content FROM read_text('$WORK/h/symlink_file_read/leak.txt');"
ln -s "$secret" "$WORK/h/symlink_file_read/leak.txt"
hostile attach_new "ATTACH '$WORK/outside/attached.duckdb' AS x; CREATE TABLE x.t AS SELECT 1 AS a;"
hostile install "INSTALL httpfs;"
hostile load_file "LOAD '$WORK/outside/fake.duckdb_extension';"
hostile load_known "LOAD json;"
hostile set_external "SET enable_external_access = true; COPY (SELECT 1 AS x) TO '$WORK/outside/reenabled.csv';"
hostile set_allowed "SET allowed_directories = ['/']; COPY (SELECT 1 AS x) TO '$WORK/outside/widened.csv';"
hostile set_extension_dir "SET extension_directory = '$WORK/outside/ext';"
hostile read_etc "CREATE TABLE stolen AS SELECT content FROM read_text('/etc/hosts');"
hostile read_csv_home "CREATE TABLE stolen AS SELECT * FROM read_csv('$secret');"
hostile glob_home "CREATE TABLE listing AS SELECT * FROM glob('$WORK/*');"
hostile view_reads "CREATE VIEW v AS SELECT content FROM read_text('/etc/hosts');"
hostile macro_reads "CREATE MACRO steal() AS TABLE SELECT content FROM read_text('$secret');"
hostile persistent_secret "CREATE PERSISTENT SECRET s (TYPE s3, KEY_ID 'a', SECRET 'b');"
hostile export_out "CREATE TABLE t AS SELECT 1 AS a; EXPORT DATABASE '$WORK/outside/exported';"
hostile profile_out "PRAGMA enable_profiling = 'json'; PRAGMA profiling_output = '$WORK/outside/profile.json'; SELECT 1;"

failures=0
cd "$WORK/run"
for folder in "$WORK"/h/*; do
    name="$(basename "$folder")"
    result="$(isolated_import "$folder" "$WORK/run/$name.duckdb" | tail -1)"
    leaked="$(find "$WORK/outside" "$HOME" "$WORK/run" -mindepth 1 ! -name '*.duckdb' ! -name '*.wal' \
        ! -path "$WORK/outside/victim.csv" ! -path "$WORK/outside/fake.duckdb_extension" | tr '\n' ' ')"
    if [[ "$result" != ERR* ]] || [ -n "$leaked" ] || [ "$(cat "$WORK/outside/victim.csv")" != original ]; then
        echo "FAIL $name: ${result:0:160} ${leaked:+wrote $leaked}"
        failures=$((failures + 1))
    else
        echo "refused $name: ${result:4:110}"
    fi
done

genuine="$WORK/genuine"
"$WORK/harness" -q "$WORK/source.duckdb" \
    "CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy')" \
    "CREATE SEQUENCE order_seq START 100" \
    "CREATE SCHEMA app" \
    "CREATE TABLE app.customers (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL UNIQUE, feeling mood, tags VARCHAR[], addr STRUCT(street VARCHAR, zip INTEGER), photo BLOB, note VARCHAR)" \
    "CREATE TABLE app.orders (id INTEGER PRIMARY KEY DEFAULT nextval('order_seq'), customer_id INTEGER, qty INTEGER CHECK (qty > 0), price DECIMAL(10,2), total DECIMAL(12,2) GENERATED ALWAYS AS (qty * price) VIRTUAL, created TIMESTAMP)" \
    "CREATE INDEX orders_created ON app.orders(created)" \
    "INSERT INTO app.customers VALUES (1, 'Ann', 'happy', ['a','b'], {'street': 'Main', 'zip': 1000}, '\\x00\\x01\\xFF'::BLOB, NULL), (2, 'Bob', NULL, NULL, NULL, NULL, 'two lines'), (3, 'Cé', 'sad', [], {'street': NULL, 'zip': NULL}, ''::BLOB, 'x')" \
    "INSERT INTO app.orders (customer_id, qty, price, created) VALUES (1, 2, 3.50, '2026-01-01 10:00:00'), (2, 1, 9.99, NULL)" \
    "CREATE VIEW app.big_orders AS SELECT o.id, c.name, o.total FROM app.orders o JOIN app.customers c ON c.id = o.customer_id WHERE o.qty > 1" \
    "CREATE MACRO app.double_it(x) AS x * 2" \
    "CREATE MACRO app.orders_of(cid) AS TABLE SELECT * FROM app.orders WHERE customer_id = cid" \
    "EXPORT DATABASE '$genuine' (FORMAT PARQUET)" > /dev/null

describe=(
    "SELECT schema_name, table_name, sql FROM duckdb_tables() WHERE database_name = current_database() ORDER BY 1, 2"
    "SELECT schema_name, view_name, sql FROM duckdb_views() WHERE NOT internal AND database_name = current_database() ORDER BY 1, 2"
    "SELECT schema_name, function_name, macro_definition FROM duckdb_functions() WHERE NOT internal AND database_name = current_database() ORDER BY 1, 2"
    "SELECT schema_name, sequence_name, start_value, last_value FROM duckdb_sequences() WHERE database_name = current_database() ORDER BY 1, 2"
    "SELECT schema_name, index_name, sql FROM duckdb_indexes() WHERE database_name = current_database() ORDER BY 1, 2"
    "SELECT schema_name, table_name, constraint_text FROM duckdb_constraints() WHERE database_name = current_database() ORDER BY 1, 2, 3"
    "SELECT type_name FROM duckdb_types() WHERE NOT internal AND database_name = current_database() ORDER BY 1"
    "SELECT id, name, feeling::VARCHAR, tags::VARCHAR, addr::VARCHAR, hex(photo), note FROM app.customers ORDER BY id"
    "SELECT * FROM app.orders ORDER BY id"
    "SELECT * FROM app.big_orders ORDER BY id"
    "SELECT app.double_it(21), (SELECT count(*) FROM app.orders_of(1))"
)

"$WORK/harness" -q "$WORK/session_import.duckdb" "IMPORT DATABASE '$genuine'" > "$WORK/steps.txt"
isolated_import "$genuine" "$WORK/staged.duckdb" >> "$WORK/steps.txt"
"$WORK/harness" "$WORK/session_copy.duckdb" \
    "ATTACH '$WORK/staged.duckdb' AS bak (READ_ONLY)" \
    "COPY FROM DATABASE bak TO session_copy (SCHEMA)" \
    "COPY FROM DATABASE bak TO session_copy (DATA)" \
    "DETACH bak" >> "$WORK/steps.txt"
"$WORK/harness" "$WORK/session_import.duckdb" "${describe[@]}" > "$WORK/expected.txt"
"$WORK/harness" "$WORK/session_copy.duckdb" "${describe[@]}" > "$WORK/measured.txt"

if grep -q '^ERR' "$WORK/steps.txt" "$WORK/expected.txt" || ! diff -u "$WORK/expected.txt" "$WORK/measured.txt"; then
    echo "FAIL genuine export: the isolated restore differs from IMPORT DATABASE in the session"
    failures=$((failures + 1))
else
    echo "restored genuine export: $(grep -c '^  ' "$WORK/measured.txt") catalog and data rows match IMPORT DATABASE"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed."
    exit 1
fi
echo "OK: every hostile folder failed in the locked instance, and the genuine export restored unchanged."
