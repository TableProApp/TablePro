//
//  PostgreSQLCatalogCompatibilityTests.swift
//  TableProTests
//
//  Regression cover for #1383: PostgreSQL-compatible engines (e.g. db9.ai) report a recent
//  version but lack optional catalogs like pg_matviews. The listing names no such catalog, only
//  relkind values, and the catalog probe parses presence from pg_class relation names.
//

import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLFetchTablesQueryTests {
    private static let flagCombinations: [(materializedViews: Bool, foreignTables: Bool)] = [
        (true, true), (true, false), (false, true), (false, false)
    ]

    @Test("No combination of flags names pg_matviews or pg_foreign_table")
    func neverNamesTheOptionalCatalogs() {
        for flags in Self.flagCombinations {
            let query = PostgreSQLTableListing.query(
                schema: "public",
                includeMaterializedViews: flags.materializedViews,
                includeForeignTables: flags.foreignTables
            )
            #expect(!query.contains("pg_matviews"), "\(flags)")
            #expect(!query.contains("pg_foreign_table"), "\(flags)")
        }
    }

    @Test("Materialized views and foreign tables are listed only with their flag")
    func relationKindsFollowTheFlags() {
        for flags in Self.flagCombinations {
            let query = PostgreSQLTableListing.query(
                schema: "public",
                includeMaterializedViews: flags.materializedViews,
                includeForeignTables: flags.foreignTables
            )
            #expect(query.contains("'m'") == flags.materializedViews, "\(flags)")
            #expect(query.contains("'f'") == flags.foreignTables, "\(flags)")
            #expect(query.contains("'MATERIALIZED VIEW'") == flags.materializedViews, "\(flags)")
            #expect(query.contains("'FOREIGN TABLE'") == flags.foreignTables, "\(flags)")
        }
    }

    @Test("Base tables, partitioned tables and views are always listed")
    func alwaysListsTablesAndViews() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: false,
            includeForeignTables: false
        )
        #expect(query.contains("rc.relkind IN ('r', 'p', 'v')"))
        #expect(!query.contains("UNION ALL"))
    }
}

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
