import Foundation
import TableProPluginKit
import Testing

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

    @Test("the temporary listing reads the session's own temporary schema, names it on each row, and keeps partitions")
    func temporaryListing() throws {
        let sql = PostgreSQLTableListing.temporaryTables
        #expect(sql.contains("c.relnamespace = pg_catalog.pg_my_temp_schema()"))
        #expect(!sql.contains("pg_inherits i"))

        let table = try #require(PostgreSQLTableListing.table(fromRow: ["t", "BASE TABLE", "scratch", nil, "pg_temp_3"]))
        #expect(table.schema == "pg_temp_3")
        #expect(table.type == "TABLE")
        #expect(table.comment == "scratch")
    }

    @Test("a row without a name is dropped")
    func namelessRowIsDropped() {
        #expect(PostgreSQLTableListing.table(fromRow: [nil, "VIEW"]) == nil)
        #expect(PostgreSQLTableListing.table(fromRow: []) == nil)
    }
}
