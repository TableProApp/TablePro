#!/usr/bin/env python3
"""Record the real HydraDB Bolt compatibility surface on a disposable graph."""

import argparse
import base64
import json
import os
import time
import urllib.error
import urllib.request

from neo4j import GraphDatabase, READ_ACCESS
from neo4j.exceptions import Neo4jError
from neo4j.graph import Node, Relationship


def json_value(value):
    if isinstance(value, Node):
        return {"element_id": value.element_id, "labels": sorted(value.labels), "properties": dict(value)}
    if isinstance(value, Relationship):
        return {"element_id": value.element_id, "type": value.type, "properties": dict(value),
                "start": value.start_node.element_id, "end": value.end_node.element_id}
    return repr(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uri", default="bolt://127.0.0.1:17687")
    parser.add_argument("--database", default="default")
    parser.add_argument("--seed", action="store_true")
    parser.add_argument("--require-metadata", action="store_true")
    parser.add_argument("--require-entities", action="store_true")
    parser.add_argument("--scale", type=int, default=0, choices=[0, 100, 1002, 10000])
    parser.add_argument("--parallel-check", action="store_true")
    args = parser.parse_args()
    if args.require_metadata and not args.seed:
        parser.error("--require-metadata requires --seed on a fresh disposable graph")
    if args.scale and not args.seed:
        parser.error("--scale requires --seed on a fresh disposable graph")
    token = os.environ["HYDRADB_PROBE_TOKEN"]
    results = []

    def record(name, query, *, database=None, mode=None, parameters=None):
        started = time.monotonic()
        config = {"database": database or args.database}
        if mode:
            config["default_access_mode"] = mode
        result = {"name": name, "query": query}
        try:
            with driver.session(**config) as session:
                response = session.run(query, parameters or {})
                result["columns"] = response.keys()
                result["rows"] = [dict(row) for row in response]
                response.consume()
            result["status"] = "accepted"
        except Neo4jError as error:
            result.update(status="rejected", code=error.code, message=error.message)
        result["elapsed_ms"] = round((time.monotonic() - started) * 1000, 2)
        results.append(result)
        print(json.dumps(result, default=json_value), flush=True)
        return result

    with GraphDatabase.driver(args.uri, auth=("tablepro-probe", token),
                              connection_timeout=10, max_transaction_retry_time=0) as driver:
        driver.verify_connectivity()
        if args.seed:
            if os.environ.get("HYDRADB_PROBE_DISPOSABLE") != "1":
                raise SystemExit("Seeding requires HYDRADB_PROBE_DISPOSABLE=1")
            existing = record("fixture-empty", "MATCH (n:TableProProbe) RETURN count(*) AS count")
            if existing.get("rows") != [{"count": 0}]:
                raise SystemExit("Refusing to seed a nonempty or unverifiable fixture")
            seeded = record("seed", "CREATE (a:TableProProbe {id: 1, name: 'Ann', age: 30})"
                            "-[:TABLEPRO_KNOWS {since: 2020}]->"
                            "(b:TableProProbe {id: 2, name: 'Bo'})")
            if seeded["status"] != "accepted":
                raise SystemExit("Fixture creation failed")

        ping = record("ping", "RETURN 1")
        record("database-info", "CALL db.info() YIELD name RETURN name")
        labels = record("labels", "CALL db.labels() YIELD label RETURN label ORDER BY label")
        types = record("relationship-types", "CALL db.relationshipTypes() YIELD relationshipType "
               "RETURN relationshipType ORDER BY relationshipType")
        record("property-discovery", "MATCH (n:TableProProbe) WITH n LIMIT 1000 "
               "UNWIND keys(n) AS key RETURN key, head(collect(n[key])) AS sample ORDER BY key")
        record("scalar-browse", "MATCH (n:TableProProbe) RETURN n.id AS id, n.name AS name "
               "ORDER BY n.id SKIP 0 LIMIT 100")
        record("node-labels", "MATCH (n:TableProProbe) RETURN n.id AS id, labels(n) AS labels")
        entities = record("entity-browse", "MATCH (n:TableProProbe) RETURN n ORDER BY n.id LIMIT 100")
        relationships = record("relationship-entity", "MATCH ()-[r:TABLEPRO_KNOWS]->() RETURN r")
        record("relationship-id", "MATCH (a)-[r:TABLEPRO_KNOWS]->(b) "
               "RETURN r.id AS id, a.id AS start, b.id AS end")
        record("element-id", "MATCH (a)-[r:TABLEPRO_KNOWS]->(b) RETURN elementId(r) AS id")
        record("relationship-scalars", "MATCH (a)-[r:TABLEPRO_KNOWS]->(b) "
               "RETURN a.id AS start, b.id AS end, r.since AS since")
        record("parameter-query", "MATCH (n:TableProProbe) WHERE n.id = $id RETURN n.name AS name",
               parameters={"id": 1})
        record("recovery-after-errors", "MATCH (n:TableProProbe) RETURN count(*) AS count")
        if args.require_entities:
            assert ping.get("rows") == [{"1": 1}], ping
            nodes = [row["n"] for row in entities.get("rows", [])]
            assert len(nodes) == 2 and all(isinstance(node, Node) for node in nodes), entities
            assert [node.element_id for node in nodes] == ["1", "2"], entities
            assert all("TableProProbe" in node.labels for node in nodes), entities
            assert [node["name"] for node in nodes] == ["Ann", "Bo"], entities
            relations = [row["r"] for row in relationships.get("rows", [])]
            assert len(relations) == 1 and isinstance(relations[0], Relationship), relationships
            assert relations[0].start_node.element_id == "1" and relations[0].end_node.element_id == "2", relationships
            assert relations[0].type == "TABLEPRO_KNOWS" and relations[0]["since"] == 2020, relationships

        if args.seed:
            # The mutation touches only the synthetic marker and detects whether mode=r is enforced.
            mode_write = record("read-mode-write", "MATCH (n:TableProProbe) WHERE n.id = 1 "
                   "SET n.read_mode_probe = 1", mode=READ_ACCESS)
            mode_result = record("read-mode-result", "MATCH (n:TableProProbe) WHERE n.id = 1 "
                   "RETURN n.read_mode_probe AS marker")
            component = lambda text: base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")
            scoped = "default.scope1." + component("tablepro-tenant") + "." + component("other")
            empty = "default.scope1." + component("tablepro-tenant") + "." + component("empty")
            record("seed-other-scope", "CREATE (a:TableProOther {id: 1})"
                   "-[:TABLEPRO_OTHER]->(b:TableProOther {id: 9})", database=scoped)
            scoped_labels = record("other-scope-labels", "CALL db.labels()", database=scoped)
            scoped_types = record("other-scope-types", "CALL db.relationshipTypes()", database=scoped)
            empty_labels = record("empty-scope-labels", "CALL db.labels()", database=empty)
            empty_types = record("empty-scope-types", "CALL db.relationshipTypes()", database=empty)
            record("seed-deleted-type", "CREATE (a:TableProDelete {id: 50})"
                   "-[:TABLEPRO_TEMP]->(b:TableProDelete {id: 51})")
            record("delete-last-type-edge", "MATCH (a:TableProDelete)-[r:TABLEPRO_TEMP]->(b) DELETE r")
            after_delete = record("types-after-last-edge-delete", "CALL db.relationshipTypes()")
            if args.require_metadata:
                assert labels.get("rows") == [{"label": "TableProProbe"}], labels
                assert types.get("rows") == [{"relationshipType": "TABLEPRO_KNOWS"}], types
                assert scoped_labels.get("rows") == [{"label": "TableProOther"}], scoped_labels
                assert scoped_types.get("rows") == [{"relationshipType": "TABLEPRO_OTHER"}], scoped_types
                assert empty_labels.get("rows") == [], empty_labels
                assert empty_types.get("rows") == [], empty_types
                assert after_delete.get("rows") == [{"relationshipType": "TABLEPRO_KNOWS"}], after_delete
            if args.scale:
                for begin in range(0, args.scale, 1000):
                    scale = record("seed-scale-" + str(begin), "UNWIND $rows AS row "
                                   "CREATE (a {id: row.src})-[:TABLEPRO_SCALE]->"
                                   "(b {id: row.dst})", parameters={"rows": [
                                       {"src": 1000 + i, "dst": 1001 + i}
                                       for i in range(begin, min(begin + 1000, args.scale), 2)
                                   ]})
                    assert scale["status"] == "accepted", scale
                scale_labels = record("label-scale", "MATCH (a)-[:TABLEPRO_SCALE]->(b) "
                                      "SET a:TableProScale, b:TableProScale")
                assert scale_labels["status"] == "accepted", scale_labels
                scaled_count = record("scale-count", "MATCH (n:TableProScale) RETURN count(*) AS count")
                assert scaled_count.get("rows") == [{"count": args.scale}], scaled_count
                record("seed-rare-label", "MATCH (n:TableProScale) WHERE n.id = $id SET n:TableProRare",
                       parameters={"id": 1000 + args.scale - 1})
                rare_property = record("seed-rare-property", "MATCH (n:TableProScale) WHERE n.id = $id SET n.rare = 'kept'",
                                       parameters={"id": 1000 + args.scale - 1})
                assert rare_property["status"] == "accepted", rare_property
                scaled_labels = record("scale-labels", "CALL db.labels()")
                scaled_types = record("scale-types", "CALL db.relationshipTypes()")
                if args.require_metadata:
                    assert {r["label"] for r in scaled_labels.get("rows", [])} == {
                        "TableProDelete", "TableProProbe", "TableProRare", "TableProScale"}, scaled_labels
                    assert {r["relationshipType"] for r in scaled_types.get("rows", [])} == {
                        "TABLEPRO_KNOWS", "TABLEPRO_SCALE"}, scaled_types
            if args.parallel_check:
                record("seed-parallel", "CREATE (a:TableProProbe {id: 1})"
                       "-[:TABLEPRO_KNOWS {since: 2021}]->(b:TableProProbe {id: 2})")
                parallel = record("parallel-entities", "MATCH ()-[r:TABLEPRO_KNOWS]->() "
                                  "RETURN r ORDER BY elementId(r)")
                edges = [row["r"] for row in parallel.get("rows", [])]
                assert len(edges) == 2 and len({edge.element_id for edge in edges}) == 2, parallel
                assert {edge["since"] for edge in edges} == {2020, 2021}, parallel

    with GraphDatabase.driver(args.uri, auth=("tablepro-probe", token + "-wrong"),
                              connection_timeout=10, max_transaction_retry_time=0) as invalid:
        try:
            invalid.verify_connectivity()
        except Neo4jError as error:
            print(json.dumps({"name": "bad-token", "status": "rejected", "code": error.code}))
        else:
            raise AssertionError("Server accepted an invalid token")

    denied_request = urllib.request.Request(
        "http://127.0.0.1:18443/v1/graphs/default/query",
        data=json.dumps({"cell_id": "cell-0", "query": "CALL db.labels()"}).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                 "X-Graph-Namespace": "tablepro-outside"}, method="POST")
    try:
        urllib.request.urlopen(denied_request, timeout=10).close()
    except urllib.error.HTTPError as error:
        print(json.dumps({"name": "unauthorized-namespace", "status": "rejected", "http": error.code}))
        assert error.code == 403, error.code
    else:
        raise AssertionError("Metadata request escaped the granted namespace")

    print(json.dumps({"summary": {"accepted": sum(r["status"] == "accepted" for r in results),
                                  "rejected": sum(r["status"] == "rejected" for r in results)},
                      "note": "Accepted means executable, not a complete capability pass."}))


if __name__ == "__main__":
    main()
