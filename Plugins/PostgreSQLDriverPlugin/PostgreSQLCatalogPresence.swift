//
//  PostgreSQLCatalogPresence.swift
//  PostgreSQLDriverPlugin
//

import Foundation

struct PostgreSQLCatalogPresence: Sendable, Equatable {
    let hasMaterializedViews: Bool
    let hasForeignTables: Bool
    let hasSequences: Bool

    static let probeQuery = """
        SELECT c.relname
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pg_catalog'
          AND c.relname IN ('pg_matviews', 'pg_foreign_table', 'pg_sequences')
        """

    init(relationNames: [String]) {
        let names = Set(relationNames)
        self.hasMaterializedViews = names.contains("pg_matviews")
        self.hasForeignTables = names.contains("pg_foreign_table")
        self.hasSequences = names.contains("pg_sequences")
    }
}
