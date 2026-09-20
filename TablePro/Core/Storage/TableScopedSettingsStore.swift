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

    /// Forgets one table's saved settings, because the table is gone.
    func dropTable(_ scope: TableScope)

    /// Forgets the saved settings of every table inside a dropped database or schema.
    ///
    /// A prefix sweep rather than a list of tables, for the reason `renameContainer` takes one: the
    /// table list is loaded lazily, so a table nobody opened this session still has settings on
    /// disk and could never be named here. A nil schema means the whole database.
    func dropContainer(connectionId: UUID, database: String, schema: String?)

    /// Forgets everything these connections saved. `leavesTombstones` is false when another device
    /// did the deleting: a synced store must not mark its records deleted there, or it pushes the
    /// sender's own deletion back at it.
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
            ForeignKeyLabelColumnStore.shared
        ]
    }
}
