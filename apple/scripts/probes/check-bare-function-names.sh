#!/usr/bin/env bash
#
# Check the name resolution SQLBareNameCalls hard-codes against a real Oracle and DM8 server.
#
# Oracle and Dameng run a function named without parentheses once the name is not a column of a table in scope.
# Packages/TableProCore/Sources/TableProSQLGrammar/SQLBareNameCalls+Parser.swift reads which tables a name can see
# (correlated subqueries see the outer query, inline views do not, ORDER BY sees select-list aliases) and treats a
# dotted name no table starts as a call. This runs each shape and reports whether the function ran.
#
# Usage:
#   scripts/probes/check-bare-function-names.sh oracle <container>   # gvenzl/oracle-free:23-slim-faststart, APP_USER probe
#   scripts/probes/check-bare-function-names.sh dameng <container>   # a DM8 image, SYSDBA password in DM8_PASSWORD
#
# Creates PURGE, WIPE, package PK, tables ORDERS and AUDIT_LOG in the probe schema. Each line prints the query and
# `calls` or `runs` (the function did not run); compare with SQLBareNameCallsTests.

set -uo pipefail

ENGINE="${1:?oracle or dameng}"
CONTAINER="${2:?container name}"

case "$ENGINE" in
    oracle)
        run_sql() { docker exec -i "$CONTAINER" sqlplus -s probe/probe_pw@FREEPDB1; }
        ;;
    dameng)
        PASSWORD="${DM8_PASSWORD:?set DM8_PASSWORD}"
        run_sql() {
            docker exec -i "$CONTAINER" bash -c "cat > /tmp/tp-probe.sql && cd /home/dmdba/dmdbms/bin \
                && ./disql -S SYSDBA/$PASSWORD@localhost:5236 \\\`/tmp/tp-probe.sql"
        }
        ;;
    *)
        echo "unknown engine: $ENGINE" >&2
        exit 3
        ;;
esac

run_sql > /dev/null <<'SQL'
CREATE TABLE orders (id NUMBER, purge NUMBER);
INSERT INTO orders VALUES (1, 100);
CREATE TABLE audit_log (n NUMBER);
COMMIT;
CREATE OR REPLACE FUNCTION purge RETURN NUMBER IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO audit_log VALUES (1); COMMIT; RETURN 42; END;
/
CREATE OR REPLACE FUNCTION wipe RETURN NUMBER IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO audit_log VALUES (2); COMMIT; RETURN 7; END;
/
CREATE OR REPLACE PACKAGE pk AS FUNCTION f RETURN NUMBER; END;
/
CREATE OR REPLACE PACKAGE BODY pk AS FUNCTION f RETURN NUMBER IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO audit_log VALUES (3); COMMIT; RETURN 3; END; END;
/
EXIT
SQL

while IFS= read -r query; do
    out="$(printf 'DELETE FROM audit_log;\nCOMMIT;\n%s\nSELECT '"'"'audit='"'"' || COUNT(*) FROM audit_log;\nEXIT\n' "$query" | run_sql 2>&1)"
    if printf '%s' "$out" | grep -q 'audit=0'; then verdict=runs; else verdict=calls; fi
    printf '%-6s %s\n' "$verdict" "$query"
done <<'QUERIES'
SELECT purge FROM orders;
SELECT purge FROM dual;
SELECT id FROM orders WHERE EXISTS (SELECT 1 FROM dual WHERE purge = 100);
SELECT * FROM orders, (SELECT purge FROM dual);
SELECT 1 AS wipe FROM dual ORDER BY wipe;
SELECT 1 AS wipe FROM dual WHERE wipe = 7;
SELECT 1 wipe FROM dual GROUP BY wipe;
SELECT pk.f FROM dual;
SELECT pk.f FROM orders pk;
WITH c AS (SELECT 1 wipe FROM dual) SELECT wipe FROM c;
SELECT purge FROM (SELECT * FROM orders);
SELECT "WIPE" FROM dual;
SELECT id, purge FROM orders UNION ALL SELECT 1, purge FROM dual;
SELECT * FROM (VALUES (wipe)) t (a);
SELECT * FROM orders, (VALUES (purge)) v (a);
SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id ALL ROWS PER MATCH PATTERN (x) DEFINE x AS wipe = 7);
SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id ALL ROWS PER MATCH PATTERN (x) DEFINE x AS purge = 100);
QUERIES
