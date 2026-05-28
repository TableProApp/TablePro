//
//  PostgreSQLCatalogCompatibilityTests.swift
//  TableProTests
//
//  Regression cover for #1383: PostgreSQL-compatible engines (e.g. db9.ai)
//  report a recent Postgres version but lack optional catalogs like
//  pg_matviews. fetchTables must omit those unions when the catalog is absent,
//  and the catalog probe must parse presence from pg_class relation names.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries.fetchTables")
struct PostgreSQLFetchTablesQueryTests {
    @Test("Always selects base tables and views from information_schema")
    func alwaysIncludesBaseTables() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: true,
            includeForeignTables: true
        )
        #expect(query.contains("information_schema.tables"))
    }

    @Test("Omits the pg_matviews union when materialized views are unavailable")
    func omitsMatviewsWhenAbsent() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: false,
            includeForeignTables: true
        )
        #expect(!query.contains("pg_matviews"))
    }

    @Test("Includes the pg_matviews union when materialized views are available")
    func includesMatviewsWhenPresent() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: true,
            includeForeignTables: false
        )
        #expect(query.contains("pg_matviews"))
    }

    @Test("Omits the pg_foreign_table union when foreign tables are unavailable")
    func omitsForeignTablesWhenAbsent() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: true,
            includeForeignTables: false
        )
        #expect(!query.contains("pg_foreign_table"))
    }

    @Test("With no optional catalogs, only the base query remains")
    func baseOnlyWhenNoOptionalCatalogs() {
        let query = PostgreSQLSchemaQueries.fetchTables(
            schemaLiteral: "public",
            includeMaterializedViews: false,
            includeForeignTables: false
        )
        #expect(query.contains("information_schema.tables"))
        #expect(!query.contains("pg_matviews"))
        #expect(!query.contains("pg_foreign_table"))
        #expect(!query.contains("UNION ALL"))
    }
}

@Suite("PostgreSQLCatalogPresence")
struct PostgreSQLCatalogPresenceTests {
    @Test("Parses a single present catalog")
    func parsesSingleCatalog() {
        let presence = PostgreSQLCatalogPresence(relationNames: ["pg_matviews"])
        #expect(presence.hasMaterializedViews)
        #expect(!presence.hasForeignTables)
        #expect(!presence.hasSequences)
    }

    @Test("Parses all catalogs present")
    func parsesAllCatalogs() {
        let presence = PostgreSQLCatalogPresence(
            relationNames: ["pg_matviews", "pg_foreign_table", "pg_sequences"]
        )
        #expect(presence.hasMaterializedViews)
        #expect(presence.hasForeignTables)
        #expect(presence.hasSequences)
    }

    @Test("Empty probe result means no optional catalogs")
    func parsesEmpty() {
        let presence = PostgreSQLCatalogPresence(relationNames: [])
        #expect(!presence.hasMaterializedViews)
        #expect(!presence.hasForeignTables)
        #expect(!presence.hasSequences)
    }
}
