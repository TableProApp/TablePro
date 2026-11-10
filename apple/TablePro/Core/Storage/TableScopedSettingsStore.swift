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

    func dropTable(_ scope: TableScope)

    // A prefix sweep rather than a list of tables: the table list is loaded lazily, so a table nobody opened this
    // session still has settings on disk. A nil schema means the whole database.
    func dropContainer(connectionId: UUID, database: String, schema: String?)

    // leavesTombstones is false when another device did the deleting: a synced store that marks its records deleted
    // there pushes the sender's own deletion back at it.
    func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool)
}

@MainActor
internal enum TableScopedSettingsRegistry {
    internal static var stores: [any TableScopedSettingsStore] {
        [
            FilterSettingsStorage.shared,
            FileColumnLayoutPersister.shared,
            HighlightRuleStorage.shared,
            ValueDisplayFormatStorage.shared,
            ForeignKeyLabelColumnStore.shared,
            ImportColumnMappingStore.shared,
            RowGenerationSettingsStore.shared,
            TableFolderStorage.shared,
            TableHealthHistoryStorage.shared
        ]
    }
}
