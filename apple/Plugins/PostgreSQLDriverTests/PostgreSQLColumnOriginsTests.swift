import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLColumnOriginsTests {
    // Measured on PostgreSQL 17: `SELECT u FROM users u` reports the table with column 0, `ctid` column -1.
    @Test("Only a relation and a positive column number name a column")
    func sourceNeedsARelationColumn() {
        #expect(PostgreSQLColumnOrigins.source(relation: 16_384, attribute: 2)
            == PostgreSQLColumnOrigins.Source(relation: 16_384, attribute: 2))
        #expect(PostgreSQLColumnOrigins.source(relation: 0, attribute: 0) == nil)
        #expect(PostgreSQLColumnOrigins.source(relation: 16_384, attribute: 0) == nil)
        #expect(PostgreSQLColumnOrigins.source(relation: 16_384, attribute: -1) == nil)
    }

    @Test("The lookup reads each relation once, by oid, from the catalogs")
    func lookupQueryNamesEachRelationOnce() throws {
        let sources = [
            PostgreSQLColumnOrigins.Source(relation: 16_394, attribute: 1),
            nil,
            PostgreSQLColumnOrigins.Source(relation: 16_384, attribute: 2),
            PostgreSQLColumnOrigins.Source(relation: 16_384, attribute: 3),
        ]
        let query = try #require(PostgreSQLColumnOrigins.lookupQuery(for: sources))
        #expect(query.contains("a.attrelid = ANY ('{16384,16394}'::pg_catalog.oid[])"))
        #expect(query.contains("FROM pg_catalog.pg_attribute a"))
        #expect(query.contains("a.attnum > 0"))
    }

    @Test("A result of expressions only needs no lookup")
    func noLookupWithoutSources() {
        #expect(PostgreSQLColumnOrigins.lookupQuery(for: [nil, nil]) == nil)
        #expect(PostgreSQLColumnOrigins.lookupQuery(for: []) == nil)
    }

    @Test("Each column takes the schema, relation and column its source names")
    func originsFollowTheirSources() {
        let email = PostgreSQLColumnOrigins.Source(relation: 16_384, attribute: 2)
        let viewColumn = PostgreSQLColumnOrigins.Source(relation: 16_394, attribute: 2)
        let dropped = PostgreSQLColumnOrigins.Source(relation: 16_384, attribute: 9)
        let rows: [[PluginCellValue]] = [
            [.text("16384"), .text("1"), .text("public"), .text("users"), .text("id")],
            [.text("16384"), .text("2"), .text("public"), .text("users"), .text("email")],
            [.text("16394"), .text("2"), .text("public"), .text("v"), .text("e")],
            [.text("x"), .text("2"), .text("public"), .text("users"), .text("email")],
        ]

        let origins = PostgreSQLColumnOrigins.origins(for: [email, nil, viewColumn, dropped], rows: rows)

        #expect(origins == [
            PluginColumnOrigin(schema: "public", table: "users", column: "email"),
            nil,
            PluginColumnOrigin(schema: "public", table: "v", column: "e"),
            nil,
        ])
    }

    // Measured: `histogram_bounds` of `pg_stats` listed the sampled e-mail addresses of the column it describes.
    @Test("Only a user table's column is vouched for, never a catalog's or a system view's")
    func systemRelationsHaveNoOrigin() {
        let rows: [[PluginCellValue]] = [
            [.text("12053"), .text("10"), .text("pg_catalog"), .text("pg_stats"), .text("histogram_bounds")],
            [.text("12222"), .text("21"), .text("pg_catalog"), .text("pg_stat_activity"), .text("query")],
            [.text("13400"), .text("3"), .text("information_schema"), .text("columns"), .text("column_default")],
            [.text("20000"), .text("2"), .text("sys_catalog"), .text("sys_stats"), .text("histogram_bounds")],
            [.text("20002"), .text("1"), .text("sys"), .text("dba_users"), .text("username")],
            [.text("20001"), .text("1"), .text("pg_toast"), .text("pg_toast_16384"), .text("chunk_data")],
            [.text("12500"), .text("1"), .text("public"), .text("made_by_initdb"), .text("x")],
            [.text("16500"), .text("1"), .text("public"), .text("pg_stats"), .text("note")],
        ]
        let sources = rows.map { row in
            PostgreSQLColumnOrigins.Source(
                relation: UInt32(row[0].asText ?? "") ?? 0, attribute: Int32(row[1].asText ?? "") ?? 0
            )
        }

        #expect(PostgreSQLColumnOrigins.origins(for: sources, rows: rows) == [
            nil, nil, nil, nil, nil, nil, nil,
            PluginColumnOrigin(schema: "public", table: "pg_stats", column: "note"),
        ])
    }
}
