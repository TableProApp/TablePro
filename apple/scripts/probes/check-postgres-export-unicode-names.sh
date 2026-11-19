#!/usr/bin/env bash
#
# Checks that the SQL export and the Data Dictionary keep apart relations, schemas, sequences and enum types whose
# names differ only in Unicode form (NFC and NFD), which PostgreSQL keeps apart and Swift's String equates.
#
# Builds this checkout's PostgreSQL driver, SQL export and Data Dictionary plugins with SwiftPM, loads a fixture with
# two tables named café (composed and decomposed, one keyed to the other, a generated and a plain column of one name),
# two sequences and two enum types named alike the same way, and two schemas named café with a table t each. For each
# set it exports every table with each table read alone and with the schema-wide reads the driver declares, diffs the
# two dumps and the two dictionaries, then restores the schema-wide dump into emptied schemas and compares the catalog
# and the rows with what was dumped.
#
# Usage: scripts/probes/check-postgres-export-unicode-names.sh [host] [port]
# Environment: PGUSER (default the current user), PGPASSWORD, PSQL, PROBE_APPLE_ROOT (the apple/ folder to build,
# default this checkout's), PROBE_DATABASE (default tablepro_perf_unicode_names): a database that must not exist yet,
# which it creates and drops.
# Prints OK, or BUG with what differs. Exits 0, 1 on a difference, 2 when it cannot run.
set -euo pipefail

ROOT="${PROBE_APPLE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PROBES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
USER_NAME="${PGUSER:-$(id -un)}"
DATABASE="${PROBE_DATABASE:-tablepro_perf_unicode_names}"
[[ "$DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "FAIL: PROBE_DATABASE must be a plain lowercase name" >&2; exit 2; }
PSQL="${PSQL:-$(command -v psql || true)}"
[[ -n "$PSQL" ]] || { echo "FAIL: psql not found; set PSQL" >&2; exit 2; }
COMPOSED=$'caf\xc3\xa9'
DECOMPOSED=$'cafe\xcc\x81'

WORK="$(mktemp -d)"
CREATED=0
cleanup() {
    if [[ $CREATED -eq 1 ]]; then
        "$PSQL" -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" \
            > /dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

run_sql() { "$PSQL" -X -q -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$USER_NAME" "$@"; }

run_sql -d postgres -Atc 'SELECT 1' > /dev/null || { echo "FAIL: cannot connect to $HOST:$PORT" >&2; exit 2; }
echo "PostgreSQL $(run_sql -d postgres -Atc 'SHOW server_version') at $HOST:$PORT, plugins from $ROOT"

mkdir -p "$WORK/Sources/ProbeDriver" "$WORK/Sources/ProbeSQLExport" "$WORK/Sources/ProbeDataDictionary" \
    "$WORK/Sources/Probe"
for source in "$ROOT"/Plugins/PostgreSQLDriverPlugin/*.swift; do
    ln -s "$source" "$WORK/Sources/ProbeDriver/$(basename "$source")"
done
for shared in PluginConnectTimeout PluginQueryTimeout PluginURLSessionTaskBox PluginRedirectRefusingDelegate; do
    ln -s "$ROOT/Plugins/Shared/$shared.swift" "$WORK/Sources/ProbeDriver/$shared.swift"
done
for source in "$ROOT"/Plugins/SQLExportPlugin/*.swift; do
    ln -s "$source" "$WORK/Sources/ProbeSQLExport/$(basename "$source")"
done
for source in "$ROOT"/Plugins/DataDictionaryExportPlugin/*.swift; do
    ln -s "$source" "$WORK/Sources/ProbeDataDictionary/$(basename "$source")"
done
for shared in PluginExportOutputBuffer PluginHexText PluginExportSpelling; do
    [[ -f "$ROOT/Plugins/Shared/$shared.swift" ]] || continue
    ln -s "$ROOT/Plugins/Shared/$shared.swift" "$WORK/Sources/ProbeSQLExport/$shared.swift"
    [[ $shared == PluginExportSpelling ]] && ln -s "$ROOT/Plugins/Shared/$shared.swift" "$WORK/Sources/ProbeDataDictionary/$shared.swift"
done
ln -s "$PROBES/postgres-export-unicode-names-probe.swift" "$WORK/Sources/Probe/Probe.swift"
ln -s "$ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ" "$WORK/CModule"
# The app's export adapter asks for the export reads where PluginKit has them, and for the shared reads before that.
EXPORT_READS=""
grep -q "func fetchAllColumnsForExport" "$ROOT/Plugins/TableProPluginKit/PluginDatabaseDriver.swift" \
    && EXPORT_READS='.define("EXPORT_READS"),'
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .unsafeFlags(["-Xcc", "-I$ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ/include"])
]
func core(_ name: String) -> Target.Dependency { .product(name: name, package: "TableProCore") }
let package = Package(
    name: "ExportUnicodeNamesProbe", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .systemLibrary(name: "CLibPQ", path: "CModule"),
        .target(name: "ProbeDriver", dependencies: [
            "CLibPQ", core("TableProPluginKit"), core("TableProCoreTypes"), core("TableProKerberos"),
            core("TableProGeometry"), core("TableProPostgreSQLCore"), core("TableProSQLVocabulary"),
            core("TableProSQLQuoting"), core("TableProTLSClientIdentity"), core("TableProLogRedaction")
        ], path: "Sources/ProbeDriver", swiftSettings: settings),
        .target(name: "ProbeSQLExport", dependencies: [core("TableProPluginKit"), core("TableProGzip")],
            path: "Sources/ProbeSQLExport", swiftSettings: settings),
        .target(name: "ProbeDataDictionary", dependencies: [core("TableProPluginKit")],
            path: "Sources/ProbeDataDictionary", swiftSettings: settings),
        .executableTarget(name: "Probe", dependencies: [
            "ProbeDriver", "ProbeSQLExport", "ProbeDataDictionary", core("TableProPluginKit")
        ], path: "Sources/Probe", swiftSettings: [$EXPORT_READS] + settings,
            linkerSettings: [.unsafeFlags([
                "-L$ROOT/Libs", "-L$ROOT/Libs/dylibs", "-Xlinker", "-rpath", "-Xlinker", "$ROOT/Libs/dylibs",
                "$ROOT/Libs/libpq.a", "$ROOT/Libs/libpgcommon.a", "$ROOT/Libs/libpgport.a",
                "-lssl.3", "-lcrypto.3", "-lz", "-framework", "GSS"
            ])])
    ])
MANIFEST
echo "Building the driver, the SQL export and the Data Dictionary..."
if ! (cd "$WORK" && swift build --jobs 2 > "$WORK/build.log" 2>&1); then
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 2
fi

if [[ -n "$(run_sql -d postgres -Atc "SELECT 1 FROM pg_catalog.pg_database WHERE datname = '$DATABASE'")" ]]; then
    echo "FAIL: database $DATABASE already exists; drop it or set PROBE_DATABASE" >&2
    exit 2
fi
run_sql -d postgres -c "CREATE DATABASE $DATABASE ENCODING 'UTF8' TEMPLATE template0" > /dev/null
CREATED=1

fixture() {
    case "$1" in
    uni) cat <<'SQL'
CREATE SCHEMA uni;
SET search_path = uni;
CREATE TYPE "état" AS ENUM ('x', 'y');
CREATE TYPE U&"e\0301tat" AS ENUM ('p', 'q');
CREATE SEQUENCE "café_seq" START 10;
CREATE SEQUENCE U&"cafe\0301_seq" START 50;
CREATE TABLE "café" (id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    a integer GENERATED ALWAYS AS (id * 2) STORED, code integer DEFAULT nextval('uni."café_seq"'), mood "état");
CREATE TABLE U&"cafe\0301" (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, a integer,
    code integer DEFAULT nextval(U&'uni."cafe\0301_seq"'), mood U&"e\0301tat", ref integer REFERENCES "café" (id));
CREATE INDEX "café_code" ON "café" (code);
CREATE INDEX U&"cafe\0301_ref" ON U&"cafe\0301" (ref);
COMMENT ON TABLE "café" IS 'composed';
COMMENT ON TABLE U&"cafe\0301" IS 'decomposed';
CREATE TABLE plain (id integer PRIMARY KEY, note text);
INSERT INTO "café" (mood) VALUES ('x'), ('y');
INSERT INTO U&"cafe\0301" (a, mood, ref) VALUES (7, 'p', 1), (8, 'q', 2);
INSERT INTO plain VALUES (1, 'one');
SQL
    ;;
    schemas) cat <<'SQL'
CREATE SCHEMA "café";
CREATE SCHEMA U&"cafe\0301";
CREATE TABLE "café".t (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, x integer);
CREATE TABLE "café".u (k integer);
CREATE TABLE U&"cafe\0301".t (y text);
CREATE TABLE U&"cafe\0301".v (k integer);
INSERT INTO "café".t (x) VALUES (1), (2);
INSERT INTO "café".u VALUES (3);
INSERT INTO U&"cafe\0301".t VALUES ('decomposed');
INSERT INTO U&"cafe\0301".v VALUES (4);
SQL
    ;;
    esac
}

drop_schemas() {
    case "$1" in
    uni) printf '%s\n' 'DROP SCHEMA uni CASCADE; CREATE SCHEMA uni;' ;;
    schemas) printf '%s\n' 'DROP SCHEMA "café" CASCADE; DROP SCHEMA U&"cafe\0301" CASCADE;' \
        'CREATE SCHEMA "café"; CREATE SCHEMA U&"cafe\0301";' ;;
    esac
}

# Every column, constraint, index, comment, sequence position and row of the fixture schemas, by exact name.
snapshot() {
    run_sql -d "$DATABASE" -At > "$1" <<'SQL'
CREATE FUNCTION pg_temp.table_rows(relation regclass) RETURNS SETOF text LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE format('SELECT t::text FROM %s t ORDER BY 1', relation);
END $$;
WITH fixture AS (
    SELECT c.oid, n.nspname || '.' || c.relname AS relation
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('uni', 'café', U&'cafe\0301') AND c.relkind = 'r'
)
SELECT line FROM (
    SELECT f.relation || ' column ' || a.attnum || ' ' || a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
        || ' notnull=' || a.attnotnull || ' identity=' || a.attidentity::text || ' generated=' || a.attgenerated::text
        || ' default=' || coalesce(pg_get_expr(d.adbin, d.adrelid), '') AS line
    FROM fixture f
    JOIN pg_catalog.pg_attribute a ON a.attrelid = f.oid AND a.attnum > 0 AND NOT a.attisdropped
    LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    UNION ALL
    SELECT f.relation || ' constraint ' || con.conname || ' ' || pg_get_constraintdef(con.oid)
    FROM fixture f JOIN pg_catalog.pg_constraint con ON con.conrelid = f.oid
    UNION ALL
    SELECT f.relation || ' index ' || pg_get_indexdef(i.indexrelid)
    FROM fixture f JOIN pg_catalog.pg_index i ON i.indrelid = f.oid
    UNION ALL
    SELECT f.relation || ' comment ' || coalesce(obj_description(f.oid, 'pg_class'), '')
    FROM fixture f
    UNION ALL
    SELECT f.relation || ' row ' || r FROM fixture f, pg_temp.table_rows(f.oid) r
    UNION ALL
    SELECT schemaname || '.' || sequencename || ' sequence ' || coalesce(last_value::text, '')
    FROM pg_catalog.pg_sequences WHERE schemaname IN ('uni', 'café', U&'cafe\0301')
) lines
ORDER BY line COLLATE "C";
SQL
}

status=0
for set in uni schemas; do
    out="$WORK/$set"
    mkdir -p "$out/table" "$out/schema"
    fixture "$set" | run_sql -d "$DATABASE" > /dev/null
    case "$set" in
    uni) schemas="uni" ;;
    schemas) schemas="$COMPOSED,$DECOMPOSED" ;;
    esac
    echo "== $set"
    if ! "$WORK/.build/debug/Probe" "$HOST" "$PORT" "$USER_NAME" "$DATABASE" "$schemas" "$out"; then
        exit 2
    fi
    if diff <(grep -v '^-- Generated: ' "$out/sql-table.sql") <(grep -v '^-- Generated: ' "$out/sql-schema.sql") \
        > "$out/sql.diff"; then
        echo "same dump either way: $(wc -l < "$out/sql-schema.sql" | tr -d ' ') lines"
    else
        echo "BUG: the dumps differ"
        head -30 "$out/sql.diff"
        status=1
    fi
    if diff <(grep -v 'generated' "$out/table/dictionary.md") <(grep -v 'generated' "$out/schema/dictionary.md") \
        > "$out/dd.diff"; then
        echo "same dictionary either way: $(wc -l < "$out/schema/dictionary.md" | tr -d ' ') lines"
    else
        echo "BUG: the dictionaries differ"
        head -30 "$out/dd.diff"
        status=1
    fi
    snapshot "$out/before.txt"
    { echo 'SET client_min_messages = warning;'; drop_schemas "$set"; } | run_sql -d "$DATABASE" > /dev/null
    search_path=public
    [[ $set == uni ]] && search_path=uni
    if PGOPTIONS="-c search_path=$search_path -c client_min_messages=warning" run_sql -d "$DATABASE" \
        -f "$out/sql-schema.sql" > "$out/restore.log" 2>&1; then
        snapshot "$out/after.txt"
        if diff "$out/before.txt" "$out/after.txt" > "$out/restore.diff"; then
            echo "the dump restores what was dumped: $(wc -l < "$out/before.txt" | tr -d ' ') catalog lines"
        else
            echo "BUG: the restored schemas differ from the dumped ones"
            head -30 "$out/restore.diff"
            status=1
        fi
    else
        echo "BUG: the dump does not restore"
        tail -3 "$out/restore.log"
        status=1
    fi
done

[[ $status -eq 0 ]] && echo "OK"
exit $status
