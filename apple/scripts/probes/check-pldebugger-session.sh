#!/usr/bin/env bash
#
# Check the PL/pgSQL debugger's pldbgapi flow against a real PostgreSQL 17 with pldebugger.
#
# The PostgreSQL plugin debugs a routine with two sessions: the target calls pldbg_oid_debug and then the
# routine, raises a PLDBGBREAK notice on entry and blocks; the proxy attaches to the backend number in that
# notice and steps it. The plugin's statements and its reading of the replies (a stop's line is one past the
# source line, a stack line is not, NULL arrives as the text NULL, 08006 means the target left) were measured
# by hand, and pldebugger can change them in a release. This runs the same statements the plugin builds in
# PostgreSQLRoutineDebugProtocol and checks every reply the plugin relies on, including Stop while paused,
# Stop while running, and a target whose proxy disappeared.
#
# Usage:
#   scripts/probes/check-pldebugger-session.sh [--keep]
#
# Needs Docker. Builds tablepro-probe-pldebugger:17 (postgres:17 plus the PGDG postgresql-17-pldebugger
# package) once, and runs a throwaway container without shared_preload_libraries, which is how a server
# a non-superuser connects to usually looks, and with transaction_timeout = 2s, which would end a target
# paused at a breakpoint for longer if the plugin left it on. --keep leaves the container running. Exits non-zero on a
# mismatch, 3 when it cannot run.

set -uo pipefail

IMAGE="tablepro-probe-pldebugger:17"
CONTAINER="${PLDEBUGGER_CHECK_CONTAINER:-tablepro-pldebugger-check-$$}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
PROTOCOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/Plugins/PostgreSQLDriverPlugin/PostgreSQLRoutineDebugProtocol.swift"
WORK="$(mktemp -d)"
FAILURES=0

command -v docker > /dev/null || {
    echo "docker not found" >&2
    exit 3
}
[ -f "$PROTOCOL" ] || {
    echo "not found: $PROTOCOL" >&2
    exit 3
}

# The statements below are copies of what the plugin builds. Each fragment must still be in the source, so
# the two cannot drift apart silently.
for fragment in \
    "SELECT func, linenumber, targetname FROM" \
    "pldbg_wait_for_breakpoint" \
    "pldbg_attach_to_port" \
    "pldbg_oid_debug" \
    "pldbg_get_source" \
    "pldbg_select_frame" \
    "pldbg_set_breakpoint" \
    "pldbg_drop_breakpoint" \
    "SELECT * FROM \\(function(\"pldbg_abort_target\"" \
    "SELECT level, targetname, func, linenumber, args FROM" \
    "SELECT name, varclass, linenumber, isunique, isconst, isnotnull, pg_catalog.format_type(dtype, NULL), value" \
    "SET statement_timeout = 0" \
    "SET idle_session_timeout = 0" \
    "SET transaction_timeout = 0" \
    "SET client_min_messages = notice" \
    "max(reported - 1, 1)" \
    "COALESCE(p.proowner = r.oid OR r.rolsuper, false)" \
    "EXISTS (SELECT 1 FROM pg_catalog.pg_available_extensions a WHERE a.name = 'pldbgapi')" \
    "p.prorettype = 'pg_catalog.record'::pg_catalog.regtype" \
    "SELECT 1 FROM pg_catalog.unnest(p.proargtypes::pg_catalog.oid[]) AS a(t)" \
    "WHERE ty.typtype = 'p'" \
    "p.proconfig" \
    "message.contains(\"select() failed\")" \
    "JOIN pg_catalog.pg_type ty ON ty.oid = (\\(argumentTypes))[s.i]" \
    "|| pg_catalog.replace(ty.typname, '\"', '\"\"') || '\"'" \
    "quoteLiteral(String(oid)))::pg_catalog.oid" \
    "PLDBGBREAK:" \
    "\"08006\"" \
    "\"57014\""; do
    grep -qF -- "$fragment" "$PROTOCOL" || {
        echo "FAIL: $PROTOCOL no longer contains: $fragment; update this script with the plugin" >&2
        exit 1
    }
done

cleanup() {
    [ "$KEEP" = 1 ] || docker rm -f "$CONTAINER" > /dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }
fail() {
    echo "FAIL $1"
    FAILURES=$((FAILURES + 1))
}

# expect <file> <fixed text> <label>
expect() {
    if grep -qF -- "$2" "$1"; then
        pass "$3"
    else
        fail "$3 (no \"$2\" in $(basename "$1"))"
        sed 's/^/    /' "$1"
    fi
}

# expect_after <file> <marker line> <line that must follow it> <label>
expect_after() {
    local following
    following=$(awk -v marker="$2" 'found { print; exit } $0 == marker { found = 1 }' "$1")
    if [ "$following" = "$3" ]; then
        pass "$4"
    else
        fail "$4 (after $2: \"$following\", wanted \"$3\")"
    fi
}

sql() {
    local user=$1 database=$2
    shift 2
    docker exec -i "$CONTAINER" psql -X -q -At -U "$user" -d "$database" "$@"
}

if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "Building $IMAGE"
    printf 'FROM postgres:17\nRUN apt-get update && apt-get install -y --no-install-recommends postgresql-17-pldebugger && rm -rf /var/lib/apt/lists/*\n' \
        | docker build -q -t "$IMAGE" - > /dev/null || {
        echo "could not build $IMAGE" >&2
        exit 3
    }
fi
docker run -d --name "$CONTAINER" -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" -c transaction_timeout=2s > /dev/null || exit 3

# The entrypoint initializes on a temporary server and restarts, so wait for the restart before connecting.
ready=0
for _ in $(seq 1 120); do
    if docker logs "$CONTAINER" 2>&1 | grep -F "init process complete" > /dev/null \
        && sql postgres postgres -c "SELECT 1" > /dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.5
done
[ "$ready" = 1 ] || {
    echo "the server did not start" >&2
    exit 3
}
echo "Checking pldbgapi against $(sql postgres postgres -c "SELECT version()")"

sql postgres postgres -v ON_ERROR_STOP=1 > /dev/null <<'SQL' || exit 3
CREATE ROLE dev LOGIN;
CREATE ROLE other LOGIN;
CREATE EXTENSION pldbgapi;
GRANT CREATE ON SCHEMA public TO dev;
GRANT CREATE ON DATABASE postgres TO dev;
CREATE DATABASE noext OWNER dev;
SET ROLE dev;
CREATE SCHEMA app;
CREATE DOMAIN app."Code3" AS char(3);
CREATE FUNCTION pick(v bit) RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN 'bit:' || v::text; END; $$;
CREATE FUNCTION pick(v bit varying) RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN 'varbit:' || v::text; END; $$;
CREATE FUNCTION pick(v char(3)) RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN 'char:' || v::text; END; $$;
CREATE FUNCTION pick(v varchar) RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN 'varchar:' || v::text; END; $$;
CREATE FUNCTION pick(v bit[]) RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN 'bit[]:' || v::text; END; $$;
CREATE FUNCTION pick(v bit varying[]) RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN 'varbit[]:' || v::text; END; $$;
CREATE FUNCTION pick(v app."Code3") RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN 'domain:' || v::text; END; $$;
CREATE TABLE audit_log(id serial PRIMARY KEY, note text);
CREATE FUNCTION add_tax(amount numeric, rate numeric DEFAULT 0.1)
RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE
    tax numeric;
BEGIN
    tax := amount * rate;
    RETURN amount + tax;
END;
$$;
CREATE FUNCTION order_total(qty integer, unit_price numeric)
RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE
    subtotal numeric := 0;
    total numeric;
    r record;
    i integer;
BEGIN
    FOR i IN 1..qty LOOP
        subtotal := subtotal + unit_price;
    END LOOP;
    SELECT 1 AS a, 'x'::text AS b INTO r;
    INSERT INTO audit_log(note) VALUES ('order_total ' || qty);
    total := add_tax(subtotal);
    RETURN total;
END;
$$;
CREATE PROCEDURE log_note(msg text, INOUT n integer DEFAULT NULL, label text DEFAULT 'x')
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log(note) VALUES (msg || label);
    SELECT count(*) INTO n FROM audit_log;
    RAISE NOTICE 'rows now %', n;
END;
$$;
CREATE FUNCTION poly_elem(a anyelement) RETURNS anyelement LANGUAGE plpgsql AS $$ BEGIN RETURN a; END; $$;
CREATE FUNCTION rec_in(r record) RETURNS integer LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END; $$;
CREATE FUNCTION quiet(x integer) RETURNS integer LANGUAGE plpgsql SET client_min_messages = warning AS $$
BEGIN
    RETURN x + 1;
END;
$$;
CREATE FUNCTION short_txn(x integer) RETURNS integer LANGUAGE plpgsql SET transaction_timeout = '2s' AS $$
DECLARE
    y integer;
BEGIN
    y := x + 1;
    RETURN y;
END;
$$;
CREATE FUNCTION two_stops() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    a integer;
BEGIN
    PERFORM pg_sleep(3);
    a := 1;
    a := 2;
    RETURN a;
END;
$$;
CREATE FUNCTION codes(code char(3), flags bit(3), many char(2)[]) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    RETURN code || '/' || flags::text || '/' || many::text;
END;
$$;
CREATE FUNCTION slow_fn() RETURNS integer LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_log(note) VALUES ('slow');
    PERFORM pg_sleep(4);
    RETURN 1;
END;
$$;
SQL
sql dev noext -v ON_ERROR_STOP=1 -c 'CREATE FUNCTION g() RETURNS integer LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END; $$' \
    > /dev/null || exit 3

ORDER_TOTAL=$(sql postgres postgres -c "SELECT 'public.order_total(integer,numeric)'::regprocedure::oid")
ADD_TAX=$(sql postgres postgres -c "SELECT 'public.add_tax(numeric,numeric)'::regprocedure::oid")
LOG_NOTE=$(sql postgres postgres -c "SELECT 'public.log_note(text,integer,text)'::regprocedure::oid")
SLOW_FN=$(sql postgres postgres -c "SELECT 'public.slow_fn()'::regprocedure::oid")
POLY_ELEM=$(sql postgres postgres -c "SELECT 'public.poly_elem(anyelement)'::regprocedure::oid")
REC_IN=$(sql postgres postgres -c "SELECT 'public.rec_in(record)'::regprocedure::oid")
QUIET=$(sql postgres postgres -c "SELECT 'public.quiet(integer)'::regprocedure::oid")
SHORT_TXN=$(sql postgres postgres -c "SELECT 'public.short_txn(integer)'::regprocedure::oid")
TWO_STOPS=$(sql postgres postgres -c "SELECT 'public.two_stops()'::regprocedure::oid")
G=$(sql dev noext -c "SELECT 'public.g()'::regprocedure::oid")
audit() { sql postgres postgres -c "SELECT count(*) FROM audit_log"; }

# --- The catalog read prepareDebug and startDebug run (routineQuery with hasProcedureKind) -------------------

cat > "$WORK/routine.sql" <<'SQL'
SELECT
    pg_catalog.current_database(),
    (SELECT en.nspname FROM pg_catalog.pg_extension e
        JOIN pg_catalog.pg_namespace en ON en.oid = e.extnamespace
        WHERE e.extname = 'pldbgapi'),
    EXISTS (SELECT 1 FROM pg_catalog.pg_available_extensions a WHERE a.name = 'pldbgapi'),
    p.oid IS NOT NULL,
    COALESCE(p.proowner = r.oid OR r.rolsuper, false),
    p.prokind,
    p.provolatile,
    l.lanname,
    n.nspname,
    p.proname,
    pg_catalog.pg_get_function_identity_arguments(p.oid),
    p.prorettype = 'pg_catalog.record'::pg_catalog.regtype,
    p.prorettype IN ('pg_catalog.trigger'::pg_catalog.regtype, 'pg_catalog.event_trigger'::pg_catalog.regtype),
    ARRAY(
        SELECT pg_catalog.format_type((COALESCE(p.proallargtypes, p.proargtypes::pg_catalog.oid[]))[s.i], NULL)
        FROM pg_catalog.generate_subscripts(COALESCE(p.proallargtypes, p.proargtypes::pg_catalog.oid[]), 1) AS s(i)
        ORDER BY s.i
    ),
    p.proargnames,
    p.proargmodes::pg_catalog.text[],
    p.pronargdefaults,
    EXISTS (
        SELECT 1 FROM pg_catalog.unnest(p.proargtypes::pg_catalog.oid[]) AS a(t)
        JOIN pg_catalog.pg_type ty ON ty.oid = a.t
        WHERE ty.typtype = 'p'
    ),
    p.proconfig,
    ARRAY(
        SELECT '"' || pg_catalog.replace(tn.nspname, '"', '""') || '"."'
            || pg_catalog.replace(ty.typname, '"', '""') || '"'
        FROM pg_catalog.generate_subscripts(COALESCE(p.proallargtypes, p.proargtypes::pg_catalog.oid[]), 1) AS s(i)
        JOIN pg_catalog.pg_type ty ON ty.oid = (COALESCE(p.proallargtypes, p.proargtypes::pg_catalog.oid[]))[s.i]
        JOIN pg_catalog.pg_namespace tn ON tn.oid = ty.typnamespace
        ORDER BY s.i
    )
FROM (SELECT 1) AS one
LEFT JOIN pg_catalog.pg_proc p ON p.oid = :'oid'::pg_catalog.oid
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
LEFT JOIN pg_catalog.pg_language l ON l.oid = p.prolang
LEFT JOIN pg_catalog.pg_roles r ON r.rolname = CURRENT_USER
SQL

echo "== catalog read"
sql dev postgres -v oid="$ORDER_TOTAL" < "$WORK/routine.sql" > "$WORK/routine.owner.log" 2>&1
expect "$WORK/routine.owner.log" \
    "postgres|public|t|t|t|f|v|plpgsql|public|order_total|qty integer, unit_price numeric|f|f|{integer,numeric}|{qty,unit_price}||0|f|" \
    "the owner may debug order_total; one row has every fact prepareDebug needs"
expect "$WORK/routine.owner.log" '|{"\"pg_catalog\".\"int4\"","\"pg_catalog\".\"numeric\""}' \
    "each argument's exact type comes back as its quoted pg_type name"
sql dev postgres -v oid="$LOG_NOTE" < "$WORK/routine.sql" > "$WORK/routine.procedure.log" 2>&1
expect "$WORK/routine.procedure.log" \
    "postgres|public|t|t|t|p|v|plpgsql|public|log_note|IN msg text, INOUT n integer, IN label text|t|f|{text,integer,text}|{msg,n,label}|{i,b,i}|2|f|" \
    "a procedure's modes and its two trailing defaults"
sql other postgres -v oid="$ORDER_TOTAL" < "$WORK/routine.sql" > "$WORK/routine.other.log" 2>&1
expect "$WORK/routine.other.log" "postgres|public|t|t|f|f|v|plpgsql" "a role that is neither owner nor superuser may not"
sql dev noext -v oid="$G" < "$WORK/routine.sql" > "$WORK/routine.noext.log" 2>&1
expect "$WORK/routine.noext.log" "noext||t|t|t|f|v|plpgsql|public|g|" \
    "no extension in this database, but the server offers it"
for pseudo in "$POLY_ELEM" "$REC_IN"; do
    sql dev postgres -v oid="$pseudo" < "$WORK/routine.sql" > "$WORK/routine.pseudo.log" 2>&1
    if [ "$(awk -F'|' '{ print $(NF - 2) }' "$WORK/routine.pseudo.log")" = "t" ]; then
        pass "an anyelement or record argument is flagged, since the debugger cannot bind one"
    else
        fail "an anyelement or record argument is flagged, since the debugger cannot bind one"
        sed 's/^/    /' "$WORK/routine.pseudo.log"
    fi
done
docker exec -i "$CONTAINER" psql -X -At -U dev -d postgres > "$WORK/pseudo-call.log" 2>&1 <<'SQL'
SELECT * FROM "public"."poly_elem"($1) \bind 5 \g
SELECT * FROM "public"."rec_in"($1::record) \bind (1,2) \g
SQL
expect "$WORK/pseudo-call.log" "could not determine polymorphic type because input has type unknown" \
    "a bound text argument cannot resolve a polymorphic parameter"
expect "$WORK/pseudo-call.log" "input of anonymous composite types is not implemented" \
    "a bound text argument cannot become a record"
sql dev postgres -c "SHOW shared_preload_libraries" > "$WORK/preload.log" 2>&1
expect "$WORK/preload.log" "permission denied to examine \"shared_preload_libraries\"" \
    "a non-superuser cannot read shared_preload_libraries, so nothing may gate on it"

# --- Session helpers -----------------------------------------------------------------------------------------

# start_target <name> <user> [psql args]: runs <name>.target.sql in the background.
start_target() {
    local name=$1 user=$2
    shift 2
    docker exec -i "$CONTAINER" psql -X -At -U "$user" -d postgres "$@" < "$WORK/$name.target.sql" \
        > "$WORK/$name.target.log" 2>&1 &
    TARGET=$!
}

# await_port <name>: sets PORT from the target's PLDBGBREAK notice.
await_port() {
    PORT=""
    for _ in $(seq 1 100); do
        PORT=$(grep -o 'PLDBGBREAK:[0-9]*' "$WORK/$1.target.log" | head -1 | cut -d: -f2)
        [ -n "$PORT" ] && return 0
        kill -0 "$TARGET" 2> /dev/null || return 1
        sleep 0.1
    done
    return 1
}

run_proxy() {
    local name=$1 user=$2
    shift 2
    docker exec -i "$CONTAINER" psql -X -At -U "$user" -d postgres -v port="$PORT" "$@" < "$WORK/$name.proxy.sql" \
        > "$WORK/$name.proxy.log" 2>&1
}

TARGET_SETUP='SET statement_timeout = 0;
SET idle_session_timeout = 0;
SET transaction_timeout = 0;
SET client_min_messages = notice;'
PROXY_SETUP='SET statement_timeout = 0;
SET idle_session_timeout = 0;
SET transaction_timeout = 0;'

# --- A full session as the owner, no superuser, no preload ---------------------------------------------------

echo "== full session"
before=$(audit)
cat > "$WORK/full.target.sql" <<SQL
$TARGET_SETUP
SELECT "public".pldbg_oid_debug('$ORDER_TOTAL'::pg_catalog.oid);
SELECT * FROM "public"."order_total"(\$1::integer, \$2::numeric) \bind 3 10 \g
SQL
cat > "$WORK/full.proxy.sql" <<SQL
$PROXY_SETUP
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
\echo ==wait
SELECT func, linenumber, targetname FROM "public".pldbg_wait_for_breakpoint(:s);
\echo ==source
SELECT "public".pldbg_get_source(:s, '$ORDER_TOTAL'::pg_catalog.oid);
\echo ==stack
SELECT level, targetname, func, linenumber, args FROM "public".pldbg_get_stack(:s);
\echo ==variables
SELECT name, varclass, linenumber, isunique, isconst, isnotnull, pg_catalog.format_type(dtype, NULL), value FROM "public".pldbg_get_variables(:s);
SELECT pg_sleep(2.5);
\echo ==after-pause
SELECT level, func, linenumber FROM "public".pldbg_get_stack(:s);
\echo ==set
SELECT "public".pldbg_set_breakpoint(:s, '$ORDER_TOTAL'::pg_catalog.oid, 12);
\echo ==drop
SELECT "public".pldbg_drop_breakpoint(:s, '$ORDER_TOTAL'::pg_catalog.oid, 77);
\echo ==continue
SELECT func, linenumber, targetname FROM "public".pldbg_continue(:s);
\echo ==step-over
SELECT func, linenumber, targetname FROM "public".pldbg_step_over(:s);
\echo ==step-into
SELECT func, linenumber, targetname FROM "public".pldbg_step_into(:s);
\echo ==stack-2
SELECT level, targetname, func, linenumber, args FROM "public".pldbg_get_stack(:s);
\echo ==frame-1
SELECT func, linenumber, targetname FROM "public".pldbg_select_frame(:s, 1);
SELECT name, varclass, linenumber, isunique, isconst, isnotnull, pg_catalog.format_type(dtype, NULL), value FROM "public".pldbg_get_variables(:s);
\echo ==run-out
SELECT func, linenumber, targetname FROM "public".pldbg_continue(:s);
SELECT func, linenumber, targetname FROM "public".pldbg_continue(:s);
\echo ==end
SQL
start_target full dev
if await_port full; then
    pass "the target's PLDBGBREAK notice arrives while its call is still running (backend $PORT)"
    run_proxy full dev
    wait "$TARGET"
    proxy="$WORK/full.proxy.log"
    expect "$proxy" "$ORDER_TOTAL|9|order_total(integer,numeric)" "the first stop is reported as line 9 for source line 8"
    source_line=$(awk '/^==source$/ { inside = 1; line = 0; next } /^==stack$/ { inside = 0 } inside { line++; if (line == 8) print }' "$proxy")
    if [ "$source_line" = "    FOR i IN 1..qty LOOP" ]; then
        pass "pldbg_get_source line 8 is the FOR loop, the first executable statement"
    else
        fail "pldbg_get_source line 8 is \"$source_line\""
    fi
    expect "$proxy" "0|order_total(integer,numeric)|$ORDER_TOTAL|8|qty=3, unit_price=10" "a stack frame's line is the source line"
    expect "$proxy" "total|L|4|t|f|f|numeric|NULL" "a NULL variable arrives as the text NULL"
    expect_after "$proxy" "==after-pause" "0|$ORDER_TOTAL|8" \
        "the target survives a pause longer than the server's 2 s transaction_timeout"
    expect "$proxy" "qty|A|0|t|f|f|integer|3" "an argument is class A with its bound value"
    expect_after "$proxy" "==set" "t" "pldbg_set_breakpoint answers t"
    expect_after "$proxy" "==drop" "f" "pldbg_drop_breakpoint answers f for a line with no breakpoint"
    expect_after "$proxy" "==continue" "$ORDER_TOTAL|13|order_total(integer,numeric)" \
        "a breakpoint set on source line 12 stops reported as 13"
    expect_after "$proxy" "==step-over" "$ORDER_TOTAL|14|order_total(integer,numeric)" "step over moves one statement"
    expect_after "$proxy" "==step-into" "$ADD_TAX|6|add_tax(numeric,numeric)" "step into enters the callee"
    expect "$proxy" "1|order_total(integer,numeric)|$ORDER_TOTAL|13|qty=3, unit_price=10" \
        "the caller's frame keeps its source line"
    expect "$proxy" "subtotal|L|3|t|f|f|numeric|30" "select_frame 1 reads the caller's variables"
    expect "$proxy" "debugger connection terminated" "the proxy learns the end from 08006"
    expect "$WORK/full.target.log" "33.0" "the target's call returns the routine's result"
    [ "$(audit)" = $((before + 1)) ] && pass "a run that finishes commits its changes" \
        || fail "a run that finishes commits its changes"
else
    fail "no PLDBGBREAK notice"
    cat "$WORK/full.target.log"
fi

# --- Stop while paused: pldbg_abort_target -------------------------------------------------------------------

echo "== stop while paused"
before=$(audit)
cat > "$WORK/abort.target.sql" <<SQL
$TARGET_SETUP
SELECT "public".pldbg_oid_debug('$ORDER_TOTAL'::pg_catalog.oid);
SELECT * FROM "public"."order_total"(\$1::integer, \$2::numeric) \bind 2 5 \g
SQL
cat > "$WORK/abort.proxy.sql" <<SQL
$PROXY_SETUP
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
SELECT func, linenumber, targetname FROM "public".pldbg_wait_for_breakpoint(:s);
SELECT "public".pldbg_set_breakpoint(:s, '$ORDER_TOTAL'::pg_catalog.oid, 13);
SELECT func, linenumber, targetname FROM "public".pldbg_continue(:s);
\echo ==abort
SELECT * FROM "public".pldbg_abort_target(:s);
\echo ==after
SELECT level, targetname, func, linenumber, args FROM "public".pldbg_get_stack(:s);
SQL
start_target abort dev
if await_port abort; then
    run_proxy abort dev
    wait "$TARGET"
    expect_after "$WORK/abort.proxy.log" "==abort" "t" "pldbg_abort_target answers t"
    expect "$WORK/abort.target.log" "canceling statement due to user request" "the target ends with 57014"
    expect "$WORK/abort.target.log" "CONTEXT:  PL/pgSQL function order_total(integer,numeric) line 13 at assignment" \
        "the target's error keeps the line it stopped on"
    [ "$(audit)" = "$before" ] && pass "Stop rolls back the INSERT the routine already ran" \
        || fail "Stop rolls back the INSERT the routine already ran"
else
    fail "no PLDBGBREAK notice"
fi

# --- Stop while running: cancel the target, never the proxy -------------------------------------------------

echo "== stop while running"
before=$(audit)
cat > "$WORK/running.target.sql" <<SQL
$TARGET_SETUP
SELECT 'TARGET ' || pg_backend_pid();
SELECT "public".pldbg_oid_debug('$SLOW_FN'::pg_catalog.oid);
SELECT * FROM "public"."slow_fn"() \bind \g
SQL
cat > "$WORK/running.proxy.sql" <<SQL
$PROXY_SETUP
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
SELECT func, linenumber, targetname FROM "public".pldbg_wait_for_breakpoint(:s);
\echo ==continue
SELECT func, linenumber, targetname FROM "public".pldbg_continue(:s);
\echo ==after
SELECT 'proxy usable';
SQL
start_target running dev
if await_port running; then
    target_pid=$(grep -o 'TARGET [0-9]*' "$WORK/running.target.log" | cut -d' ' -f2)
    run_proxy running dev &
    proxy_job=$!
    sleep 1.5
    sql postgres postgres -c "SELECT pg_cancel_backend($target_pid)" > /dev/null
    wait "$proxy_job"
    wait "$TARGET"
    expect "$WORK/running.target.log" "CONTEXT:  SQL statement \"SELECT pg_sleep(4)\"" "a cancel ends the running target"
    expect "$WORK/running.proxy.log" "debugger connection terminated" "the waiting proxy call ends with 08006"
    expect "$WORK/running.proxy.log" "proxy usable" "the proxy session stays usable"
    [ "$(audit)" = "$before" ] && pass "the cancelled run rolls back" || fail "the cancelled run rolls back"
else
    fail "no PLDBGBREAK notice"
fi

# --- A target whose proxy disappeared ------------------------------------------------------------------------

echo "== proxy lost while paused"
before=$(audit)
cat > "$WORK/lost.target.sql" <<SQL
$TARGET_SETUP
SELECT "public".pldbg_oid_debug('$ORDER_TOTAL'::pg_catalog.oid);
SELECT * FROM "public"."order_total"(\$1::integer, \$2::numeric) \bind 2 5 \g
SQL
cat > "$WORK/lost.proxy.sql" <<SQL
$PROXY_SETUP
SELECT 'PROXY ' || pg_backend_pid();
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
\echo ==paused
SELECT func, linenumber, targetname FROM "public".pldbg_wait_for_breakpoint(:s);
SELECT pg_sleep(30);
SQL
cat > "$WORK/lost.rescue.sql" <<'SQL'
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
\echo ==abort
SELECT * FROM "public".pldbg_abort_target(:s);
SQL
start_target lost dev
if await_port lost; then
    run_proxy lost dev &
    proxy_job=$!
    for _ in $(seq 1 50); do
        grep -F "==paused" "$WORK/lost.proxy.log" > /dev/null 2>&1 && break
        sleep 0.1
    done
    sleep 0.5
    proxy_pid=$(grep -o 'PROXY [0-9]*' "$WORK/lost.proxy.log" | cut -d' ' -f2)
    sql postgres postgres -c "SELECT pg_terminate_backend($proxy_pid)" > /dev/null
    wait "$proxy_job"
    notices=0
    for _ in $(seq 1 30); do
        notices=$(grep -c "PLDBGBREAK:$PORT\$" "$WORK/lost.target.log")
        [ "$notices" = 2 ] && break
        sleep 0.1
    done
    [ "$notices" = 2 ] && pass "the target waits again under the same backend number" \
        || fail "the target waits again under the same backend number ($notices notices)"
    sql postgres postgres -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE query LIKE '%order_total%' AND state = 'active' AND pid <> pg_backend_pid()" \
        > /dev/null
    sleep 0.5
    if kill -0 "$TARGET" 2> /dev/null; then
        pass "a cancel does not end a target waiting for its proxy"
    else
        fail "a cancel does not end a target waiting for its proxy"
    fi
    docker exec -i "$CONTAINER" psql -X -At -U dev -d postgres -v port="$PORT" < "$WORK/lost.rescue.sql" \
        > "$WORK/lost.rescue.log" 2>&1
    wait "$TARGET"
    expect_after "$WORK/lost.rescue.log" "==abort" "t" "a fresh session attaches to that number and aborts"
    expect "$WORK/lost.target.log" "canceling statement due to user request" "the abandoned target ends"
    [ "$(audit)" = "$before" ] && pass "the abandoned run rolls back" || fail "the abandoned run rolls back"
else
    fail "no PLDBGBREAK notice"
fi

# --- A procedure, a named argument after a default, and its notices -----------------------------------------

echo "== procedure"
cat > "$WORK/procedure.target.sql" <<SQL
$TARGET_SETUP
SELECT "public".pldbg_oid_debug('$LOG_NOTE'::pg_catalog.oid);
CALL "public"."log_note"(\$1::text, "label" => \$2::text) \bind hi -x \g
SQL
cat > "$WORK/procedure.proxy.sql" <<SQL
$PROXY_SETUP
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
SELECT func, linenumber, targetname FROM "public".pldbg_wait_for_breakpoint(:s);
SELECT name, varclass, linenumber, isunique, isconst, isnotnull, pg_catalog.format_type(dtype, NULL), value FROM "public".pldbg_get_variables(:s);
SELECT func, linenumber, targetname FROM "public".pldbg_continue(:s);
SQL
start_target procedure dev
if await_port procedure; then
    run_proxy procedure dev
    wait "$TARGET"
    expect "$WORK/procedure.proxy.log" "label|A|0|t|f|f|text|-x" "a named argument after a defaulted one binds"
    expect "$WORK/procedure.proxy.log" "n|A|0|t|f|f|integer|NULL" "the skipped INOUT parameter takes its default"
    expect "$WORK/procedure.target.log" "NOTICE:  rows now" "RAISE NOTICE reaches the target session"
else
    fail "no PLDBGBREAK notice"
fi

# --- A transaction startup commands left open ----------------------------------------------------------------

echo "== startup transaction"
# run_to_end <name> <first lines>: the call runs to the end of order_total(1, 1) after the given lines.
run_to_end() {
    cat > "$WORK/$1.target.sql" <<SQL
$2
$TARGET_SETUP
SELECT "public".pldbg_oid_debug('$ORDER_TOTAL'::pg_catalog.oid);
SELECT * FROM "public"."order_total"(\$1::integer, \$2::numeric) \bind 1 1 \g
\echo ==after-call
SQL
    cat > "$WORK/$1.proxy.sql" <<SQL
$PROXY_SETUP
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
SELECT func, linenumber, targetname FROM "public".pldbg_wait_for_breakpoint(:s);
SELECT func, linenumber, targetname FROM "public".pldbg_continue(:s);
SQL
    start_target "$1" dev
    if await_port "$1"; then
        run_proxy "$1" dev
        wait "$TARGET"
    else
        fail "no PLDBGBREAK notice"
    fi
}
before=$(audit)
run_to_end open-transaction "BEGIN;"
expect "$WORK/open-transaction.target.log" "1.1" "the routine runs inside a transaction a startup BEGIN left open"
[ "$(audit)" = "$before" ] && pass "and its changes are not committed when it finishes, so the plugin rolls that transaction back first" \
    || fail "and its changes are not committed when it finishes, so the plugin rolls that transaction back first"
before=$(audit)
run_to_end rolled-back $'BEGIN;\nROLLBACK;'
[ "$(audit)" = $((before + 1)) ] && pass "after the ROLLBACK the finished run commits as usual" \
    || fail "after the ROLLBACK the finished run commits as usual"

# --- What a routine's own settings and argument types do -------------------------------------------------------

echo "== routine settings and argument types"
sql dev postgres -v oid="$QUIET" < "$WORK/routine.sql" > "$WORK/routine.quiet.log" 2>&1
expect "$WORK/routine.quiet.log" "|{client_min_messages=warning}" "the catalog read returns a routine's own settings"
cat > "$WORK/quiet.target.sql" <<SQL
$TARGET_SETUP
SELECT "public".pldbg_oid_debug('$QUIET'::pg_catalog.oid);
SELECT * FROM "public"."quiet"(\$1::integer) \bind 1 \g
SQL
start_target quiet dev
sleep 2
if grep -F "PLDBGBREAK" "$WORK/quiet.target.log" > /dev/null; then
    fail "a routine's SET client_min_messages = warning hides PLDBGBREAK, so the plugin refuses such a routine"
else
    pass "a routine's SET client_min_messages = warning hides PLDBGBREAK, so the plugin refuses such a routine"
fi
# The target now waits in accept() for a proxy it never named; it goes when the container does.
kill "$TARGET" 2> /dev/null
cat > "$WORK/short.target.sql" <<SQL
$TARGET_SETUP
SELECT "public".pldbg_oid_debug('$SHORT_TXN'::pg_catalog.oid);
SELECT * FROM "public"."short_txn"(\$1::integer) \bind 1 \g
SQL
cat > "$WORK/short.proxy.sql" <<SQL
$PROXY_SETUP
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
SELECT func, linenumber, targetname FROM "public".pldbg_wait_for_breakpoint(:s);
SELECT pg_sleep(3);
SELECT func, linenumber, targetname FROM "public".pldbg_step_over(:s);
SQL
start_target short dev
if await_port short; then
    run_proxy short dev
    wait "$TARGET"
    expect "$WORK/short.target.log" "terminating connection due to transaction timeout" \
        "a routine's SET transaction_timeout ends it while it waits at a breakpoint, so the plugin refuses such a routine"
else
    fail "no PLDBGBREAK notice"
fi
docker exec -i "$CONTAINER" psql -X -At -U dev -d postgres > "$WORK/codes.log" 2>&1 <<'SQL'
SELECT * FROM "public"."codes"($1::"pg_catalog"."bpchar", $2::"pg_catalog"."bit", $3::"pg_catalog"."_bpchar") \bind ABC 101 {XY,ZW} \g
SELECT * FROM "public"."codes"($1::character, $2::bit, $3::character[]) \bind ABC 101 {XY,ZW} \g
SELECT * FROM "public"."pick"($1::"pg_catalog"."bit") \bind 101 \g
SELECT * FROM "public"."pick"($1::"pg_catalog"."varbit") \bind 101 \g
SELECT * FROM "public"."pick"($1::"pg_catalog"."bpchar") \bind ABCD \g
SELECT * FROM "public"."pick"($1::"pg_catalog"."_bit") \bind {101,11} \g
SELECT * FROM "public"."pick"($1::"app"."Code3") \bind AB \g
\echo ==unlimited-spelling
SELECT * FROM "public"."pick"($1::pg_catalog.varbit) \bind 101 \g
SQL
expect "$WORK/codes.log" "ABC/101/{XY,ZW}" "arguments cast to their quoted pg_type names keep their length"
expect "$WORK/codes.log" "A/1/{X,Z}" "a cast to character or bit, as format_type spells them, cuts them to one"
for result in "bit:101" "varbit:101" "char:ABCD" "bit[]:{101,11}" "domain:AB"; do
    if grep -qxF -- "$result" "$WORK/codes.log"; then
        pass "the quoted pg_type name calls exactly that overload and keeps the value ($result)"
    else
        fail "the quoted pg_type name calls exactly that overload and keeps the value ($result)"
        sed 's/^/    /' "$WORK/codes.log"
    fi
done
expect_after "$WORK/codes.log" "==unlimited-spelling" "varbit:101" \
    "varbit is not a way to keep a bit(n) argument: it calls the bit varying overload"

# --- The proxy's two 08006 errors -----------------------------------------------------------------------------

echo "== proxy interrupted while it waits"
cat > "$WORK/interrupted.target.sql" <<SQL
$TARGET_SETUP
SELECT "public".pldbg_oid_debug('$TWO_STOPS'::pg_catalog.oid);
SELECT * FROM "public"."two_stops"() \bind \g
SQL
cat > "$WORK/interrupted.proxy.sql" <<SQL
$PROXY_SETUP
SELECT 'PROXY ' || pg_backend_pid();
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
SELECT func, linenumber, targetname FROM "public".pldbg_wait_for_breakpoint(:s);
SELECT "public".pldbg_set_breakpoint(:s, '$TWO_STOPS'::pg_catalog.oid, 6);
SELECT func, linenumber, targetname FROM "public".pldbg_continue(:s);
\echo ==abort
SELECT * FROM "public".pldbg_abort_target(:s);
SELECT pg_sleep(4);
SQL
start_target interrupted dev
if await_port interrupted; then
    run_proxy interrupted dev &
    proxy_job=$!
    sleep 1
    proxy_pid=$(grep -o 'PROXY [0-9]*' "$WORK/interrupted.proxy.log" | cut -d' ' -f2)
    sql postgres postgres -c "SELECT pg_cancel_backend($proxy_pid)" > /dev/null
    wait "$proxy_job"
    wait "$TARGET"
    expect "$WORK/interrupted.proxy.log" "select() failed waiting for target" \
        "a signal to the waiting proxy gives 08006 select() failed, not the target's end"
    expect "$WORK/interrupted.target.log" "CONTEXT:  PL/pgSQL function two_stops() line 6 at assignment" \
        "the target still paused at its breakpoint, and an abort on the same proxy, kept connected, ended it there"
else
    fail "no PLDBGBREAK notice"
fi
# No cancel this time: the server's transaction_timeout (2s here) interrupts a longer wait although the session's is 0.
cp "$WORK/interrupted.proxy.sql" "$WORK/timeout.proxy.sql"
cp "$WORK/interrupted.target.sql" "$WORK/timeout.target.sql"
start_target timeout dev
if await_port timeout; then
    run_proxy timeout dev
    wait "$TARGET"
    expect "$WORK/timeout.proxy.log" "select() failed waiting for target" \
        "on PostgreSQL 17 a server transaction_timeout interrupts a proxy wait that outlasts it, so the plugin ends such a run"
else
    fail "no PLDBGBREAK notice"
fi

echo "== a routine that returns"
cat > "$WORK/returns.target.sql" <<SQL
$TARGET_SETUP
SELECT "public".pldbg_oid_debug('$ORDER_TOTAL'::pg_catalog.oid);
SELECT * FROM "public"."order_total"(\$1::integer, \$2::numeric) \bind 1 1 \g
SELECT 'CALL-DONE ' || extract(epoch FROM clock_timestamp());
SELECT pg_sleep(1.5);
SQL
cat > "$WORK/returns.proxy.sql" <<SQL
$PROXY_SETUP
SELECT "public".pldbg_attach_to_port(:port) AS s \gset
SELECT func, linenumber, targetname FROM "public".pldbg_wait_for_breakpoint(:s);
SELECT func, linenumber, targetname FROM "public".pldbg_continue(:s);
SELECT 'PROXY-DONE ' || extract(epoch FROM clock_timestamp());
SQL
start_target returns dev
if await_port returns; then
    run_proxy returns dev
    wait "$TARGET"
    call_done=$(grep -o 'CALL-DONE [0-9.]*' "$WORK/returns.target.log" | cut -d' ' -f2)
    proxy_done=$(grep -o 'PROXY-DONE [0-9.]*' "$WORK/returns.proxy.log" | cut -d' ' -f2)
    if [ -n "$call_done" ] && [ -n "$proxy_done" ] && awk -v a="$call_done" -v b="$proxy_done" 'BEGIN { exit !(b - a > 1.2) }'; then
        pass "the proxy hears a routine returned only when the target's session ends, so the plugin watches the target's call"
    else
        fail "the proxy hears a routine returned only when the target's session ends ($call_done, $proxy_done)"
    fi
else
    fail "no PLDBGBREAK notice"
fi

# --- What prepareDebug and startDebug map ---------------------------------------------------------------------

echo "== refusals"
sql other postgres -c "\set VERBOSITY verbose" -c "SELECT \"public\".pldbg_oid_debug('$ORDER_TOTAL'::pg_catalog.oid)" \
    > "$WORK/refuse.owner.log" 2>&1
expect "$WORK/refuse.owner.log" "42501: must be owner or superuser to create a breakpoint" \
    "a non-owner is refused with 42501"
sql dev noext -c "\set VERBOSITY verbose" -c "SELECT \"public\".pldbg_oid_debug('$G'::pg_catalog.oid)" \
    > "$WORK/refuse.extension.log" 2>&1
expect "$WORK/refuse.extension.log" "42883: function public.pldbg_oid_debug(oid) does not exist" \
    "a database without the extension answers 42883"

echo
if [ "$FAILURES" = 0 ]; then
    echo "All pldbgapi checks passed."
else
    echo "$FAILURES check(s) failed."
    exit 1
fi
