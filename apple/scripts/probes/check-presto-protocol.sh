#!/usr/bin/env bash
#
# Checks the Presto facts the Trino plugin's Presto type hard-codes, against a stock coordinator.
#
# Usage:
#   scripts/probes/check-presto-protocol.sh [host] [port]     # default 127.0.0.1 8080
#
# To bring a coordinator up first:
#   docker run -d --name tp-presto -p 8080:8080 prestodb/presto:latest

set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-8080}"

exec python3 -I - "$HOST" "$PORT" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

host, port = sys.argv[1], sys.argv[2]
base = f"http://{host}:{port}"
failures = []


def request(method, url, headers=None, body=None):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def presto_headers(extra=None):
    headers = {"X-Presto-User": "tablepro", "X-Presto-Source": "TablePro", "Content-Type": "text/plain"}
    headers.update(extra or {})
    return headers


def run(sql, headers=None):
    status, _, body = request("POST", f"{base}/v1/statement", headers or presto_headers(), sql.encode())
    if status != 200:
        return {"httpStatus": status, "body": body.decode(errors="replace")}
    results = json.loads(body)
    rows, columns = [], None
    while True:
        columns = columns or results.get("columns")
        rows += results.get("data") or []
        if results.get("error") or not results.get("nextUri"):
            break
        _, _, body = request("GET", results["nextUri"])
        results = json.loads(body)
    return {"columns": columns, "rows": rows, "error": (results.get("error") or {}).get("message")}


def check(name, passed, detail):
    print(("ok   " if passed else "FAIL ") + name + ": " + json.dumps(detail, default=str)[:600])
    if not passed:
        failures.append(name)


for attempt in range(60):
    try:
        status, _, body = request("GET", f"{base}/v1/info")
        if status == 200 and not json.loads(body).get("starting"):
            break
    except OSError:
        pass
    time.sleep(5)

trino_only = run("SELECT 1", {"X-Trino-User": "tablepro", "Content-Type": "text/plain"})
check("X-Trino- headers carry no user", trino_only.get("httpStatus") == 400 or bool(trino_only.get("error")), trino_only)

check("version() does not exist", "not registered" in (run("SELECT version()").get("error") or ""), "")
node = run("SELECT node_version FROM system.runtime.nodes WHERE coordinator = true")
check("coordinator version from system.runtime.nodes", not node.get("error") and node.get("rows"), node)

catalogs = run("SHOW CATALOGS")
check("SHOW CATALOGS", "system" in [r[0] for r in catalogs.get("rows", [])], catalogs)

check("SHOW SCHEMAS FROM a quoted catalog", not run('SHOW SCHEMAS FROM "system"').get("error"), "")

tables = run(
    'SELECT table_name, table_type FROM "system".information_schema.tables '
    "WHERE table_schema = 'runtime' ORDER BY table_name"
)
check("information_schema.tables", not tables.get("error") and tables.get("rows"), tables)

columns = run(
    "SELECT column_name, data_type, is_nullable, column_default, comment, ordinal_position "
    "FROM \"system\".information_schema.columns WHERE table_schema = 'runtime' AND table_name = 'nodes' "
    "ORDER BY ordinal_position"
)
check("information_schema.columns has comment", not columns.get("error"), columns)

comments = run("SELECT comment FROM system.metadata.table_comments")
check("system.metadata.table_comments is missing", bool(comments.get("error")), comments)

old_views = run("SELECT name FROM system.metadata.materialized_views")
check("system.metadata.materialized_views is missing", bool(old_views.get("error")), old_views)

views = run(
    'SELECT table_name FROM "system".information_schema.materialized_views WHERE table_schema = \'runtime\''
)
check("information_schema.materialized_views", not views.get("error"), views)

values = "SELECT x FROM (VALUES 1, 2, 3) AS t(x) ORDER BY x"
check("OFFSET FETCH NEXT is a syntax error", bool(run(values + " OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY").get("error")), "")
check("LIMIT then OFFSET is a syntax error", bool(run(values + " LIMIT 1 OFFSET 1").get("error")), "")
offset = run(values + " OFFSET 1 ROWS LIMIT 1")
check("OFFSET is off by default", "not enabled" in (offset.get("error") or ""), offset)
check("LIMIT alone runs", run(values + " LIMIT 2").get("rows") == [[1], [2]], "")
check("FETCH FIRST runs", run(values + " FETCH FIRST 2 ROWS ONLY").get("rows") == [[1], [2]], "")

for prefix in ["EXPLAIN", "EXPLAIN (TYPE DISTRIBUTED)", "EXPLAIN (TYPE IO)", "EXPLAIN (TYPE VALIDATE)", "EXPLAIN ANALYZE"]:
    check(prefix, not run(prefix + " " + values).get("error"), "")

stats = run('SHOW STATS FOR "tpch"."tiny"."nation"')
summary = [r for r in stats.get("rows", []) if r[0] is None]
check("SHOW STATS row_count is the fifth column", bool(summary) and summary[0][4] == 25, stats)
browse = run('SELECT * FROM "tpch"."tiny"."nation" LIMIT 10')
check("browse with LIMIT", len(browse.get("rows", [])) == 10, browse.get("error"))
session_offset = run(values + " OFFSET 1 ROWS LIMIT 1", presto_headers({"X-Presto-Session": "offset_clause_enabled=true"}))
check("offset_clause_enabled turns OFFSET on", session_offset.get("rows") == [[2]], session_offset)
check("COMMENT ON TABLE is a syntax error", bool(run("COMMENT ON TABLE system.runtime.nodes IS 'x'").get("error")), "")

capability = run("SELECT 1", presto_headers({"X-Presto-Client-Capabilities": "PARAMETRIC_DATETIME"}))
check("an unknown capability header is ignored", capability.get("rows") == [[1]], capability)

typed = run(
    "SELECT TIMESTAMP '2024-01-02 03:04:05.123456', CAST('ab' AS varbinary), ARRAY[1, 2], JSON '{\"a\":1}', "
    "MAP(ARRAY['k'], ARRAY[1]), CAST(ROW(1, 'x') AS ROW(a integer, b varchar)), ARRAY[ARRAY['y']]"
)
check("type names and values", not typed.get("error"), [typed.get("rows"), [c["type"] for c in typed.get("columns") or []]])

session = run("SELECT 1", presto_headers({"X-Presto-Catalog": "system", "X-Presto-Schema": "runtime"}))
check("catalog and schema headers", session.get("rows") == [[1]], session)

status, _, body = request(
    "POST", f"{base}/v1/statement", presto_headers(),
    b"SELECT count(*) FROM tpch.sf100000.lineitem",
)
results = json.loads(body)
query_id, next_uri = results["id"], results["nextUri"]
for _ in range(3):
    _, _, body = request("GET", next_uri)
    next_uri = json.loads(body).get("nextUri") or next_uri
cancel_status, _, _ = request("DELETE", next_uri)
state = {}
for _ in range(20):
    state = run(f"SELECT state FROM system.runtime.queries WHERE query_id = '{query_id}'")
    if state.get("rows") and state["rows"][0][0] in ("FAILED", "FINISHED"):
        break
    time.sleep(1)
final_state = (state.get("rows") or [[None]])[0][0]
check("DELETE on nextUri cancels", cancel_status == 204 and final_state == "FAILED", [cancel_status, state])

print("FAILED: " + ", ".join(failures) if failures else "all checks passed")
sys.exit(1 if failures else 0)
PY
