//
//  LazyLoadColumnsService.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

@MainActor
struct LazyLoadColumnsService {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LazyLoadColumns")

    let connectionId: UUID
    let databaseType: DatabaseType
    let queryBuilder: TableQueryBuilder

    func fetchValues(
        tableName: String,
        primaryKeyColumn: String,
        primaryKeyValue: String,
        excludedColumnNames: [String]
    ) async throws -> [String: String?] {
        guard !excludedColumnNames.isEmpty else { return [:] }
        guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
            throw DatabaseError.notConnected
        }

        let quotedCols = excludedColumnNames.map { queryBuilder.quoteIdentifier($0) }
        let quotedTable = queryBuilder.quoteIdentifier(tableName)
        let quotedPK = queryBuilder.quoteIdentifier(primaryKeyColumn)

        let paramStyle = PluginMetadataRegistry.shared
            .snapshot(forTypeId: databaseType.pluginTypeId)?.parameterStyle ?? .questionMark
        let placeholder: String
        switch paramStyle {
        case .dollar:
            placeholder = "$1"
        case .questionMark:
            placeholder = "?"
        }

        let query = "SELECT \(quotedCols.joined(separator: ", ")) FROM \(quotedTable) WHERE \(quotedPK) = \(placeholder)"

        Self.logger.debug("Lazy-loading excluded columns: \(excludedColumnNames.joined(separator: ", "), privacy: .public)")

        let result = try await driver.executeParameterized(
            query: query,
            parameters: [primaryKeyValue]
        )

        guard let row = result.rows.first else {
            Self.logger.warning("No row returned for lazy-load query")
            return [:]
        }

        var dict: [String: String?] = [:]
        for (index, colName) in excludedColumnNames.enumerated() where index < row.count {
            dict[colName] = row[index]
        }
        return dict
    }
}
