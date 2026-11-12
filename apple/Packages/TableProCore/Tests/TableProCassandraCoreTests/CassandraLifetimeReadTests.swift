//
//  CassandraLifetimeReadTests.swift
//  TableProCassandraCoreTests
//

import TableProCassandraCore
import Testing

struct CassandraLifetimeReadTests {
    private static let target = "\"shop\".\"visits\""

    @Test("A browse of named columns reads TTL() after them for each one that takes it")
    func namedColumns() throws {
        let layout = try #require(CassandraTableLayoutTests.visits())
        let plan = try #require(CassandraLifetimeRead.plan(
            cql: "SELECT \"id\", \"day\", \"note\", \"tags\" FROM \"shop\".\"visits\" WHERE \"note\" = ? ALLOW FILTERING",
            target: Self.target,
            layout: layout
        ))
        #expect(plan.cql
            == "SELECT \"id\", \"day\", \"note\", \"tags\", TTL(\"note\") FROM \"shop\".\"visits\" WHERE \"note\" = ? ALLOW FILTERING")
        #expect(plan.shownColumns == ["id", "day", "note", "tags"])
        #expect(plan.lifetimeColumns == ["note"])
        #expect(plan.lifetimeValueIndices == [2])
        #expect(plan.keyIndices == ["id": 0, "day": 1])
    }

    @Test("SELECT * is spelled out in the order the server returns it, so the TTL() selectors can follow")
    func wildcard() throws {
        let layout = try #require(CassandraTableLayoutTests.visits())
        let plan = try #require(CassandraLifetimeRead.plan(cql: "SELECT * FROM \"visits\"", target: "\"visits\"", layout: layout))
        #expect(plan.shownColumns == ["id", "day", "owner", "Count", "address", "note", "tags"])
        #expect(plan.cql == "SELECT \"id\", \"day\", \"owner\", \"Count\", \"address\", \"note\", \"tags\", "
            + "TTL(\"owner\"), TTL(\"Count\"), TTL(\"address\"), TTL(\"note\") FROM \"visits\"")
        #expect(plan.lifetimeValueIndices == [2, 3, 4, 5])
    }

    @Test("A name holding a quote and a comma is read back whole")
    func quotedNames() throws {
        let layout = try #require(CassandraTableLayoutTests.visits(
            extra: [.init(name: "a\"b, c", type: "text", kind: .regular, position: -1)]
        ))
        let plan = try #require(CassandraLifetimeRead.plan(
            cql: "SELECT \"id\", \"day\", \"a\"\"b, c\" FROM \"shop\".\"visits\"", target: Self.target, layout: layout
        ))
        #expect(plan.shownColumns == ["id", "day", "a\"b, c"])
        #expect(plan.cql == "SELECT \"id\", \"day\", \"a\"\"b, c\", TTL(\"a\"\"b, c\") FROM \"shop\".\"visits\"")
    }

    @Test("Nothing is added to another table, another shape of statement, a read without the key or without a TTL", arguments: [
        "SELECT * FROM \"shop\".\"other\"",
        "SELECT * FROM \"shop\".\"visits\" LIMIT 5",
        "SELECT id, day, note FROM \"shop\".\"visits\"",
        "SELECT \"note\" FROM \"shop\".\"visits\"",
        "SELECT \"id\", \"day\", \"tags\" FROM \"shop\".\"visits\"",
        "SELECT \"id\", \"day\", \"note FROM \"shop\".\"visits\"",
        "select * from \"shop\".\"visits\"",
    ])
    func untouchedStatements(cql: String) throws {
        let layout = try #require(CassandraTableLayoutTests.visits())
        #expect(CassandraLifetimeRead.plan(cql: cql, target: Self.target, layout: layout) == nil)
    }
}
