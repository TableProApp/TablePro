#!/usr/bin/env bash
#
# Checks the server fact Read-Only Safe Mode rests on for the PostgreSQL family: a read the driver runs the way it runs
# one at Read-Only (`START TRANSACTION READ ONLY; SELECT 1`, the statement, `ROLLBACK`) cannot write through a function
# it calls. A SQL function that deletes rows, `nextval`, and `set_config` at session level are each sent that way; the
# delete and the sequence must be refused with SQLSTATE 25006 and leave the data as it was, and the setting must be
# gone after the ROLLBACK. The same delete sent without the wrap must write, so the probe proves it can see a write.
#
# Usage: scripts/probes/check-postgresql-read-only-functions.sh [psql connection arguments…]
#        scripts/probes/check-postgresql-read-only-functions.sh -h 127.0.0.1 -p 5432 -U postgres -d postgres
# The login needs CREATE on the database: the probe makes and drops its own schema.
# Prints OK, or BUG with what the server let through. Exits 2 when the server cannot be reached.
set -uo pipefail

PSQL="${PSQL:-$(command -v psql || true)}"
[[ -n "$PSQL" ]] || { echo "FAIL: psql not found; set PSQL" >&2; exit 2; }
SCHEMA="tablepro_read_only_probe_$$"
BEGIN_READ_ONLY="START TRANSACTION READ ONLY; SELECT 1"

run() { "$PSQL" -X -q -At -v VERBOSITY=verbose "$@" 2>&1; }

run "$@" -c 'SELECT 1' > /dev/null || { echo "FAIL: cannot connect" >&2; exit 2; }
cleanup() { run "$@" -c "DROP SCHEMA IF EXISTS $SCHEMA CASCADE" > /dev/null; }
trap 'cleanup "$@"' EXIT

run "$@" -v ON_ERROR_STOP=1 \
    -c "CREATE SCHEMA $SCHEMA" \
    -c "CREATE TABLE $SCHEMA.orders (id integer)" \
    -c "INSERT INTO $SCHEMA.orders SELECT generate_series(1, 5)" \
    -c "CREATE SEQUENCE $SCHEMA.ticket" \
    -c "CREATE FUNCTION $SCHEMA.purge_orders() RETURNS void LANGUAGE sql AS 'DELETE FROM $SCHEMA.orders'" \
    > /dev/null || { echo "FAIL: cannot create the probe schema" >&2; exit 2; }
echo "PostgreSQL $(run "$@" -c 'SHOW server_version')"

failures=()
wrapped() { run "$@" -c "$BEGIN_READ_ONLY" -c "$STATEMENT" -c "ROLLBACK"; }

STATEMENT="SELECT $SCHEMA.purge_orders()"
answer="$(wrapped "$@")"
[[ "$answer" == *25006* ]] || failures+=("purge_orders() was not refused: $answer")
[[ "$(run "$@" -c "SELECT count(*) FROM $SCHEMA.orders")" == 5 ]] || failures+=("purge_orders() deleted rows")

STATEMENT="SELECT nextval('$SCHEMA.ticket')"
answer="$(wrapped "$@")"
[[ "$answer" == *25006* ]] || failures+=("nextval() was not refused: $answer")

answer="$(run "$@" -c "$BEGIN_READ_ONLY" -c "SELECT set_config('application_name', 'probe_leak', false)" \
    -c "ROLLBACK" -c "SHOW application_name")"
[[ "$answer" != *$'\n'probe_leak ]] || failures+=("set_config() outlived the ROLLBACK")

run "$@" -c "SELECT $SCHEMA.purge_orders()" > /dev/null
[[ "$(run "$@" -c "SELECT count(*) FROM $SCHEMA.orders")" == 0 ]] || failures+=("control: the unwrapped purge did not write")

if ((${#failures[@]} == 0)); then
    echo "OK: the read-only transaction refused every write through a function"
    exit 0
fi
printf 'BUG: %s\n' "${failures[@]}"
exit 1
