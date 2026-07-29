//
//  DataGridCoordinator+Scope.swift
//  TablePro
//

import Foundation

extension TableViewCoordinator {
    var tableScope: TableScope? {
        guard let connectionId, let tableName else { return nil }
        return TableScope(connectionId: connectionId, database: databaseName, schema: schemaName, table: tableName)
    }
}
