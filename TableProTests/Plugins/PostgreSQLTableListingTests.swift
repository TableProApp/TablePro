import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQL table listing rows")
struct PostgreSQLTableListingTests {
    @Test("each listed relation type keeps its kind, and any other type reads as a table")
    func relationTypes() {
        let rows: [[String?]] = [
            ["mv", "MATERIALIZED VIEW", nil, nil],
            ["p", "PARTITIONED TABLE", "partitioned", "3"],
            ["ft", "FOREIGN TABLE", nil, nil],
            ["v", "VIEW", nil, nil],
            ["t", "BASE TABLE", "", nil],
            ["tmp", "LOCAL TEMPORARY", nil, nil],
            ["missing", nil, nil, nil]
        ]

        let tables = rows.compactMap { PostgreSQLTableListing.table(fromRow: $0) }

        #expect(tables.map(\.name) == ["mv", "p", "ft", "v", "t", "tmp", "missing"])
        #expect(tables.map(\.type) == [
            "MATERIALIZED VIEW", "PARTITIONED TABLE", "FOREIGN TABLE", "VIEW", "TABLE", "TABLE", "TABLE"
        ])
        #expect(tables.map(\.comment) == [nil, "partitioned", nil, nil, nil, nil, nil])
        #expect(tables.map(\.partitionCount) == [nil, 3, nil, nil, nil, nil, nil])
    }

    @Test("a row without a name is dropped")
    func namelessRowIsDropped() {
        #expect(PostgreSQLTableListing.table(fromRow: [nil, "VIEW"]) == nil)
        #expect(PostgreSQLTableListing.table(fromRow: []) == nil)
    }
}
