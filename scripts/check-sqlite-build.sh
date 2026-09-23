#!/usr/bin/env bash
#
# Asserts that Libs/libsqlite3_vendored.a is the SQLite the SQLite and libSQL plugins expect.
#
# Three things are checked against the archive itself, because each one is a hand-maintained
# claim that nothing else verifies:
#
#   1. The compile options scripts/build-sqlite.sh sets actually reached the binary: extension
#      loading present, FTS3_TOKENIZER absent, and the features the system build offered (FTS5,
#      R-Tree, math functions, dbstat, UPDATE ... LIMIT) all there.
#   2. The loading sequence the plugins rely on holds: SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION set
#      through the CSQLite shim opens the C API only, the load_extension() SQL function stays
#      "not authorized" throughout, a loaded extension keeps working once loading is closed
#      again, and it is registered on that connection only.
#   3. No sqlite3_ symbol is exported, so a plugin bundle never offers a second sqlite3_open to the
#      process that also links the system library.
#   4. TablePro/Core/Utilities/SQL/SQLiteBuiltinNames.swift names exactly the functions, table-valued
#      functions and keywords this SQLite provides. A statement from outside the app may call only
#      those on a connection that loads extensions, so a stale list either refuses a built-in or
#      lets an extension's function through.
#
# Run after bumping SQLITE_VERSION or editing the options in build-sqlite.sh, and before
# publishing a rebuilt libsqlite3_vendored.
#
# Usage: scripts/check-sqlite-build.sh [--write-builtin-names]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSQLITE="$ROOT/Packages/TableProCore/Sources/CSQLite"
LIB="$ROOT/Libs/libsqlite3_vendored.a"

if [ ! -f "$LIB" ]; then
    echo "error: $LIB is missing. Run scripts/download-libs.sh or scripts/build-sqlite.sh first." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d /tmp/sqlite-build-check.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
ARCH="$(uname -m)"

cat > "$WORK_DIR/tableproprobe.c" << 'EOF'
#include "sqlite3ext.h"
SQLITE_EXTENSION_INIT1

static void probe(sqlite3_context *context, int argc, sqlite3_value **argv) {
    sqlite3_result_text(context, "loaded", -1, SQLITE_STATIC);
}

int sqlite3_tableproprobe_init(sqlite3 *db, char **error, const sqlite3_api_routines *api) {
    SQLITE_EXTENSION_INIT2(api);
    return sqlite3_create_function(db, "tablepro_probe", 0, SQLITE_UTF8, 0, probe, 0, 0);
}
EOF

cat > "$WORK_DIR/harness.c" << 'EOF'
#include <stdio.h>
#include <string.h>
#include "tablepro_sqlite3.h"

static int failures = 0;

static void expect(int condition, const char *what) {
    printf("%-64s %s\n", what, condition ? "ok" : "FAILED");
    if (!condition) failures++;
}

static int run(sqlite3 *db, const char *sql, char *out, size_t size) {
    sqlite3_stmt *statement = 0;
    out[0] = 0;
    int rc = sqlite3_prepare_v2(db, sql, -1, &statement, 0);
    if (rc == SQLITE_OK) {
        rc = sqlite3_step(statement);
        if (rc == SQLITE_ROW) {
            const unsigned char *text = sqlite3_column_text(statement, 0);
            snprintf(out, size, "%s", text ? (const char *)text : "");
            rc = SQLITE_OK;
        } else if (rc == SQLITE_DONE) {
            rc = SQLITE_OK;
        }
    }
    if (rc != SQLITE_OK) snprintf(out, size, "%s", sqlite3_errmsg(db));
    sqlite3_finalize(statement);
    return rc;
}

static int load(sqlite3 *db, const char *path, char *out, size_t size) {
    char *error = 0;
    int rc = sqlite3_load_extension(db, path, 0, &error);
    snprintf(out, size, "%s", error ? error : "");
    sqlite3_free(error);
    return rc;
}

int main(int argc, char **argv) {
    const char *extension = argv[1];
    const char *required[] = {
        "ENABLE_FTS3", "ENABLE_FTS4", "ENABLE_FTS5", "ENABLE_RTREE", "ENABLE_MATH_FUNCTIONS",
        "ENABLE_PERCENTILE", "ENABLE_DBSTAT_VTAB", "ENABLE_BYTECODE_VTAB", "ENABLE_CARRAY",
        "ENABLE_COLUMN_METADATA", "ENABLE_SESSION", "ENABLE_SNAPSHOT", "ENABLE_PREUPDATE_HOOK",
        "ENABLE_UPDATE_DELETE_LIMIT", "ENABLE_API_ARMOR", "THREADSAFE=2", 0
    };
    const char *forbidden[] = { "OMIT_LOAD_EXTENSION", "ENABLE_FTS3_TOKENIZER", 0 };
    char out[1024];
    int state = -1;

    printf("SQLite %s\n", sqlite3_libversion());
    expect(sqlite3_libversion_number() >= 3053000, "version is at least 3.53.0");
    for (int i = 0; required[i]; i++) {
        char label[128];
        snprintf(label, sizeof label, "compiled with %s", required[i]);
        expect(sqlite3_compileoption_used(required[i]), label);
    }
    for (int i = 0; forbidden[i]; i++) {
        char label[128];
        snprintf(label, sizeof label, "compiled without %s", forbidden[i]);
        expect(!sqlite3_compileoption_used(forbidden[i]), label);
    }

    sqlite3 *db = 0;
    sqlite3 *other = 0;
    sqlite3_open(":memory:", &db);
    sqlite3_open(":memory:", &other);

    run(db, "CREATE TABLE t(x)", out, sizeof out);
    run(db, "INSERT INTO t VALUES (1), (2)", out, sizeof out);
    expect(run(db, "DELETE FROM t LIMIT 1", out, sizeof out) == SQLITE_OK, "DELETE ... LIMIT parses");

    expect(load(db, extension, out, sizeof out) != SQLITE_OK && strstr(out, "not authorized"),
           "C API refused before loading is opened");

    int rc = tablepro_sqlite3_set_extension_loading(db, 1, &state);
    expect(rc == SQLITE_OK && state == 1, "shim opens the C API");

    char sql[1100];
    snprintf(sql, sizeof sql, "SELECT load_extension('%s')", extension);
    expect(run(db, sql, out, sizeof out) != SQLITE_OK && strstr(out, "not authorized"),
           "load_extension() SQL function refused while the C API is open");

    expect(load(db, extension, out, sizeof out) == SQLITE_OK, "C API loads with the derived entry point");
    expect(run(db, "SELECT tablepro_probe()", out, sizeof out) == SQLITE_OK && strcmp(out, "loaded") == 0,
           "loaded function answers");

    rc = tablepro_sqlite3_set_extension_loading(db, 0, &state);
    expect(rc == SQLITE_OK && state == 0, "shim closes the C API");
    expect(load(db, extension, out, sizeof out) != SQLITE_OK && strstr(out, "not authorized"),
           "C API refused once loading is closed");
    expect(run(db, sql, out, sizeof out) != SQLITE_OK && strstr(out, "not authorized"),
           "load_extension() SQL function refused once loading is closed");
    expect(run(db, "SELECT tablepro_probe()", out, sizeof out) == SQLITE_OK && strcmp(out, "loaded") == 0,
           "loaded function still answers once loading is closed");
    expect(run(other, "SELECT tablepro_probe()", out, sizeof out) != SQLITE_OK,
           "another connection does not see the function");

    sqlite3_close(db);
    sqlite3_close(other);
    printf("\n%d failure%s\n", failures, failures == 1 ? "" : "s");
    return failures == 0 ? 0 : 1;
}
EOF

xcrun clang -arch "$ARCH" -dynamiclib -I "$CSQLITE/include" \
    "$WORK_DIR/tableproprobe.c" -o "$WORK_DIR/tableproprobe.dylib"
xcrun clang -arch "$ARCH" -I "$CSQLITE/include" \
    "$WORK_DIR/harness.c" "$CSQLITE/tablepro_sqlite3.c" "$LIB" -o "$WORK_DIR/harness"

status=0
"$WORK_DIR/harness" "$WORK_DIR/tableproprobe.dylib" || status=1

exported="$(xcrun nm -m "$LIB" 2> /dev/null | grep -E ' external _sqlite3_' | grep -cv 'private external' || true)"
if [ "$exported" -eq 0 ]; then
    printf '%-64s ok\n' "no sqlite3_ symbol is exported"
else
    printf '%-64s FAILED (%s exported)\n' "no sqlite3_ symbol is exported" "$exported"
    status=1
fi

# The functions, table-valued functions and keywords this SQLite provides, which
# SQLiteBuiltinNames.swift repeats so the app can tell a call into SQLite from a call into an
# extension without a connection. The table-valued ones are registered lazily and never appear in
# pragma_module_list, so each candidate is asked for directly.
cat > "$WORK_DIR/names.c" << 'EOF'
#include <stdio.h>
#include "sqlite3.h"

static void rows(sqlite3 *db, const char *label, const char *sql) {
    sqlite3_stmt *statement = 0;
    sqlite3_prepare_v2(db, sql, -1, &statement, 0);
    while (sqlite3_step(statement) == SQLITE_ROW) printf("%s %s\n", label, sqlite3_column_text(statement, 0));
    sqlite3_finalize(statement);
}

int main(void) {
    const char *tableValued[] = { "json_each", "json_tree", "jsonb_each", "jsonb_tree", "carray", "generate_series", 0 };
    sqlite3 *db = 0;
    sqlite3_open(":memory:", &db);
    rows(db, "function", "SELECT DISTINCT lower(name) FROM pragma_function_list WHERE builtin");
    rows(db, "table", "SELECT DISTINCT lower(name) FROM pragma_module_list");
    for (int i = 0; tableValued[i]; i++) {
        char sql[128];
        sqlite3_stmt *statement = 0;
        snprintf(sql, sizeof sql, "SELECT * FROM %s LIMIT 0", tableValued[i]);
        if (sqlite3_prepare_v2(db, sql, -1, &statement, 0) == SQLITE_OK) printf("table %s\n", tableValued[i]);
        sqlite3_finalize(statement);
    }
    for (int i = 0; i < sqlite3_keyword_count(); i++) {
        const char *name = 0;
        int length = 0;
        sqlite3_keyword_name(i, &name, &length);
        printf("keyword %.*s\n", length, name);
    }
    sqlite3_close(db);
    return 0;
}
EOF

xcrun clang -arch "$ARCH" -I "$CSQLITE/include" "$WORK_DIR/names.c" "$LIB" -o "$WORK_DIR/names"
"$WORK_DIR/names" > "$WORK_DIR/names.txt"

swift_set() {
    local label="$1" property="$2"
    printf '    static let %s: Set<String> = [\n' "$property"
    grep "^$label " "$WORK_DIR/names.txt" | cut -d' ' -f2 | tr '[:upper:]' '[:lower:]' | sort -u \
        | sed 's/.*/        "&",/' | sed '$ s/,$//'
    printf '    ]\n'
}

{
    printf '//\n//  SQLiteBuiltinNames.swift\n//  TablePro\n//\n\n'
    printf '/// Generated from Libs/libsqlite3_vendored.a by scripts/check-sqlite-build.sh --write-builtin-names,\n'
    printf '/// which fails whenever this list and the library disagree.\n'
    printf 'enum SQLiteBuiltinNames {\n'
    swift_set function functions
    printf '\n'
    swift_set table tableValuedFunctions
    printf '\n'
    swift_set keyword keywords
    printf '}\n'
} > "$WORK_DIR/SQLiteBuiltinNames.swift"

BUILTIN_NAMES="$ROOT/TablePro/Core/Utilities/SQL/SQLiteBuiltinNames.swift"
if [ "${1:-}" = "--write-builtin-names" ]; then
    cp "$WORK_DIR/SQLiteBuiltinNames.swift" "$BUILTIN_NAMES"
    printf '%-64s written\n' "SQLiteBuiltinNames.swift"
elif diff -u "$BUILTIN_NAMES" "$WORK_DIR/SQLiteBuiltinNames.swift"; then
    printf '%-64s ok\n' "SQLiteBuiltinNames.swift matches the library"
else
    printf '%-64s FAILED\n' "SQLiteBuiltinNames.swift matches the library"
    echo "       rerun with --write-builtin-names and review the diff" >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    echo "error: Libs/libsqlite3_vendored.a is not the SQLite the plugins expect." >&2
fi
exit "$status"
