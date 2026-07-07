//
//  ColumnVisibilityPersistence.swift
//  TablePro
//

import Foundation

enum ColumnVisibilityPersistence {
    private static let keyPrefix = "com.TablePro.columns.hiddenColumns."

    static func key(for tableKey: ColumnLayoutTableKey) -> String {
        keyPrefix + tableKey.storageKey
    }

    static func loadHiddenColumns(
        for tableKey: ColumnLayoutTableKey,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        guard let array = defaults.stringArray(forKey: key(for: tableKey)) else { return [] }
        return Set(array)
    }

    static func saveHiddenColumns(
        _ hiddenColumns: Set<String>,
        for tableKey: ColumnLayoutTableKey,
        defaults: UserDefaults = .standard
    ) {
        let storageKey = key(for: tableKey)
        if hiddenColumns.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(Array(hiddenColumns), forKey: storageKey)
        }
    }
}
