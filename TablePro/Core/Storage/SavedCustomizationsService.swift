//
//  SavedCustomizationsService.swift
//  TablePro
//

import Foundation

struct SavedTableCustomization: Identifiable, Equatable {
    let scope: TableScope
    let hasLayout: Bool
    let hasFilters: Bool

    var id: String { scope.storageComponent }
}

@MainActor
enum SavedCustomizationsService {
    static func all(
        layoutStore: FileColumnLayoutPersister = .shared,
        filterStore: FilterSettingsStorage = .shared
    ) -> [SavedTableCustomization] {
        let layoutKeys = Set(layoutStore.customizedStorageKeys())
        let filterKeys = Set(filterStore.customizedStorageKeys())

        return layoutKeys.union(filterKeys)
            .compactMap { key -> SavedTableCustomization? in
                guard let scope = TableScope(storageComponent: key) else { return nil }
                return SavedTableCustomization(
                    scope: scope,
                    hasLayout: layoutKeys.contains(key),
                    hasFilters: filterKeys.contains(key)
                )
            }
            .sorted { $0.scope.displayName.localizedStandardCompare($1.scope.displayName) == .orderedAscending }
    }

    static func reset(
        _ scope: TableScope,
        layoutStore: FileColumnLayoutPersister = .shared,
        filterStore: FilterSettingsStorage = .shared
    ) {
        layoutStore.clear(for: ColumnLayoutTableKey(
            connectionId: scope.connectionId,
            databaseName: scope.database ?? "",
            schemaName: scope.schema,
            tableName: scope.table
        ))
        filterStore.clearLastFilters(
            for: scope.table,
            connectionId: scope.connectionId,
            databaseName: scope.database ?? "",
            schemaName: scope.schema
        )
    }

    static func resetAll(
        layoutStore: FileColumnLayoutPersister = .shared,
        filterStore: FilterSettingsStorage = .shared
    ) {
        for customization in all(layoutStore: layoutStore, filterStore: filterStore) {
            reset(customization.scope, layoutStore: layoutStore, filterStore: filterStore)
        }
    }
}
