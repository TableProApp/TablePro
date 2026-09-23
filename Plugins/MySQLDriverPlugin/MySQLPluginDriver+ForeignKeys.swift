//
//  MySQLPluginDriver+ForeignKeys.swift
//  MySQLDriverPlugin
//
//  The per-table and whole-schema foreign key reads, which take the same two catalog statements and
//  the same merge so the two cannot disagree.
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    var providesBulkForeignKeyFetch: Bool { true }

    var tableDDLIncludesForeignKeys: Bool { true }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        guard !flavor.isDatabend else { return [] }
        let database = effectiveSchema(schema)
        let identity = serverIdentity
        let omittedAction = MySQLServerVersion.omittedForeignKeyAction(
            banner: identity.banner,
            flavor: identity.flavor
        )
        let byTable = try await catalogOrShow(
            database: database,
            catalog: { try await self.catalogForeignKeys(database: database, table: table) },
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
        guard !flavor.isDatabend else { return [:] }
        let database = effectiveSchema(schema)
        return try await catalogOrShow(
            database: database,
            catalog: { try await self.catalogForeignKeys(database: database, table: nil) },
            show: { try await self.showForeignKeysByTable(database: database) }
        )
    }

    /// Two single-catalog reads merged here rather than one join run by the server.
    ///
    /// The join answered nothing at all through ShardingSphere-Proxy 5.5.3, which returns an OK
    /// packet with no columns for any join of two `information_schema` tables while answering each
    /// of these two reads with the same rows a direct server does.
    private func catalogForeignKeys(
        database: String,
        table: String?
    ) async throws -> [String: [PluginForeignKeyInfo]] {
        let columns = try await execute(ownStatement: MySQLObjectQueries.foreignKeyColumns(schema: database, table: table))
        let columnRows = columns.rows.compactMap { row -> MySQLForeignKeyCatalog.ColumnRow? in
            guard let tableName = row[safe: 0]?.asText,
                  let constraint = row[safe: 1]?.asText,
                  let column = row[safe: 2]?.asText,
                  let referencedTable = row[safe: 4]?.asText,
                  let referencedColumn = row[safe: 5]?.asText
            else { return nil }
            return MySQLForeignKeyCatalog.ColumnRow(
                table: tableName,
                constraint: constraint,
                column: column,
                referencedSchema: row[safe: 3]?.asText,
                referencedTable: referencedTable,
                referencedColumn: referencedColumn
            )
        }
        guard !columnRows.isEmpty else { return [:] }

        let actions = try await execute(ownStatement: MySQLObjectQueries.referentialActions(schema: database, table: table))
        let actionRows = actions.rows.compactMap { row -> MySQLForeignKeyCatalog.ActionRow? in
            guard let tableName = row[safe: 0]?.asText,
                  let constraint = row[safe: 1]?.asText
            else { return nil }
            return MySQLForeignKeyCatalog.ActionRow(
                table: tableName,
                constraint: constraint,
                onDelete: row[safe: 2]?.asText ?? "",
                onUpdate: row[safe: 3]?.asText ?? ""
            )
        }

        return MySQLForeignKeyCatalog.group(
            columnRows: columnRows,
            actionRows: actionRows.filter { !$0.onDelete.isEmpty && !$0.onUpdate.isEmpty },
            defaultAction: MySQLServerVersion.omittedForeignKeyAction(
                banner: serverIdentity.banner,
                flavor: serverIdentity.flavor
            )
        )
    }
}
