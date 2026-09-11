//
//  TableScopedSettingsStore.swift
//  TablePro
//

import Foundation

@MainActor
internal protocol TableScopedSettingsStore: AnyObject {
    func renameTable(from oldScope: TableScope, to newScope: TableScope)
    func renameContainer(
        connectionId: UUID,
        fromDatabase: String,
        fromSchema: String?,
        toDatabase: String,
        toSchema: String?
    )
    func purgeConnections(_ connectionIds: Set<UUID>)
}

@MainActor
internal enum TableScopedSettingsRegistry {
    internal static var stores: [any TableScopedSettingsStore] {
        [
            FilterSettingsStorage.shared,
            FileColumnLayoutPersister.shared,
            HighlightRuleStorage.shared,
            ValueDisplayFormatStorage.shared,
            ForeignKeyLabelColumnStore.shared
        ]
    }
}
