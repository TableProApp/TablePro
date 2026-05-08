//
//  MainContentCoordinator+LazyLoadColumns.swift
//  TablePro
//

import Foundation

internal extension MainContentCoordinator {
    func fetchFullValuesForExcludedColumns(
        tableName: String,
        primaryKeyColumn: String,
        primaryKeyValue: String,
        excludedColumnNames: [String]
    ) async throws -> [String: String?] {
        try await LazyLoadColumnsService(
            connectionId: connectionId,
            databaseType: connection.type,
            queryBuilder: queryBuilder
        ).fetchValues(
            tableName: tableName,
            primaryKeyColumn: primaryKeyColumn,
            primaryKeyValue: primaryKeyValue,
            excludedColumnNames: excludedColumnNames
        )
    }
}
