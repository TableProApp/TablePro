//
//  CompositeStorageKey.swift
//  TablePro
//

import Foundation

enum CompositeStorageKey {
    static func make(
        connectionId: UUID,
        databaseName: String,
        schemaName: String?,
        tableName: String
    ) -> String {
        TableScope(
            connectionId: connectionId,
            database: databaseName,
            schema: schemaName,
            table: tableName
        ).storageComponent
    }
}
