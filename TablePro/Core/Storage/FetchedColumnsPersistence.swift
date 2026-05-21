//
//  FetchedColumnsPersistence.swift
//  TablePro
//

import Foundation

enum FetchedColumnsPersistence {
    static func key(tableName: String, connectionId: UUID) -> String {
        "com.TablePro.columns.unfetchedColumns.\(connectionId.uuidString).\(tableName)"
    }

    static func loadUnfetchedColumns(
        for tableName: String,
        connectionId: UUID,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        let storageKey = key(tableName: tableName, connectionId: connectionId)
        guard let array = defaults.stringArray(forKey: storageKey) else { return [] }
        return Set(array)
    }

    static func saveUnfetchedColumns(
        _ unfetchedColumns: Set<String>,
        for tableName: String,
        connectionId: UUID,
        defaults: UserDefaults = .standard
    ) {
        let storageKey = key(tableName: tableName, connectionId: connectionId)
        if unfetchedColumns.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(Array(unfetchedColumns), forKey: storageKey)
        }
    }
}
