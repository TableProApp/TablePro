//
//  MySQLPluginDriver+ForeignKeys.swift
//  MySQLDriverPlugin
//
//  The per-table and whole-schema foreign key reads, which take the same two catalog statements and
//  the same merge so the two cannot disagree.
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

extension MySQLPluginDriver {
    var providesBulkForeignKeyFetch: Bool { true }

    var tableDDLIncludesForeignKeys: Bool { MySQLExportCatalog.tableDDLIncludesForeignKeys }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        guard flavor.hasMySQLObjectCatalogs else { return [] }
        let database = effectiveSchema(schema)
        let identity = serverIdentity
        let omittedAction = MySQLServerVersion.omittedForeignKeyAction(
            banner: identity.banner,
            flavor: identity.flavor
        )
        guard await !resolvesToTemporaryTable(table, schema: schema) else {
            return try await ddlForeignKeys(table: table, database: database, omittedAction: omittedAction)
        }
        let reader = exportCatalog
        let byTable = try await catalogOrShow(
            database: database,
            catalogExists: reader.hasForeignKeyCatalog,
            catalog: { try await reader.catalogForeignKeys(database: database, table: table) },
            show: {
                let keys = try await self.ddlForeignKeys(
                    table: table, database: database, omittedAction: omittedAction
                )
                return [table: keys]
            }
        )
        return MySQLForeignKeyCatalog.keys(for: table, in: byTable)
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        guard flavor.hasMySQLObjectCatalogs else { return [:] }
        let database = effectiveSchema(schema)
        let reader = exportCatalog
        return try await catalogOrShow(
            database: database,
            catalogExists: reader.hasForeignKeyCatalog,
            catalog: { try await reader.catalogForeignKeys(database: database, table: nil) },
            show: { try await self.showForeignKeysByTable(database: database) }
        )
    }
}
