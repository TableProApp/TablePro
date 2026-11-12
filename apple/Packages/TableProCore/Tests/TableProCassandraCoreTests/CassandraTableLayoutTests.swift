//
//  CassandraTableLayoutTests.swift
//  TableProCassandraCoreTests
//

import TableProCassandraCore
import Testing

struct CassandraTableLayoutTests {
    static func visits(defaultTimeToLive: Int? = 0, extra: [CassandraTableLayout.Column] = []) -> CassandraTableLayout? {
        CassandraTableLayout(columns: [
            .init(name: "note", type: "text", kind: .regular, position: -1),
            .init(name: "day", type: "date", kind: .clustering, position: 0),
            .init(name: "tags", type: "set<text>", kind: .regular, position: -1),
            .init(name: "owner", type: "text", kind: .staticColumn, position: -1),
            .init(name: "id", type: "uuid", kind: .partitionKey, position: 0),
            .init(name: "Count", type: "int", kind: .regular, position: -1),
            .init(name: "address", type: "frozen<address>", kind: .regular, position: -1),
        ] + extra, defaultTimeToLive: defaultTimeToLive)
    }

    @Test("SELECT * order: the key in order, then static and regular columns by name")
    func selectOrder() throws {
        let layout = try #require(Self.visits())
        #expect(layout.selectOrder == ["id", "day", "owner", "Count", "address", "note", "tags"])
        #expect(layout.partitionKey == ["id"])
        #expect(layout.primaryKey == ["id", "day"])
        #expect(layout.staticColumns == ["owner"])
    }

    @Test("TTL() is read for regular and static cells that hold one value", arguments: [
        ("note", true), ("owner", true), ("Count", true), ("address", true),
        ("tags", false), ("id", false), ("day", false), ("missing", false),
    ])
    func acceptedColumns(column: String, accepted: Bool) throws {
        let layout = try #require(Self.visits())
        #expect(layout.acceptsTimeToLive(column) == accepted)
    }

    @Test("Counters, non-frozen collections and user types, and custom types take no TTL()", arguments: [
        ("counter", false), ("list<int>", false), ("map<text, int>", false), ("address", false),
        ("'org.apache.cassandra.db.marshal.DynamicCompositeType'", false),
        ("frozen<list<int>>", true), ("tuple<int, text>", true), ("vector<float, 3>", true), ("duration", true),
        (" TIMESTAMP ", true),
    ])
    func typesThatHoldOneCell(type: String, accepted: Bool) throws {
        let layout = try #require(Self.visits(extra: [.init(name: "probe", type: type, kind: .regular, position: -1)]))
        #expect(layout.acceptsTimeToLive("probe") == accepted)
    }

    @Test("No layout for a table without columns or with a COMPACT STORAGE value column")
    func unusableTables() {
        #expect(CassandraTableLayout(columns: [], defaultTimeToLive: 0) == nil)
        #expect(Self.visits(extra: [.init(name: "value", type: "empty", kind: .regular, position: -1)]) == nil)
    }

    @Test("A system_schema row needs a name, a type and a kind CQL has")
    func columnRows() {
        #expect(CassandraTableLayout.column(name: "note", type: "text", kind: "regular", position: "-1")
            == .init(name: "note", type: "text", kind: .regular, position: -1))
        #expect(CassandraTableLayout.column(name: "id", type: "int", kind: "partition_key", position: "0")?.kind
            == .partitionKey)
        #expect(CassandraTableLayout.column(name: "note", type: "text", kind: "other", position: "0") == nil)
        #expect(CassandraTableLayout.column(name: nil, type: "text", kind: "regular", position: "0") == nil)
    }
}
