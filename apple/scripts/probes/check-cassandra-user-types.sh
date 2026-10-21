#!/usr/bin/env bash
#
# Check CassandraUserTypes against a live server: the rebuilt CREATE TYPE round-trips, the
# column picker's spelling is accepted and recorded as spelled, the bare name is refused exactly
# where the spelling says frozen, DROP TYPE is refused while a table uses the type, and the
# hard-coded reserved keywords cover the server's own list.
#
# Usage:
#   apple/scripts/probes/check-cassandra-user-types.sh [container]
#
# Needs Docker and a Cassandra container, by default named cassandra-probe:
#   docker run -d --name cassandra-probe -e MAX_HEAP_SIZE=768M -e HEAP_NEWSIZE=128M cassandra:5.0
# Exits non-zero on a disagreement, 3 when a prerequisite is missing.

set -uo pipefail

CONTAINER="${1:-cassandra-probe}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="$ROOT/Plugins/CassandraDriverPlugin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v docker > /dev/null || { echo "docker not found" >&2; exit 3; }
docker exec "$CONTAINER" cqlsh -e "SELECT release_version FROM system.local" > /dev/null 2>&1 || {
    echo "no Cassandra answering cqlsh in container $CONTAINER" >&2
    exit 3
}
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p)"
    case "$DEVELOPER_DIR" in
        *CommandLineTools*) DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
    esac
fi
export DEVELOPER_DIR

cat > "$WORK/main.swift" << 'SWIFT'
import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
let rows = (try JSONSerialization.jsonObject(with: input) as? [[String: String]]) ?? []
let types: [[String: Any]] = rows.map { row in
    let name = row["name"] ?? ""
    let keyspace = row["keyspace"] ?? ""
    let fields = CassandraUserTypes.fields(names: row["names"], types: row["types"])
    return [
        "name": name,
        "definition": fields.map { CassandraUserTypes.definition(keyspace: keyspace, name: name, fields: $0) as Any }
            ?? NSNull(),
        "spelling": CassandraUserTypes.columnTypeSpelling(name: name, fields: fields, releaseVersion: row["release"]),
        "bare": CassandraUserTypes.identifier(name),
        "drop": CassandraUserTypes.dropStatement(keyspace: keyspace, name: name),
    ]
}
let output: [String: Any] = ["types": types, "reserved": CassandraUserTypes.reservedKeywords.sorted()]
let data = try JSONSerialization.data(withJSONObject: output)
print(String(decoding: data, as: UTF8.self))
SWIFT
xcrun swiftc -o "$WORK/spell" "$WORK/main.swift" "$PLUGIN/CassandraObjectQueries.swift" "$PLUGIN/CassandraUserTypes.swift" \
    > "$WORK/build.log" 2>&1 || {
    echo "the probe failed to build:" >&2
    grep -E 'error:' "$WORK/build.log" | sort -u | head -20 >&2
    exit 3
}

docker cp "$CONTAINER:/opt/cassandra/lib/." "$WORK/lib" > /dev/null 2>&1
JAR="$(ls "$WORK"/lib/apache-cassandra-[0-9]*.jar 2> /dev/null | head -1)"
SERVER_RESERVED=""
if [ -n "$JAR" ]; then
    SERVER_RESERVED="$(unzip -p "$JAR" org/apache/cassandra/cql3/reserved_keywords.txt 2> /dev/null)"
fi

CONTAINER="$CONTAINER" SPELL="$WORK/spell" SERVER_RESERVED="$SERVER_RESERVED" RUN_ID="$$" python3 -I - << 'PYTHON'
import json, os, subprocess, sys

container = os.environ["CONTAINER"]
source = "tp_udt_src_" + os.environ["RUN_ID"]
target = "tp_udt_dst_" + os.environ["RUN_ID"]
failures = []


def cql(statement):
    run = subprocess.run(["docker", "exec", container, "cqlsh", "-e", statement], capture_output=True, text=True)
    return run.returncode == 0 and "Error" not in run.stderr, (run.stdout + run.stderr).strip()


def rows(statement):
    ok, out = cql(statement)
    if not ok:
        sys.exit("read failed: " + out)
    # cqlsh prints a backslash in a text value doubled.
    return [json.loads(line.strip().replace("\\\\", "\\"))
            for line in out.splitlines() if line.strip().startswith("{")]


def driver_list(values):
    return "[" + ", ".join(values) + "]"


def check(condition, message):
    if not condition:
        failures.append(message)


replication = "{'class': 'SimpleStrategy', 'replication_factor': 1}"
try:
    for keyspace in (source, target):
        cql(f"CREATE KEYSPACE {keyspace} WITH replication = {replication}")
    fixture = [
        "CREATE TYPE {k}.address (street text, city text)",
        "CREATE TYPE {k}.phone (kind text, number text)",
        "CREATE TYPE {k}.contact (home frozen<address>, phones list<frozen<phone>>, tags set<text>, extra map<text, int>)",
        "CREATE TYPE {k}.\"MixedCase\" (a int, \"Quoted Field\" text)",
        "CREATE TYPE {k}.\"select\" (a int)",
        "CREATE TYPE {k}.ref (m frozen<\"MixedCase\">, s frozen<\"select\">)",
        "CREATE TYPE {k}.\"weird\" (\"a, b\" int, c text)",
        "CREATE TYPE {k}.odd (\"customer'\" text, \" padded \" int, \"say \"\"hi\"\"\" text)",
        "CREATE TYPE {k}.commas (\"a,b\" int, c text)",
        "CREATE TYPE {k}.angles (\"a<\" int, \"b>\" text)",
        "CREATE TYPE {k}.\"My, Type\" (v int)",
        "CREATE TYPE {k}.uses_comma (m frozen<\"My, Type\">, n int)",
        "CREATE TYPE {k}.\"text\" (v int)",
        "CREATE TYPE {k}.\"byte\" (v int)",
    ]
    for statement in fixture:
        ok, out = cql(statement.format(k=source))
        if not ok:
            sys.exit("fixture failed: " + out)
    if not cql(f"CREATE TYPE {source}.withfrozen (tags frozen<set<text>>, pair tuple<int, text>, v vector<float, 3>)")[0]:
        cql(f"CREATE TYPE {source}.withfrozen (tags frozen<set<text>>, pair tuple<int, text>)")

    release = rows("SELECT JSON release_version FROM system.local")[0]["release_version"]
    listed = {row["type_name"]: row for row in rows(
        f"SELECT JSON type_name, field_names, field_types FROM system_schema.types WHERE keyspace_name = '{source}'")}
    request = [{
        "name": name,
        "keyspace": target,
        "names": driver_list(row["field_names"]),
        "types": driver_list(row["field_types"]),
        "release": release,
    } for name, row in listed.items()]
    spelled = subprocess.run([os.environ["SPELL"]], input=json.dumps(request), capture_output=True, text=True, check=True)
    output = json.loads(spelled.stdout)
    built = {entry["name"]: entry for entry in output["types"]}
    print(f"Cassandra {release}: {len(built)} types")

    check(built["weird"]["definition"] is None, "a field name holding ', ' still produced a definition")
    for name, entry in built.items():
        check(entry["definition"] or name == "weird", f"{name}: no definition")
    check(built["weird"]["spelling"].startswith("frozen<"), "a type with unreadable fields was not spelled frozen")

    pending = [name for name in built if built[name]["definition"]]
    for _ in range(len(pending)):
        pending = [name for name in pending if not cql(built[name]["definition"])[0]]
    check(not pending, f"rebuilt definitions refused: {pending}")
    rebuilt = {row["type_name"]: row for row in rows(
        f"SELECT JSON type_name, field_names, field_types FROM system_schema.types WHERE keyspace_name = '{target}'")}
    for name, entry in built.items():
        if not entry["definition"]:
            continue
        original, copy = listed[name], rebuilt.get(name)
        check(copy is not None and copy["field_names"] == original["field_names"]
              and copy["field_types"] == original["field_types"],
              f"{name}: rebuilt as {copy} from {original}")

    cql(f"CREATE TABLE {source}.holder (id int PRIMARY KEY)")
    for index, (name, entry) in enumerate(sorted(built.items())):
        ok, out = cql(f"ALTER TABLE {source}.holder ADD c{index} {entry['spelling']}")
        check(ok, f"{name}: picker spelling {entry['spelling']} refused: {out}")
        recorded = rows(f"SELECT JSON type FROM system_schema.columns WHERE keyspace_name = '{source}' "
                        f"AND table_name = 'holder' AND column_name = 'c{index}'")
        if name in ("text", "byte"):
            # system_schema records a UDT called "text" as text, so only a UDT literal tells it from the native type.
            ok, out = cql(f"INSERT INTO {source}.holder (id, c{index}) VALUES ({index}, {{v: 1}})")
            check(ok, f"{name}: spelled {entry['spelling']}, the column is not the type: {out}")
        else:
            check(recorded and recorded[0]["type"] == entry["spelling"],
                  f"{name}: spelled {entry['spelling']}, recorded {recorded}")
        if entry["spelling"].startswith("frozen<"):
            ok, out = cql(f"ALTER TABLE {source}.holder ADD b{index} {entry['bare']}")
            check(not ok or name == "weird", f"{name}: spelled frozen, yet the bare name was accepted")

    ok, out = cql(built["phone"]["drop"])
    check(not ok and "still used" in out, f"DROP of a type another type uses was not refused: {out}")
    ok, out = cql(built["ref"]["drop"])
    check(ok, f"DROP of an unused type failed: {out}")
    cql(f"CREATE TABLE {target}.holder (id int PRIMARY KEY, m frozen<\"MixedCase\">)")
    ok, out = cql(built["MixedCase"]["drop"])
    check(not ok and "still used" in out, f"DROP of a type a table uses was not refused: {out}")
    cql(f"DROP TABLE {target}.holder")
    ok, out = cql(built["MixedCase"]["drop"])
    check(ok, f"DROP of a quoted name failed once nothing used it: {out}")

    server_reserved = set(os.environ["SERVER_RESERVED"].split())
    if server_reserved:
        missing = sorted(server_reserved - set(output["reserved"]))
        check(not missing, f"reserved keywords the code does not quote: {missing}")
    else:
        print("reserved_keywords.txt not found in the server jar, skipped")
finally:
    for keyspace in (source, target):
        cql(f"DROP KEYSPACE IF EXISTS {keyspace}")

for failure in failures:
    print("FAIL " + failure)
print("PASS" if not failures else f"{len(failures)} disagreement(s)")
sys.exit(1 if failures else 0)
PYTHON
