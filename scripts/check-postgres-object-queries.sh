#!/usr/bin/env bash
#
# Run the PostgreSQL routine and trigger catalog queries against a live server and check the
# answers, so a hand-written query cannot drift from what the server actually returns.
#
# The queries in Plugins/PostgreSQLDriverPlugin/PostgreSQLObjectQueries.swift are hand-written and
# nothing at runtime checks them. Three of the things they get right are only visible with real
# overloads in the catalog:
#   - one row per routine, not one per pairing of a name with itself
#   - a distinct oid per overload, which is what makes the DDL fetch address the right one
#   - aggregates excluded, because pg_get_functiondef raises on them and would fail the whole list
#
# Usage:
#   scripts/check-postgres-object-queries.sh [database] [schema]
#
# Defaults to the `postgres` database and a scratch schema it creates and drops.

set -euo pipefail

DATABASE="${1:-postgres}"
SCHEMA="${2:-tablepro_object_query_check}"

if ! command -v psql > /dev/null 2>&1; then
    echo "psql not found" >&2
    exit 2
fi

if ! psql -d "$DATABASE" -Atc 'SELECT 1' > /dev/null 2>&1; then
    echo "cannot connect to database '$DATABASE'" >&2
    exit 2
fi

cleanup() {
    psql -d "$DATABASE" -q -c "DROP SCHEMA IF EXISTS $SCHEMA CASCADE" > /dev/null 2>&1 || true
}
trap cleanup EXIT

failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

psql -d "$DATABASE" -q -v ON_ERROR_STOP=1 > /dev/null << SQL
DROP SCHEMA IF EXISTS $SCHEMA CASCADE;
CREATE SCHEMA $SCHEMA;
CREATE FUNCTION $SCHEMA.transform(a integer) RETURNS integer LANGUAGE sql IMMUTABLE AS \$\$ SELECT \$1 \$\$;
CREATE FUNCTION $SCHEMA.transform(a text) RETURNS integer LANGUAGE sql AS \$\$ SELECT 2 \$\$;
CREATE FUNCTION $SCHEMA.transform(a date, b int) RETURNS integer LANGUAGE sql AS \$\$ SELECT 3 \$\$;
CREATE PROCEDURE $SCHEMA.sync_orders() LANGUAGE plpgsql AS \$\$ BEGIN NULL; END \$\$;
CREATE AGGREGATE $SCHEMA.my_sum(int) (SFUNC = int4pl, STYPE = int);
CREATE TABLE $SCHEMA.orders(id int primary key, total numeric);
CREATE TABLE $SCHEMA.customers(id int primary key);
CREATE FUNCTION $SCHEMA.audit_fn() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN RETURN NEW; END \$\$;
CREATE TRIGGER audit BEFORE INSERT OR UPDATE ON $SCHEMA.orders
    FOR EACH ROW WHEN (NEW.total > 0) EXECUTE FUNCTION $SCHEMA.audit_fn();
CREATE TRIGGER audit AFTER DELETE ON $SCHEMA.customers
    FOR EACH STATEMENT EXECUTE FUNCTION $SCHEMA.audit_fn();
SQL

ROUTINE_LIST="
SELECT p.oid::text, p.proname, '(' || pg_catalog.pg_get_function_identity_arguments(p.oid) || ')', p.prokind
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE n.nspname = '$SCHEMA'
  AND p.prokind IN ('f', 'p')
  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
"

rows=$(psql -d "$DATABASE" -Atc "$ROUTINE_LIST" | wc -l | tr -d ' ')
[ "$rows" = "5" ] || fail "routine list returned $rows rows, expected 5 (3 overloads, 1 procedure, 1 trigger function)"

transform_rows=$(psql -d "$DATABASE" -Atc "$ROUTINE_LIST AND p.proname = 'transform'" | wc -l | tr -d ' ')
[ "$transform_rows" = "3" ] || fail "three overloads returned $transform_rows rows, expected 3"

distinct_oids=$(psql -d "$DATABASE" -Atc "SELECT count(DISTINCT p.oid) FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = '$SCHEMA' AND p.proname = 'transform'")
[ "$distinct_oids" = "3" ] || fail "three overloads share $distinct_oids oids, expected 3 distinct"

distinct_args=$(psql -d "$DATABASE" -Atc "SELECT count(DISTINCT pg_catalog.pg_get_function_identity_arguments(p.oid))
    FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = '$SCHEMA' AND p.proname = 'transform'")
[ "$distinct_args" = "3" ] || fail "three overloads share $distinct_args argument signatures, expected 3 distinct"

aggregates=$(psql -d "$DATABASE" -Atc "$ROUTINE_LIST AND p.proname = 'my_sum'" | wc -l | tr -d ' ')
[ "$aggregates" = "0" ] || fail "an aggregate reached the routine list; pg_get_functiondef raises on it"

if psql -d "$DATABASE" -Atc "SELECT pg_catalog.pg_get_functiondef(p.oid) FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = '$SCHEMA' AND p.proname = 'my_sum'" > /dev/null 2>&1; then
    echo "note: pg_get_functiondef no longer raises on an aggregate on this server version"
fi

for oid in $(psql -d "$DATABASE" -Atc "SELECT p.oid FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = '$SCHEMA' AND p.proname = 'transform' ORDER BY p.oid"); do
    args=$(psql -d "$DATABASE" -Atc "SELECT pg_catalog.pg_get_function_identity_arguments($oid)")
    definition=$(psql -d "$DATABASE" -Atc "SELECT pg_catalog.pg_get_functiondef($oid::oid)" | head -1)
    case "$definition" in
        *"($args)"*) ;;
        *) fail "pg_get_functiondef($oid) returned a definition for a different overload: $definition" ;;
    esac
done

TRIGGER_LIST="
SELECT t.tgname, c.relname,
    CASE WHEN (t.tgtype & 64) != 0 THEN 'INSTEAD OF'
         WHEN (t.tgtype & 2)  != 0 THEN 'BEFORE' ELSE 'AFTER' END,
    array_to_string(array_remove(ARRAY[
        CASE WHEN (t.tgtype & 4)  != 0 THEN 'INSERT' END,
        CASE WHEN (t.tgtype & 8)  != 0 THEN 'DELETE' END,
        CASE WHEN (t.tgtype & 16) != 0 THEN 'UPDATE' END,
        CASE WHEN (t.tgtype & 32) != 0 THEN 'TRUNCATE' END], NULL), ' OR '),
    CASE WHEN (t.tgtype & 1) != 0 THEN 'ROW' ELSE 'STATEMENT' END
FROM pg_catalog.pg_trigger t
JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = '$SCHEMA' AND NOT t.tgisinternal
ORDER BY c.relname, t.tgname
"

trigger_rows=$(psql -d "$DATABASE" -Atc "$TRIGGER_LIST")
expected=$'audit|customers|AFTER|DELETE|STATEMENT\naudit|orders|BEFORE|INSERT OR UPDATE|ROW'
if [ "$trigger_rows" != "$expected" ]; then
    fail "trigger list disagreed"
    echo "expected:" >&2
    echo "$expected" >&2
    echo "got:" >&2
    echo "$trigger_rows" >&2
fi

definition=$(psql -d "$DATABASE" -Atc "SELECT pg_catalog.pg_get_triggerdef(t.oid) FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = '$SCHEMA' AND c.relname = 'orders' AND t.tgname = 'audit'")
case "$definition" in
    *"WHEN"*) ;;
    *) fail "pg_get_triggerdef dropped the WHEN clause: $definition" ;;
esac

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi

echo "PostgreSQL object catalog queries agree with $(psql -d "$DATABASE" -Atc 'SHOW server_version')"
