//
//  TabTableContext+Scope.swift
//  TablePro
//

import Foundation

extension TabTableContext {
    func scope(connectionId: UUID?) -> TableScope? {
        guard let connectionId, let tableName else { return nil }
        let database = databaseName.isEmpty ? nil : databaseName
        return TableScope(connectionId: connectionId, database: database, schema: schemaName, table: tableName)
    }
}
