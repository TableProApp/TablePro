#!/usr/bin/env bash
#
# Compare the curated Redis routing table against a real server.
#
# RedisCommandRouting builds its table from the server's own COMMAND answer at connect, so the
# curated table in RedisCommandRouting.swift is only a fallback: it serves Redis 6, which reports
# no command tips, and ACL-restricted users, who are refused COMMAND. That makes it a hand-written
# list that has to agree with Redis and that nothing else checks, which is exactly the shape that
# drifts silently. A wrong entry there sends DBSIZE, KEYS or FLUSHDB to one shard of a cluster, or
# hashes a key on the wrong argument and reaches the wrong one.
#
# Usage:
#   scripts/check-redis-command-routing.sh [host] [port]
#
# Needs redis-cli and a reachable Redis 7 or newer, since earlier servers report no tips to
# compare against. Exits non-zero on a disagreement.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-6379}"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Plugins/RedisDriverPlugin/RedisCommandRouting.swift"

command -v redis-cli > /dev/null || {
    echo "redis-cli not found" >&2
    exit 3
}
[ -f "$SOURCE" ] || {
    echo "not found: $SOURCE" >&2
    exit 3
}

if ! redis-cli -h "$HOST" -p "$PORT" ping > /dev/null 2>&1; then
    echo "no Redis at $HOST:$PORT" >&2
    exit 3
fi

VERSION="$(redis-cli -h "$HOST" -p "$PORT" info server | tr -d '\r' | awk -F: '/^redis_version:/ {print $2}')"
case "$VERSION" in
    [1-6].*)
        echo "Redis $VERSION reports no command tips; run this against 7.0 or newer." >&2
        exit 3
        ;;
esac

echo "Checking the curated table against Redis $VERSION at $HOST:$PORT"

redis-cli --json -h "$HOST" -p "$PORT" command > /tmp/redis-command-table.json || {
    echo "COMMAND was refused; the user's ACL has to allow it for this check" >&2
    exit 3
}

python3 - "$SOURCE" /tmp/redis-command-table.json <<'PY'
import json
import re
import sys

source = open(sys.argv[1]).read()
table = source[source.index("static let curated"):]

CAMEL = {
    "allNodes": "all_nodes", "allShards": "all_shards", "multiShard": "multi_shard",
    "special": "special", "oneSucceeded": "one_succeeded", "allSucceeded": "all_succeeded",
    "aggLogicalAnd": "agg_logical_and", "aggLogicalOr": "agg_logical_or",
    "aggMin": "agg_min", "aggMax": "agg_max", "aggSum": "agg_sum",
}


def policies(text):
    request = re.search(r'request:\s*\.(\w+)', text)
    response = re.search(r'response:\s*\.(\w+)', text)
    return (
        CAMEL.get(request.group(1)) if request else None,
        CAMEL.get(response.group(1)) if response else None,
    )


curated = {}

# This parses Swift with regular expressions, which works until somebody reformats the table.
# The dangerous shape is a partial parse: 115 of the 151 entries live inside `for name in [...]`
# blocks, so a change to how those are written drops three quarters of the table and the check
# still reports that the curated list matches the server. Both counts are therefore asserted
# against the source before anything is compared.
# Every add(spec(...)) call in the source must be accounted for by exactly one parsed construct,
# either a direct entry or a `for name in [...]` block. Counting the blocks alone is not enough:
# renaming the loop variable makes both the expectation and the match zero, and the check would
# sail past having lost three quarters of the table.
expected_calls = len(re.findall(r'add\(spec\(', table))
expected_direct = len(re.findall(r'add\(spec\(\s*"', table))

# add(spec("name", first, last, step, ...))
for match in re.finditer(r'spec\(\s*"([^"]+)",\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)([^)]*)\)', table):
    name, first, last, step, rest = match.groups()
    request, response = policies(rest)
    curated[name] = {
        "firstKey": int(first), "lastKey": int(last), "step": int(step),
        "readOnly": "readOnly: true" in rest, "movable": "movable: true" in rest,
        "request": request, "response": response,
    }

if len(curated) != expected_direct:
    sys.exit(
        f"parsed {len(curated)} direct spec() entries but the source has {expected_direct}; "
        "the parser and RedisCommandRouting.swift have diverged"
    )

# for name in [...] { add(spec(name, first, last, step, ...)) }
blocks = re.findall(r'for name in \[(.*?)\]\s*\{\s*add\(spec\(name,\s*(.*?)\)\)', table, re.S)
if len(curated) + len(blocks) != expected_calls:
    sys.exit(
        f"accounted for {len(curated)} direct entries and {len(blocks)} loop blocks, "
        f"but the source makes {expected_calls} add(spec(...)) calls; "
        "the parser and RedisCommandRouting.swift have diverged"
    )

for block, values in blocks:
    parts = values.split(",")
    positions = [int(p.strip()) for p in parts[:3]]
    rest = ",".join(parts[3:])
    request, response = policies(rest)
    for name in re.findall(r'"([^"]+)"', block):
        curated.setdefault(name, {
            "firstKey": positions[0], "lastKey": positions[1], "step": positions[2],
            "readOnly": "readOnly: true" in rest, "movable": "movable: true" in rest,
            "request": request, "response": response,
        })

if not curated:
    sys.exit("could not parse any curated entries")

server = {}


def collect(entry, container=None):
    if not isinstance(entry, list) or len(entry) < 6 or not isinstance(entry[0], str):
        return
    name = f"{container}|{entry[0].lower().split('|')[-1]}" if container else entry[0].lower()
    flags = {str(f).lower() for f in (entry[2] or [])}
    tips = [str(t) for t in (entry[7] or [])] if len(entry) > 7 else []
    server[name] = {
        "firstKey": entry[3], "lastKey": entry[4], "step": entry[5],
        "readOnly": "readonly" in flags, "movable": "movablekeys" in flags,
        "request": next((t.split(":", 1)[1] for t in tips if t.startswith("request_policy:")), None),
        "response": next((t.split(":", 1)[1] for t in tips if t.startswith("response_policy:")), None),
    }
    for sub in (entry[9] if len(entry) > 9 and entry[9] else []):
        collect(sub, container=name)


for entry in json.load(open(sys.argv[2])):
    collect(entry)

mismatches = []
checked = 0
for name in sorted(curated):
    actual = server.get(name)
    if actual is None:
        continue
    checked += 1
    expected = curated[name]
    for field, label in [
        ("firstKey", "first key"), ("lastKey", "last key"), ("step", "key step"),
        ("readOnly", "readonly"), ("movable", "movablekeys"),
        ("request", "request_policy"), ("response", "response_policy"),
    ]:
        if expected[field] != actual[field]:
            mismatches.append(f"{name}: {label} curated {expected[field]} but server says {actual[field]}")

print(f"compared {checked} commands")
missing = sorted(n for n in curated if n not in server)
if missing:
    print(f"not on this server, so unchecked: {', '.join(missing)}")
if mismatches:
    print()
    for line in mismatches:
        print(f"  {line}")
    print(f"\n{len(mismatches)} disagreement(s)")
    sys.exit(1)
print("the curated table matches the server")
PY
status=$?
rm -f /tmp/redis-command-table.json
exit $status
