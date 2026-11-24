//
//  ClickHousePluginDriver+StorageParts.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated extension ClickHousePluginDriver: PluginStorageParts {
    func fetchStorageParts(table: String, database: String) async throws -> [PluginStoragePart] {
        let result = try await execute(query: ClickHousePartStatements.parts(database: database, table: table))
        return result.rows.compactMap(ClickHousePartStatements.part(from:))
    }

    func mergePartsStatement(table: String, database: String) -> String? {
        ClickHousePartStatements.optimize(database: database, table: table, quote: quoteIdentifier)
    }

    func dropPartitionStatement(table: String, database: String, partitionId: String) -> String? {
        ClickHousePartStatements.dropPartition(
            database: database, table: table, partitionId: partitionId, quote: quoteIdentifier
        )
    }

    func detachPartitionStatement(table: String, database: String, partitionId: String) -> String? {
        ClickHousePartStatements.detachPartition(
            database: database, table: table, partitionId: partitionId, quote: quoteIdentifier
        )
    }
}
