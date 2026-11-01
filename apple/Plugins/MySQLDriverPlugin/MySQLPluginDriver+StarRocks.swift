//
//  MySQLPluginDriver+StarRocks.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

extension MySQLPluginDriver {
    // No multi-statement transactions before 3.5, and a frontend before 3.2 refuses `COM_STMT_PREPARE`.
    static let starrocksCapabilities: PluginCapabilities = [
        .cancelQuery,
    ]

    func starrocksTables(database: String) async throws -> [PluginTableInfo] {
        let rows = try await execute(
            query: MySQLObjectQueries.listedTables(schema: database, hasInformationSchema: true)
        ).rows
        let tables = MySQLTableListing.tables(from: rows, listsSequencesAsTables: false)
        guard starrocksScope.keepsTableStatus else { return tables }
        let materialized = StarRocksCatalog.names(from: try await execute(
            ownStatement: StarRocksCatalog.materializedViewNames(database: database)
        ).rows)
        return StarRocksCatalog.markingMaterializedViews(Set(materialized), in: tables)
    }

    func starrocksColumns(database: String, table: String?) async throws -> [String: [PluginColumnInfo]] {
        let rows = try await execute(
            ownStatement: StarRocksCatalog.columns(database: database, table: table)
        ).rows
        return StarRocksCatalog.columnsByTable(from: rows)
    }

    func starrocksTableStatus(database: String) async throws -> [String: PluginTableMetadata] {
        guard starrocksScope.keepsTableStatus else { return [:] }
        let rows = try await execute(query: Self.tableStatusStatement(database: database)).rows
        var metadata: [String: PluginTableMetadata] = [:]
        for row in rows {
            guard let name = row[safe: 0]?.asText else { continue }
            metadata[name] = MySQLTableStatusRow.metadata(from: row, tableName: name, reportsIndexLength: false)
        }
        return metadata
    }

    func starrocksTableStatus(table: String, schema: String?) async throws -> PluginTableMetadata? {
        guard starrocksScope.keepsTableStatus, let row = try await tableStatusRow(table: table, schema: schema) else {
            return nil
        }
        return MySQLTableStatusRow.metadata(from: row, tableName: table, reportsIndexLength: false)
    }
}
