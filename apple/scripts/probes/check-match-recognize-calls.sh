#!/usr/bin/env bash
#
# Check that MATCH_RECOGNIZE's navigation calls never reach a user function of the same name, which
# Packages/TableProCore/Sources/TableProSQLGrammar/SQLReadOnlyFunctionCalls.swift (RowPatternClauses) and
# SQLBareNameCalls+Parser.swift (the row pattern clause) rely on, and that the same names outside the clause do.
#
# Usage:
#   scripts/probes/check-match-recognize-calls.sh oracle <container>   # gvenzl/oracle-free:23-slim-faststart, APP_USER probe
#   scripts/probes/check-match-recognize-calls.sh dameng <container>   # a DM8 image, SYSDBA password in DM8_PASSWORD
#
# Creates functions PREV, NEXT, FIRST, LAST, CLASSIFIER, MATCH_NUMBER, RUNNING, FINAL and WIPE, each writing a row,
# and tables ORDERS and AUDIT_LOG. Each line prints the query and `calls` (a user function ran), `runs` (none ran)
# or `error` (the server refused the query); compare with SQLReadOnlyFunctionCallsTests and SQLBareNameCallsTests.

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

{
    echo "CREATE TABLE orders (id NUMBER, purge NUMBER);"
    echo "INSERT INTO orders VALUES (1, 100);"
    echo "INSERT INTO orders VALUES (2, 50);"
    echo "INSERT INTO orders VALUES (3, 80);"
    echo "CREATE TABLE audit_log (n NUMBER);"
    echo "COMMIT;"
    for name in prev next first last; do
        printf 'CREATE OR REPLACE FUNCTION %s(v NUMBER) RETURN NUMBER IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO audit_log VALUES (1); COMMIT; RETURN v; END;\n/\n' "$name"
    done
    for name in classifier match_number running final wipe; do
        printf 'CREATE OR REPLACE FUNCTION %s RETURN NUMBER IS PRAGMA AUTONOMOUS_TRANSACTION; BEGIN INSERT INTO audit_log VALUES (2); COMMIT; RETURN 7; END;\n/\n' "$name"
    done
    echo "EXIT"
} | run_sql > /dev/null

MR="SELECT * FROM orders MATCH_RECOGNIZE (ORDER BY id"

while IFS= read -r query; do
    out="$(printf 'DELETE FROM audit_log;\nCOMMIT;\n%s\nSELECT '"'"'audit='"'"' || COUNT(*) FROM audit_log;\nEXIT\n' "$query" | run_sql 2>&1)"
    if printf '%s' "$out" | grep -qE 'ORA-|\[-[0-9]+\]'; then
        verdict=error
    elif printf '%s' "$out" | grep -q 'audit=0'; then
        verdict=runs
    else
        verdict=calls
    fi
    printf '%-6s %s\n' "$verdict" "$query"
done <<QUERIES
SELECT prev(1) FROM dual;
SELECT first(1) FROM dual;
SELECT classifier() FROM dual;
SELECT match_number() FROM dual;
SELECT running FROM dual;
$MR MEASURES PREV(x.purge) AS p ALL ROWS PER MATCH PATTERN (x+) DEFINE x AS PREV(x.purge) IS NULL OR x.purge < PREV(x.purge));
$MR MEASURES NEXT(x.purge) AS n ONE ROW PER MATCH PATTERN (x) DEFINE x AS NEXT(x.purge) IS NOT NULL);
$MR MEASURES FIRST(x.purge) AS f, LAST(x.purge) AS l ONE ROW PER MATCH PATTERN (x+) DEFINE x AS FIRST(x.purge) > 0);
$MR MEASURES CLASSIFIER() AS c, MATCH_NUMBER() AS m ALL ROWS PER MATCH PATTERN (x) DEFINE x AS 1 = 1);
$MR MEASURES FINAL LAST(x.purge) AS l, RUNNING COUNT(*) AS c ALL ROWS PER MATCH PATTERN (x+) DEFINE x AS 1 = 1);
$MR MEASURES RUNNING LAST(x.purge) AS l ALL ROWS PER MATCH PATTERN (x+) DEFINE x AS RUNNING COUNT(*) < 9);
$MR MEASURES x.id AS wipe ONE ROW PER MATCH PATTERN (x) DEFINE x AS 1 = 1);
$MR MEASURES wipe AS w ONE ROW PER MATCH PATTERN (x) DEFINE x AS 1 = 1);
$MR MEASURES wipe() AS w ONE ROW PER MATCH PATTERN (x) DEFINE x AS 1 = 1);
$MR MEASURES x.id AS i ONE ROW PER MATCH PATTERN (x) DEFINE x AS wipe = 7);
$MR MEASURES x.id AS i ONE ROW PER MATCH PATTERN (PERMUTE(x, y)) DEFINE x AS x.id = 1, y AS y.id = 2);
$MR MEASURES x.id AS i ONE ROW PER MATCH AFTER MATCH SKIP TO LAST y PATTERN (x y) DEFINE x AS 1 = 1, y AS 1 = 1);
$MR MEASURES x.id AS i ONE ROW PER MATCH PATTERN (x) DEFINE x AS x.purge > (SELECT prev(1) FROM dual));
$MR MEASURES x.id AS i ALL ROWS PER MATCH PATTERN (^ x {- y -} z* $) DEFINE x AS PREV(x.purge, 1) IS NULL, y AS ABS(PREV(y.purge)) > 0, z AS 1 = 1);
SELECT * FROM orders MATCH_RECOGNIZE (PARTITION BY prev(purge) ORDER BY id MEASURES x.id AS i ONE ROW PER MATCH PATTERN (x) DEFINE x AS 1 = 1);
$MR MEASURES x.id AS subset, wipe AS w ONE ROW PER MATCH PATTERN (x) DEFINE x AS 1 = 1);
$MR MEASURES x.id AS define, wipe AS w ONE ROW PER MATCH PATTERN (x) DEFINE x AS 1 = 1);
$MR MEASURES x.id AS i ONE ROW PER MATCH PATTERN (x) DEFINE x AS x.purge > ((SELECT 1 FROM dual WHERE 1 = 0) UNION ALL SELECT prev(1) FROM dual));
$MR MEASURES x.id AS i ONE ROW PER MATCH PATTERN (x) DEFINE x AS EXISTS ((SELECT 1 FROM dual WHERE 1 = 0) UNION ALL SELECT prev(1) FROM dual));
SELECT * FROM (SELECT id, purge, 1 AS subset FROM orders) MATCH_RECOGNIZE (ORDER BY id MEASURES x.subset + wipe AS m ONE ROW PER MATCH PATTERN (x) DEFINE x AS 1 = 1);
QUERIES
