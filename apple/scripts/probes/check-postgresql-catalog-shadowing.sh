#!/usr/bin/env bash
#
# Checks that the PostgreSQL driver's own catalog statements never run a function or operator that another role
# planted in the schema being browsed (CVE-2018-1058's substitution, aimed at the client).
#
# PostgreSQL picks a candidate that takes the call's argument types exactly over a pg_catalog one reached through a
# cast, wherever the two sit on search_path. So a role that owns a schema can create `pg_total_relation_size(oid)`,
# `<>(oid, integer)` or `=(sql_identifier, sql_identifier)` there and have a reader's session run it.
#
# Builds the PostgreSQL plugin with SwiftPM, loads a fixture into a schema owned by an unprivileged role, and reads
# every catalog surface of it through the driver twice: pinned to that schema as the metadata pool pins a connection,
# and with a path that names the schema before pg_catalog, as a database owner's default search_path can. Then
# that role plants lookalikes: one operator for each operator name and pair of catalog types pg_catalog has no exact
# match for, one function for each pg_catalog overload the driver calls with one or two argument types swapped, and
# array_agg and max over each type. Each lookalike counts its calls in a sequence, which survives a rollback. The
# planted reads must print exactly what the clean ones did and nothing may count.
#
# Also checks PostGIS when the server has it: an enum named geometry with its own st_asewkt in the schema must not
# take the spatial rendering.
#
# Usage: scripts/probes/check-postgresql-catalog-shadowing.sh [host] [port]   (PostgreSQL 11 or later)
# Environment: PGUSER (default postgres, a superuser: the reader whose privileges are at stake), PGPASSWORD, PSQL,
# TP_SHADOW_APPLE_ROOT (the apple/ folder whose driver to build, default this checkout's).
# Prints OK, or BUG with the lookalikes that ran and the lines that changed.
set -euo pipefail

ROOT="${TP_SHADOW_APPLE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PROBES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:-127.0.0.1}"
PORT="${2:-5432}"
READER="${PGUSER:-postgres}"
OWNER="tablepro_shadow_owner"
OWNER_PASSWORD="tablepro_shadow_owner"
DATABASE="tablepro_shadow_check"
SCHEMA="evil"
LOG_SCHEMA="shadow_log"
PSQL="${PSQL:-$(command -v psql || true)}"
[[ -n "$PSQL" ]] || { echo "FAIL: psql not found; set PSQL" >&2; exit 2; }

WORK="$(mktemp -d)"
cleanup() {
    "$PSQL" -X -q -h "$HOST" -p "$PORT" -U "$READER" -d postgres \
        -c "DROP DATABASE IF EXISTS $DATABASE" -c "DROP ROLE IF EXISTS $OWNER" > /dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

as_reader() { "$PSQL" -X -q -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$READER" "$@"; }
as_owner() { PGPASSWORD="$OWNER_PASSWORD" "$PSQL" -X -q -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$OWNER" -d "$DATABASE"; }

as_reader -d postgres -Atc 'SELECT 1' > /dev/null || { echo "FAIL: cannot connect to $HOST:$PORT as $READER" >&2; exit 2; }
echo "PostgreSQL $(as_reader -d postgres -Atc 'SHOW server_version') at $HOST:$PORT, driver from $ROOT"

mkdir -p "$WORK/Sources/Probe"
for source in "$ROOT"/Plugins/PostgreSQLDriverPlugin/*.swift; do
    ln -s "$source" "$WORK/Sources/Probe/$(basename "$source")"
done
for shared in PluginConnectTimeout PluginQueryTimeout PluginURLSessionTaskBox; do
    ln -s "$ROOT/Plugins/Shared/$shared.swift" "$WORK/Sources/Probe/$shared.swift"
done
ln -s "$PROBES/postgresql-shadowing-probe.swift" "$WORK/Sources/Probe/Probe.swift"
ln -s "$ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ" "$WORK/CModule"
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ShadowingProbe", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .systemLibrary(name: "CLibPQ", path: "CModule"),
        .executableTarget(name: "Probe", dependencies: [
            "CLibPQ",
            .product(name: "TableProPluginKit", package: "TableProCore"),
            .product(name: "TableProCoreTypes", package: "TableProCore"),
            .product(name: "TableProKerberos", package: "TableProCore"),
            .product(name: "TableProPostgreSQLCore", package: "TableProCore"),
            .product(name: "TableProSQLVocabulary", package: "TableProCore"),
            .product(name: "TableProLogRedaction", package: "TableProCore")
        ], swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("MemberImportVisibility"),
            .unsafeFlags(["-Xcc", "-I$ROOT/Plugins/PostgreSQLDriverPlugin/CLibPQ/include"])],
        linkerSettings: [.unsafeFlags([
            "-L$ROOT/Libs", "-L$ROOT/Libs/dylibs", "-Xlinker", "-rpath", "-Xlinker", "$ROOT/Libs/dylibs",
            "$ROOT/Libs/libpq.a", "$ROOT/Libs/libpgcommon.a", "$ROOT/Libs/libpgport.a",
            "-lssl.3", "-lcrypto.3", "-lz", "-framework", "GSS"
        ])])
    ])
MANIFEST
echo "Building the driver..."
if ! (cd "$WORK" && swift build --jobs 2 > "$WORK/build.log" 2>&1); then
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 2
fi

as_reader -d postgres -c "DROP DATABASE IF EXISTS $DATABASE" -c "DROP ROLE IF EXISTS $OWNER" > /dev/null
as_reader -d postgres -c "CREATE ROLE $OWNER LOGIN PASSWORD '$OWNER_PASSWORD'" -c "CREATE DATABASE $DATABASE" > /dev/null
as_reader -d "$DATABASE" -c "CREATE SCHEMA $SCHEMA AUTHORIZATION $OWNER" \
    -c "CREATE SCHEMA $LOG_SCHEMA AUTHORIZATION $OWNER" > /dev/null
HAS_POSTGIS="$(as_reader -d "$DATABASE" -Atc "SELECT count(*) FROM pg_available_extensions WHERE name = 'postgis'")"
if [[ "$HAS_POSTGIS" == "1" ]]; then
    as_reader -d "$DATABASE" -c "CREATE EXTENSION postgis" > /dev/null
    REAL_GEOMETRY="public.geometry"
else
    echo "PostGIS is not installed on this server; the spatial check reads a text column instead"
    REAL_GEOMETRY="text"
fi

# The call log exists before the first read, so both reads list the same relations.
as_owner > /dev/null <<SQL
CREATE SEQUENCE $LOG_SCHEMA.hits;
CREATE TABLE $LOG_SCHEMA.calls (signature text);
GRANT INSERT ON $LOG_SCHEMA.calls TO PUBLIC;
GRANT USAGE ON SEQUENCE $LOG_SCHEMA.hits TO PUBLIC;
GRANT USAGE ON SCHEMA $LOG_SCHEMA TO PUBLIC;
CREATE FUNCTION $LOG_SCHEMA.hit(signature text) RETURNS void LANGUAGE plpgsql AS \$\$
BEGIN
    PERFORM pg_catalog.nextval('$LOG_SCHEMA.hits');
    INSERT INTO $LOG_SCHEMA.calls VALUES (signature);
END
\$\$;
CREATE TYPE $SCHEMA.mood AS ENUM ('happy', 'sad');
CREATE DOMAIN $SCHEMA.positive AS integer CHECK (VALUE > 0);
CREATE TYPE $SCHEMA.pair AS (a integer, b text);
CREATE TYPE $SCHEMA.floatrange AS RANGE (subtype = float8);
CREATE TABLE $SCHEMA.customers (id serial PRIMARY KEY, email text UNIQUE, tier $SCHEMA.mood);
CREATE TABLE $SCHEMA.orders (
    id bigserial PRIMARY KEY,
    customer_id integer REFERENCES $SCHEMA.customers (id),
    qty $SCHEMA.positive,
    status $SCHEMA.mood DEFAULT 'happy',
    tags text[],
    note text COLLATE "C",
    total integer GENERATED ALWAYS AS (qty * 2) STORED,
    CONSTRAINT qty_small CHECK (qty < 1000 AND status <> 'sad'::$SCHEMA.mood)
);
COMMENT ON TABLE $SCHEMA.orders IS 'Orders';
COMMENT ON COLUMN $SCHEMA.orders.qty IS 'Quantity';
CREATE INDEX orders_lower_note ON $SCHEMA.orders (lower(note)) WHERE qty > 5;
CREATE FUNCTION $SCHEMA.touch() RETURNS trigger LANGUAGE plpgsql AS \$\$BEGIN RETURN NEW; END\$\$;
CREATE TRIGGER orders_touch BEFORE INSERT OR UPDATE ON $SCHEMA.orders FOR EACH ROW EXECUTE FUNCTION $SCHEMA.touch();
CREATE FUNCTION $SCHEMA.label(m $SCHEMA.mood, n integer DEFAULT 1) RETURNS text LANGUAGE plpgsql
    AS \$\$BEGIN RETURN m::text; END\$\$;
CREATE VIEW $SCHEMA.order_view AS SELECT id, status FROM $SCHEMA.orders;
CREATE MATERIALIZED VIEW $SCHEMA.order_totals AS SELECT status, count(*) AS n FROM $SCHEMA.orders GROUP BY status;
CREATE TABLE $SCHEMA.events (id integer, at date) PARTITION BY RANGE (at);
CREATE TABLE $SCHEMA.events_2026 PARTITION OF $SCHEMA.events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE SEQUENCE $SCHEMA.invoice_seq;
CREATE TYPE $SCHEMA.geometry AS ENUM ('POINT(0 0)');
CREATE TABLE $SCHEMA.places (id integer, location $SCHEMA.geometry, real_location $REAL_GEOMETRY);
INSERT INTO $SCHEMA.customers (email, tier) VALUES ('a@example.com', 'happy');
INSERT INTO $SCHEMA.orders (customer_id, qty, note, tags) VALUES (1, 7, 'Hello', '{a,b}');
INSERT INTO $SCHEMA.places VALUES (1, 'POINT(0 0)', 'SRID=4326;POINT(1 2)');
SQL

read_schema() {
    "$WORK/.build/debug/Probe" "$HOST" "$PORT" "$READER" "$DATABASE" "$SCHEMA" pinned > "$1-pinned.txt"
    "$WORK/.build/debug/Probe" "$HOST" "$PORT" "$READER" "$DATABASE" "$SCHEMA" explicit > "$1-explicit.txt"
}

echo "Reading the clean schema..."
read_schema "$WORK/clean"

echo "Planting lookalikes..."
as_owner > "$WORK/plant.log" <<SQL
CREATE FUNCTION $SCHEMA.st_asewkt($SCHEMA.geometry) RETURNS text LANGUAGE plpgsql AS \$\$
BEGIN
    PERFORM $LOG_SCHEMA.hit('st_asewkt($SCHEMA.geometry)');
    RETURN \$1::text;
END
\$\$;

CREATE PROCEDURE $LOG_SCHEMA.plant() LANGUAGE plpgsql AS \$plant\$
DECLARE
    operators text[] := ARRAY['=', '<>', '<', '>', '<=', '>=', '&', '|', '~~', '~~*', '!~~', '!~~*', '~', '~*', '!~',
                              '||', '+', '-', '*', '/', '@>', '<@', '&&'];
    types regtype[] := ARRAY['oid', 'name', 'text', 'smallint', 'integer', 'bigint', '"char"', 'boolean', 'regclass',
                             'regtype', 'regproc', 'regprocedure', 'regnamespace', 'regrole', 'oidvector', 'int2vector',
                             'oid[]', 'smallint[]', 'text[]', 'name[]', 'aclitem[]', '"char"[]', 'real',
                             'double precision', 'numeric', 'character varying', 'character', 'xid',
                             'timestamp with time zone', 'interval', 'information_schema.sql_identifier',
                             'information_schema.cardinal_number', 'information_schema.character_data',
                             'information_schema.yes_or_no']::regtype[];
    swaps regtype[] := ARRAY['oid', 'name', 'text', 'smallint', 'integer', 'bigint', '"char"', 'regclass',
                             'character varying', 'information_schema.sql_identifier']::regtype[];
    functions text[] := ARRAY['pg_total_relation_size', 'pg_table_size', 'pg_indexes_size', 'pg_relation_size',
                              'obj_description', 'col_description', 'quote_ident', 'quote_literal', 'format_type',
                              'pg_get_expr', 'pg_get_constraintdef', 'pg_get_triggerdef', 'pg_get_indexdef',
                              'pg_get_viewdef', 'pg_get_functiondef', 'pg_get_function_identity_arguments',
                              'pg_get_function_result', 'pg_get_serial_sequence', 'pg_get_userbyid', 'concat_ws',
                              'has_schema_privilege', 'has_table_privilege', 'has_sequence_privilege',
                              'has_any_column_privilege', 'has_column_privilege', 'has_database_privilege',
                              'pg_has_role', 'current_setting', 'pg_size_pretty', 'pg_database_size', 'setval',
                              'pg_type_is_visible', 'pg_is_other_temp_schema', 'pg_sequence_parameters',
                              'pg_get_function_arg_default', 'array_lower', 'replace', 'lower', 'left', 'length'];
    op text; l regtype; r regtype; t regtype; u regtype;
    f record; args regtype[]; trial regtype[]; i int; j int; n int := 0;
    returns text;
BEGIN
    FOREACH op IN ARRAY operators LOOP
        FOREACH l IN ARRAY types LOOP
            FOREACH r IN ARRAY types LOOP
                CONTINUE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_operator o
                                      WHERE o.oprname = op AND o.oprleft = l AND o.oprright = r);
                n := n + 1;
                EXECUTE format('CREATE FUNCTION $SCHEMA.%I(%s, %s) RETURNS boolean LANGUAGE plpgsql AS %L',
                    'op_' || n, l, r,
                    format('BEGIN PERFORM $LOG_SCHEMA.hit(%L); RETURN NULL; END', op || '(' || l || ', ' || r || ')'));
                EXECUTE format('CREATE OPERATOR $SCHEMA.%s (LEFTARG = %s, RIGHTARG = %s, FUNCTION = $SCHEMA.%I)',
                    op, l, r, 'op_' || n);
                -- Thousands of objects in one transaction run out of lock slots.
                IF n % 500 = 0 THEN COMMIT; END IF;
            END LOOP;
        END LOOP;
    END LOOP;

    FOR f IN
        SELECT p.proname,
               ARRAY(SELECT a.t::pg_catalog.regtype
                     FROM pg_catalog.unnest(p.proargtypes::pg_catalog.oid[]) WITH ORDINALITY AS a(t, n)
                     ORDER BY a.n) AS args,
               p.prorettype::pg_catalog.regtype AS rettype,
               p.proretset, rt.typtype
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_type rt ON rt.oid = p.prorettype
        WHERE p.pronamespace = 'pg_catalog'::pg_catalog.regnamespace
          AND p.proname = ANY (functions)
          AND p.prokind = 'f'
          AND p.pronargs BETWEEN 1 AND 3
    LOOP
        returns := CASE WHEN f.typtype = 'p' THEN 'text' ELSE f.rettype::text END;
        FOR i IN 1 .. pg_catalog.array_length(f.args, 1) LOOP
            FOREACH t IN ARRAY swaps LOOP
                FOR j IN i .. pg_catalog.array_length(f.args, 1) LOOP
                    FOREACH u IN ARRAY CASE WHEN j = i THEN ARRAY[t] ELSE swaps END LOOP
                        trial := f.args;
                        trial[i] := t;
                        trial[j] := u;
                        CONTINUE WHEN EXISTS (
                            SELECT 1 FROM pg_catalog.pg_proc q
                            WHERE q.proname = f.proname
                              AND pg_catalog.array_to_string(q.proargtypes::pg_catalog.oid[], ' ')
                                  = pg_catalog.array_to_string(trial::pg_catalog.oid[], ' '));
                        BEGIN
                            EXECUTE format('CREATE FUNCTION $SCHEMA.%I(%s) RETURNS %s%s LANGUAGE plpgsql AS %L',
                                f.proname, pg_catalog.array_to_string(trial, ', '),
                                CASE WHEN f.proretset THEN 'SETOF ' ELSE '' END, returns,
                                format('BEGIN PERFORM $LOG_SCHEMA.hit(%L); RETURN%s; END',
                                    f.proname || '(' || pg_catalog.array_to_string(trial, ', ') || ')',
                                    CASE WHEN f.proretset THEN '' ELSE ' NULL' END));
                        EXCEPTION WHEN OTHERS THEN
                            NULL;
                        END;
                        n := n + 1;
                        IF n % 500 = 0 THEN COMMIT; END IF;
                    END LOOP;
                END LOOP;
            END LOOP;
        END LOOP;
    END LOOP;

    FOREACH t IN ARRAY types LOOP
        n := n + 1;
        EXECUTE format('CREATE FUNCTION $SCHEMA.%I(text, %s) RETURNS text LANGUAGE plpgsql AS %L',
            'agg_' || n, t, format('BEGIN PERFORM $LOG_SCHEMA.hit(%L); RETURN NULL; END', 'aggregate(' || t || ')'));
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc q
                       WHERE q.proname = 'array_agg' AND q.pronargs = 1 AND q.proargtypes[0] = t) THEN
            EXECUTE format('CREATE AGGREGATE $SCHEMA.array_agg(%s) (SFUNC = $SCHEMA.%I, STYPE = text)', t, 'agg_' || n);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc q
                       WHERE q.proname = 'max' AND q.pronargs = 1 AND q.proargtypes[0] = t) THEN
            EXECUTE format('CREATE AGGREGATE $SCHEMA.max(%s) (SFUNC = $SCHEMA.%I, STYPE = text)', t, 'agg_' || n);
        END IF;
    END LOOP;
END
\$plant\$;
CALL $LOG_SCHEMA.plant();
SELECT pg_catalog.count(*) || ' lookalike functions and operators' FROM pg_catalog.pg_proc
WHERE pronamespace = '$SCHEMA'::pg_catalog.regnamespace;
SQL
grep -i "lookalike" "$WORK/plant.log" | tr -d ' ' | sed 's/lookalike/ lookalike /' || true

echo "Reading the planted schema..."
read_schema "$WORK/planted"

HITS="$(as_reader -d "$DATABASE" -Atc "SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM $LOG_SCHEMA.hits")"
CALLS="$(as_reader -d "$DATABASE" -Atc "SELECT signature, pg_catalog.count(*) FROM $LOG_SCHEMA.calls GROUP BY 1 ORDER BY 1")"
CHANGED="$(diff "$WORK/clean-pinned.txt" "$WORK/planted-pinned.txt"; diff "$WORK/clean-explicit.txt" "$WORK/planted-explicit.txt")" || true

grep -h '^error|' "$WORK/clean-pinned.txt" "$WORK/clean-explicit.txt" | sed 's/^/clean read failed: /' || true
echo "Lookalike calls: $HITS"
[[ -z "$CALLS" ]] || echo "$CALLS" | sed 's/^/  ran: /'
[[ -z "$CHANGED" ]] || { echo "Lines that changed:"; echo "$CHANGED" | head -60; }
if [[ "$HITS" == "0" && -z "$CHANGED" ]] && ! grep -q '^error|' "$WORK/clean-pinned.txt" "$WORK/clean-explicit.txt"; then
    echo "OK"
else
    echo "BUG"
    exit 1
fi
