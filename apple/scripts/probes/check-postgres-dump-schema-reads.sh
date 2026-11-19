#!/usr/bin/env bash
#
# Checks that a PostgreSQL SQL dump is the same whether the export reads each table's index, comment, sequence and
# enum DDL alone or takes the schema-wide reads the driver declares in `exportBulkReads`.
#
# Builds this checkout's PostgreSQL driver and SQL export plugin with SwiftPM, loads a fixture with partial,
# expression, INCLUDE and partitioned indexes, comments on tables, columns, views and materialized views, owned and
# free sequences (one shared by two tables' defaults), quoted names, enum types, and a table and a view whose names
# differ only in Unicode form, then dumps it both ways and diffs the files. Also restores the dump of a table with two columns of one enum, which wrote each label twice before.
#
# Usage: scripts/probes/check-postgres-dump-schema-reads.sh [host] [port]
# Environment: PGUSER (default the current user), PGPASSWORD, PSQL, PROBE_APPLE_ROOT (the apple/ folder to build,
# default this checkout's), PROBE_DATABASE (default tablepro_dump_schema_reads_check), which it creates and drops.
# Prints OK, or BUG with the lines that differ. Exits 0, 1 on a difference, 2 when it cannot run.
set -euo pipefail

ROOT="${PROBE_APPLE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PROBES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
USER_NAME="${PGUSER:-$(id -un)}"
DATABASE="${PROBE_DATABASE:-tablepro_dump_schema_reads_check}"
PSQL="${PSQL:-$(command -v psql || true)}"
[[ -n "$PSQL" ]] || { echo "FAIL: psql not found; set PSQL" >&2; exit 2; }

WORK="$(mktemp -d)"
cleanup() {
    "$PSQL" -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" \
        > /dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

run_sql() { "$PSQL" -X -q -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$USER_NAME" "$@"; }

run_sql -d postgres -Atc 'SELECT 1' > /dev/null || { echo "FAIL: cannot connect to $HOST:$PORT" >&2; exit 2; }
echo "PostgreSQL $(run_sql -d postgres -Atc 'SHOW server_version') at $HOST:$PORT, plugins from $ROOT"

mkdir -p "$WORK/Sources/ProbeDriver" "$WORK/Sources/ProbeSQLExport" "$WORK/Sources/Probe"
for source in "$ROOT"/Plugins/PostgreSQLDriverPlugin/*.swift; do
    ln -s "$source" "$WORK/Sources/ProbeDriver/$(basename "$source")"
done
for shared in PluginConnectTimeout PluginQueryTimeout PluginURLSessionTaskBox PluginRedirectRefusingDelegate; do
    ln -s "$ROOT/Plugins/Shared/$shared.swift" "$WORK/Sources/ProbeDriver/$shared.swift"
done
for source in "$ROOT"/Plugins/SQLExportPlugin/*.swift; do
    ln -s "$source" "$WORK/Sources/ProbeSQLExport/$(basename "$source")"
done
for shared in PluginExportOutputBuffer PluginHexText; do
    ln -s "$ROOT/Plugins/Shared/$shared.swift" "$WORK/Sources/ProbeSQLExport/$shared.swift"
done
ln -s "$PROBES/postgres-dump-schema-reads-probe.swift" "$WORK/Sources/Probe/Probe.swift"
ln -s "$ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ" "$WORK/CModule"
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
    name: "DumpSchemaReadsProbe", platforms: [.macOS(.v14)],
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
        .executableTarget(name: "Probe", dependencies: ["ProbeDriver", "ProbeSQLExport", core("TableProPluginKit")],
            path: "Sources/Probe", swiftSettings: settings,
            linkerSettings: [.unsafeFlags([
                "-L$ROOT/Libs", "-L$ROOT/Libs/dylibs", "-Xlinker", "-rpath", "-Xlinker", "$ROOT/Libs/dylibs",
                "$ROOT/Libs/libpq.a", "$ROOT/Libs/libpgcommon.a", "$ROOT/Libs/libpgport.a",
                "-lssl.3", "-lcrypto.3", "-lz", "-framework", "GSS"
            ])])
    ])
MANIFEST
echo "Building the driver and the SQL export..."
if ! (cd "$WORK" && swift build --jobs 2 > "$WORK/build.log" 2>&1); then
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 2
fi

run_sql -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" -c "CREATE DATABASE $DATABASE" > /dev/null
run_sql -d "$DATABASE" > /dev/null <<'SQL'
SET client_min_messages = warning;
CREATE SCHEMA shop;
SET search_path = shop;
CREATE TYPE order_status AS ENUM ('new', 'paid', 'shipped', 'it''s done');
CREATE TYPE mood AS ENUM ('happy', 'sad');
CREATE TYPE "Odd Type" AS ENUM ('a b', 'c"d');
CREATE SEQUENCE shared_seq START 100 INCREMENT 5;
SELECT setval('shared_seq', 120);
CREATE SEQUENCE lonely_seq;
CREATE TABLE customers (id serial PRIMARY KEY, email text NOT NULL, name text, mood mood,
    code integer DEFAULT nextval('shared_seq'));
COMMENT ON TABLE customers IS 'People who buy';
COMMENT ON COLUMN customers.email IS 'Login, it''s unique';
CREATE UNIQUE INDEX customers_email_lower ON customers (lower(email));
CREATE INDEX customers_name_partial ON customers (name) WHERE name IS NOT NULL;
CREATE INDEX customers_mood_idx ON customers (mood, id DESC);
CREATE TABLE orders (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id integer REFERENCES customers (id) ON DELETE CASCADE,
    status order_status NOT NULL DEFAULT 'new', ref integer DEFAULT nextval('shared_seq'),
    total numeric(10, 2), note text);
COMMENT ON COLUMN orders.status IS 'Lifecycle';
CREATE INDEX orders_open ON orders (customer_id) INCLUDE (total) WHERE status <> 'shipped';
CREATE INDEX orders_lower_note ON orders (lower(note) text_pattern_ops);
CREATE TABLE "Mixed Case" ("Id" serial PRIMARY KEY, "Weird ""Col""" "Odd Type", val text);
COMMENT ON TABLE "Mixed Case" IS 'Quoted';
COMMENT ON COLUMN "Mixed Case"."Weird ""Col""" IS 'col comment';
CREATE INDEX "Mixed Case idx" ON "Mixed Case" (val) WHERE val LIKE 'x%';
CREATE TABLE events (id integer, at date NOT NULL, kind mood) PARTITION BY RANGE (at);
CREATE TABLE events_2026 PARTITION OF events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE INDEX events_at_idx ON events (at);
COMMENT ON TABLE events IS 'Partitioned';
CREATE TABLE plain (a integer, b text);
INSERT INTO customers (email, name, mood) VALUES ('a@x', 'A', 'happy'), ('b@x', NULL, 'sad');
INSERT INTO orders (customer_id, status, total, note) VALUES (1, 'paid', 10.5, 'first'), (2, 'it''s done', 3, NULL);
INSERT INTO "Mixed Case" ("Weird ""Col""", val) VALUES ('c"d', 'xy');
INSERT INTO events VALUES (1, '2026-05-01', 'happy');
CREATE VIEW open_orders AS SELECT id, customer_id FROM orders WHERE status <> 'shipped';
COMMENT ON VIEW open_orders IS 'Orders still moving';
COMMENT ON COLUMN open_orders.id IS 'view col';
CREATE MATERIALIZED VIEW order_totals AS SELECT customer_id, sum(total) AS total FROM orders GROUP BY customer_id;
CREATE UNIQUE INDEX order_totals_customer ON order_totals (customer_id);
COMMENT ON MATERIALIZED VIEW order_totals IS 'Totals';
CREATE SCHEMA solo;
CREATE TYPE solo.tone AS ENUM ('low', 'high');
CREATE TABLE solo.only_one (id serial PRIMARY KEY, tone solo.tone, label text);
COMMENT ON TABLE solo.only_one IS 'Alone';
CREATE INDEX only_one_label ON solo.only_one (label) WHERE label <> '';
CREATE SCHEMA dup;
CREATE TYPE dup.mood AS ENUM ('happy', 'sad');
CREATE TABLE dup.pair (a dup.mood, b dup.mood);
CREATE TABLE dup.single (c dup.mood);
INSERT INTO dup.pair VALUES ('happy', 'sad');
CREATE SCHEMA uni;
CREATE TABLE uni."café" (id integer, note text);
COMMENT ON TABLE uni."café" IS 'composed';
CREATE INDEX cafe_note ON uni."café" (note) WHERE note IS NOT NULL;
CREATE VIEW uni.U&"cafe\0301" AS SELECT 1 AS id;
COMMENT ON VIEW uni.U&"cafe\0301" IS 'decomposed';
CREATE TABLE uni.plain (id integer);
SQL

status=0
for schemas in shop shop,solo dup uni; do
    out="$WORK/${schemas//,/-}"
    mkdir -p "$out"
    echo "== $schemas"
    if ! "$WORK/.build/debug/Probe" "$HOST" "$PORT" "$USER_NAME" "$DATABASE" "$schemas" "$out"; then
        exit 2
    fi
    if diff <(grep -v '^-- Generated: ' "$out/table-reads.sql") <(grep -v '^-- Generated: ' "$out/schema-reads.sql") \
        > "$out/diff.txt"; then
        echo "same dump: $(wc -l < "$out/schema-reads.sql" | tr -d ' ') lines"
    else
        echo "BUG: the dumps differ"
        head -40 "$out/diff.txt"
        status=1
    fi
done

run_sql -d "$DATABASE" -c "DROP SCHEMA dup CASCADE" -c "CREATE SCHEMA dup" > /dev/null 2>&1
if PGOPTIONS="-c search_path=dup -c client_min_messages=warning" run_sql -d "$DATABASE" \
    -f "$WORK/dup/schema-reads.sql" > "$WORK/restore.log" 2>&1; then
    echo "two columns of one enum: the dump restores"
else
    echo "BUG: the dump of two columns of one enum does not restore"
    tail -3 "$WORK/restore.log"
    status=1
fi

[[ $status -eq 0 ]] && echo "OK"
exit $status
