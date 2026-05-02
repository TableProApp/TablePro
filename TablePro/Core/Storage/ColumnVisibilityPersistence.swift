//
//  ColumnVisibilityPersistence.swift
//  TablePro
//

import Foundation

enum ColumnVisibilityPersistence {
    static func key(tableName: String, connectionId: UUID) -> String {
        "com.TablePro.columns.hiddenColumns.\(connectionId.uuidString).\(tableName)"
    }

    static func loadHiddenColumns(
        for tableName: String,
        connectionId: UUID,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        let storageKey = key(tableName: tableName, connectionId: connectionId)
        guard let array = defaults.stringArray(forKey: storageKey) else { return [] }
        return Set(array)
    }

    static func saveHiddenColumns(
        _ hiddenColumns: Set<String>,
        for tableName: String,
        connectionId: UUID,
        defaults: UserDefaults = .standard
    ) {
        let storageKey = key(tableName: tableName, connectionId: connectionId)
        defaults.set(Array(hiddenColumns), forKey: storageKey)
    }
}
