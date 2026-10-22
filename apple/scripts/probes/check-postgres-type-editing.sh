#!/usr/bin/env bash
#
# Check PostgreSQLTypeStatements and the rebuilt type definitions against real servers.
#
# The Types editor queues changes and runs the statements this plugin builds. A statement a server
# version refuses, or a change that does not land as the catalog then reports it, only shows on a
# live server. This compiles the statement builders as they are in the tree, runs a create, edit and
# drop of an enum, a composite and a domain the way a save does (one transaction, or each statement
# on its own where the server refuses a label addition in one), checks the catalog after each, and rebuilds every type
# from the definition the viewer shows to confirm it parses back to the same type.
#
# Usage:
#   apple/scripts/probes/check-postgres-type-editing.sh host:port [host:port...]
#
# Each server needs a `postgres` superuser; PGPASSWORD is passed through. For example:
#   for v in 13 14 15 16 17 18; do docker run -d --name pg$v -e POSTGRES_PASSWORD=pw -p 0:5432 postgres:$v-alpine; done
# Exits non-zero on a disagreement, 3 when a prerequisite is missing.

set -uo pipefail

[ $# -ge 1 ] || {
    echo "usage: $0 host:port [host:port...]" >&2
    exit 3
}
command -v psql > /dev/null || {
    echo "psql not found" >&2
    exit 3
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p)"
    case "$DEVELOPER_DIR" in
        *CommandLineTools*) DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
    esac
fi
export DEVELOPER_DIR

mkdir -p "$WORK/src"
for file in \
    Plugins/TableProPluginKit/PluginUserDefinedTypeInfo.swift \
    Plugins/TableProPluginKit/PluginUserDefinedTypeChange.swift \
    Plugins/TableProPluginKit/PluginObjectAttribute.swift \
    Plugins/TableProPluginKit/PluginCellValue.swift \
    Plugins/TableProPluginKit/ArrayExtension.swift \
    Plugins/TableProPluginKit/PostgresArrayLiteralCodec.swift \
    Plugins/PostgreSQLDriverPlugin/PostgreSQLObjectQueries.swift \
    Plugins/PostgreSQLDriverPlugin/PostgreSQLTypeDefinition.swift \
    Plugins/PostgreSQLDriverPlugin/PostgreSQLTypeStatements.swift \
    Plugins/PostgreSQLDriverPlugin/PostgreSQLTextArray.swift \
    Packages/TableProCore/Sources/TableProPostgreSQLCore/PostgreSQLCapabilities.swift \
    Packages/TableProCore/Sources/TableProPostgreSQLCore/PostgreSQLCatalogBoolean.swift; do
    sed -e '/^import TableProPluginKit$/d' -e '/^import TableProPostgreSQLCore$/d' "$ROOT/$file" > "$WORK/src/$(basename "$file")"
done

cat > "$WORK/src/main.swift" << 'SWIFT'
import Foundation

func emit(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value)
    print(String(decoding: data, as: UTF8.self))
}

let arguments = CommandLine.arguments
switch arguments[1] {
case "catalog":
    let capabilities = PostgreSQLCapabilities(serverVersion: Int32(arguments[3])!)
    print(PostgreSQLObjectQueries.userDefinedTypeList(schema: arguments[2], identity: nil, capabilities: capabilities))
case "rebuild":
    let rows = try! JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[Any]]
    let ddl = rows.compactMap { row -> String? in
        let cells = row.map { ($0 as? String).map(PluginCellValue.text) ?? .null }
        return PostgreSQLTypeDefinition.record(from: cells).map(PostgreSQLTypeDefinition.ddl(for:))
    }
    emit(ddl)
default:
    let schema = arguments[2]
    let capabilities = PostgreSQLCapabilities(serverVersion: Int32(arguments[3])!)
    func type(_ name: String, _ kind: PluginUserDefinedTypeKind) -> PluginUserDefinedTypeInfo {
        PluginUserDefinedTypeInfo(name: name, kind: kind, schema: schema)
    }
    func save(_ label: String, _ target: PluginUserDefinedTypeInfo, _ changes: [PluginUserDefinedTypeChange], refusal: String? = nil) -> [String: Any] {
        let statements = changes.flatMap {
            PostgreSQLTypeStatements.alter(type: target, schema: schema, change: $0, capabilities: capabilities)!
        }
        return [
            "label": label,
            "statements": statements,
            "transaction": !changes.contains { PostgreSQLTypeStatements.runsOutsideTransaction($0, capabilities: capabilities) },
            "refusal": refusal as Any
        ]
    }
    func create(_ label: String, _ definition: PluginUserDefinedTypeDefinition) -> [String: Any] {
        ["label": label, "statements": PostgreSQLTypeStatements.create(definition, schema: schema)!, "transaction": true, "refusal": NSNull()]
    }
    let mood = type("mood", .enumeration)
    let address = type("address", .composite)
    let posint = type("posint", .domain)
    let after = PluginEnumLabelPlacement(anchor: "ok", placesBefore: false)
    let before = PluginEnumLabelPlacement(anchor: "sad", placesBefore: true)
    let small = PluginUserDefinedTypeCheck(name: "small", expression: "VALUE < 100")
    emit([
        create("create enum", PluginUserDefinedTypeDefinition(
            name: "mood", schema: schema, kind: .enumeration, enumLabels: ["sad", "ok"], comment: "feelings"
        )),
        create("create composite", PluginUserDefinedTypeDefinition(
            name: "address", schema: schema, kind: .composite,
            fields: [PluginUserDefinedTypeField(name: "street", type: "text"), PluginUserDefinedTypeField(name: "zip", type: "integer")]
        )),
        create("create domain", PluginUserDefinedTypeDefinition(
            name: "posint", schema: schema, kind: .domain, baseType: "integer", defaultValue: "1", isNotNull: true,
            checks: [PluginUserDefinedTypeCheck(name: "positive", expression: "VALUE > 0")]
        )),
        save("edit enum", mood, [
            .addEnumLabel("glad", placement: after),
            .addEnumLabel("meh", placement: before),
            .renameEnumLabel(from: "ok", to: "fine"),
            .setComment("moods"),
            .rename(to: "feeling")
        ]),
        save("edit composite", address, [
            .addField(PluginUserDefinedTypeField(name: "city", type: "text")),
            .renameField(from: "zip", to: "postcode"),
            .changeFieldType(field: "postcode", type: "bigint"),
            .dropField("street"),
            .setComment(nil),
            .rename(to: "addr2")
        ]),
        save("refused domain check", posint, [
            .setDefault("2"),
            .setNotNull(false),
            .addCheck(small, validatesExistingValues: true)
        ], refusal: "violate"),
        save("edit domain", posint, [
            .setDefault("2"),
            .setNotNull(false),
            .addCheck(small, validatesExistingValues: false)
        ]),
        save("refused validation", posint, [.validateConstraint("small")], refusal: "violate"),
        save("drop check", posint, [.dropConstraint("positive")]),
        save("rename domain", posint, [.rename(to: "counter")]),
        ["label": "drop enum", "statements": [
            PostgreSQLTypeStatements.drop(schema: schema, name: "feeling", kind: .enumeration, cascade: true)
        ], "transaction": true, "refusal": NSNull()],
        ["label": "drop composite", "statements": [
            PostgreSQLTypeStatements.drop(schema: schema, name: "addr2", kind: .composite, cascade: false)
        ], "transaction": true, "refusal": NSNull()]
    ])
}
SWIFT

xcrun swiftc -swift-version 6 -module-name TypeProbe -o "$WORK/probe" "$WORK"/src/*.swift > "$WORK/build.log" 2>&1 || {
    echo "the probe failed to build:" >&2
    grep -E 'error:' "$WORK/build.log" | sort -u | head -20 >&2
    exit 3
}

PROBE="$WORK/probe" python3 -I - "$@" << 'PYTHON'
import json, os, subprocess, sys

probe = os.environ["PROBE"]
database = "tablepro_type_editing_probe"
schema = "probe"
failures = []

def psql(endpoint, db, sql, check=True):
    host, port = endpoint.rsplit(":", 1)
    result = subprocess.run(
        ["psql", "-X", "-q", "-At", "-h", host, "-p", port, "-U", "postgres", "-d", db, "-v", "ON_ERROR_STOP=1"],
        input=sql, capture_output=True, text=True,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    return result

def one(endpoint, sql):
    return psql(endpoint, database, sql).stdout.strip()

def expect(endpoint, label, sql, wanted):
    got = one(endpoint, sql)
    if got != wanted:
        failures.append(f"{endpoint} {label}: {sql!r} gave {got!r}, wanted {wanted!r}")

def rows_as_lists(endpoint, version):
    query = subprocess.run([probe, "catalog", schema, version], capture_output=True, text=True, check=True).stdout
    text = one(endpoint, f"SELECT coalesce(json_agg(row_to_json(q)), '[]') FROM ({query}) q;")
    return [list(row.values()) for row in json.loads(text, object_pairs_hook=lambda pairs: dict(pairs))]

for endpoint in sys.argv[1:]:
    try:
        psql(endpoint, "postgres", f"DROP DATABASE IF EXISTS {database};")
        psql(endpoint, "postgres", f"CREATE DATABASE {database};")
    except RuntimeError as error:
        print(f"{endpoint}: cannot reach the server: {error}", file=sys.stderr)
        sys.exit(3)
    version = one(endpoint, "SHOW server_version_num;")
    print(f"PostgreSQL {one(endpoint, 'SHOW server_version;')} at {endpoint}")
    one(endpoint, f"CREATE SCHEMA {schema};")
    steps = json.loads(subprocess.run([probe, "steps", schema, version], capture_output=True, text=True, check=True).stdout)

    for step in steps:
        statements = [s + ";" for s in step["statements"]]
        body = "\n".join(statements)
        if step["transaction"]:
            body = "BEGIN;\n" + body + "\nCOMMIT;"
        result = psql(endpoint, database, body, check=False)
        refusal = step["refusal"]
        if refusal is None and result.returncode != 0:
            failures.append(f"{endpoint} {step['label']}: refused: {result.stderr.strip()}")
        elif refusal is not None and (result.returncode == 0 or refusal not in result.stderr):
            failures.append(f"{endpoint} {step['label']}: wanted a refusal naming {refusal!r}, got {result.stderr.strip()!r}")
        label = step["label"]

        if label == "create domain":
            one(endpoint, f"CREATE TABLE {schema}.t (v {schema}.posint, m {schema}.mood); INSERT INTO {schema}.t VALUES (150, 'ok');")
            expect(endpoint, label, f"SELECT obj_description('{schema}.mood'::regtype, 'pg_type');", "feelings")
        elif label == "edit enum":
            expect(endpoint, label, f"SELECT enum_range(NULL::{schema}.feeling)::text;", "{meh,sad,fine,glad}")
            expect(endpoint, label, f"SELECT obj_description('{schema}.feeling'::regtype, 'pg_type');", "moods")
        elif label == "edit composite":
            expect(endpoint, label,
                   f"SELECT string_agg(attname || ' ' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum) "
                   f"FROM pg_attribute WHERE attrelid = '{schema}.addr2'::regclass AND attnum > 0 AND NOT attisdropped;",
                   "postcode bigint, city text")
            expect(endpoint, label, f"SELECT coalesce(obj_description('{schema}.addr2'::regtype, 'pg_type'), '<none>');", "<none>")
        elif label == "refused domain check":
            expect(endpoint, label, f"SELECT typdefault || ' ' || typnotnull FROM pg_type WHERE oid = '{schema}.posint'::regtype;", "1 true")
            expect(endpoint, label, f"SELECT count(*) FROM pg_constraint WHERE contypid = '{schema}.posint'::regtype AND conname = 'small';", "0")
        elif label == "edit domain":
            expect(endpoint, label, f"SELECT typdefault || ' ' || typnotnull FROM pg_type WHERE oid = '{schema}.posint'::regtype;", "2 false")
            expect(endpoint, label, f"SELECT convalidated FROM pg_constraint WHERE contypid = '{schema}.posint'::regtype AND conname = 'small';", "f")
        elif label == "refused validation":
            expect(endpoint, label, f"SELECT convalidated FROM pg_constraint WHERE contypid = '{schema}.posint'::regtype AND conname = 'small';", "f")
        elif label == "drop check":
            expect(endpoint, label, f"SELECT string_agg(conname, ',') FROM pg_constraint WHERE contypid = '{schema}.posint'::regtype AND contype = 'c';", "small")
        elif label == "rename domain":
            expect(endpoint, label, f"SELECT to_regtype('{schema}.counter') IS NOT NULL AND to_regtype('{schema}.posint') IS NULL;", "t")
            before = rows_as_lists(endpoint, version)
            ddl = json.loads(subprocess.run([probe, "rebuild"], input=json.dumps(before), capture_output=True, text=True, check=True).stdout)
            one(endpoint, f"DROP TABLE {schema}.t; DROP SCHEMA {schema} CASCADE; CREATE SCHEMA {schema};")
            rebuilt = psql(endpoint, database, "\n".join(ddl), check=False)
            if rebuilt.returncode != 0:
                failures.append(f"{endpoint} rebuild: the shown definitions did not run: {rebuilt.stderr.strip()}")
            after = rows_as_lists(endpoint, version)
            # identity (0), owner (4) and comment (5) are not part of a definition
            def shape(rows):
                return [[cell for index, cell in enumerate(row) if index not in (0, 4, 5)] for row in rows]
            if shape(before) != shape(after):
                failures.append(f"{endpoint} rebuild: the catalog differs after running the shown definitions:\n  {shape(before)}\n  {shape(after)}")
            one(endpoint, f"CREATE TABLE {schema}.t (v {schema}.counter, m {schema}.feeling);")
        elif label == "drop enum":
            expect(endpoint, label, f"SELECT string_agg(attname, ',') FROM pg_attribute WHERE attrelid = '{schema}.t'::regclass AND attnum > 0 AND NOT attisdropped;", "v")
        elif label == "drop composite":
            expect(endpoint, label, f"SELECT to_regtype('{schema}.addr2') IS NULL;", "t")

    psql(endpoint, "postgres", f"DROP DATABASE IF EXISTS {database};", check=False)

if failures:
    print("\n".join(failures))
    sys.exit(1)
print("Every change landed as the catalog reports it, and every shown definition rebuilt the same type.")
PYTHON
