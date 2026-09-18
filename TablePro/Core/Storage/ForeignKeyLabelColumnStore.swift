//
//  ForeignKeyLabelColumnStore.swift
//  TablePro
//

import Foundation

/// The label column a foreign key picker shows beside the key, remembered per referenced table.
///
/// Keyed by the table being picked from rather than by the column pointing at it, because a name is
/// a property of the target: `orders.user_id` and `comments.user_id` both want `users.name`, and
/// setting it once for `users` is what a user means by remembering it. Device-local, so this needs
/// no CloudKit record type.
///
/// Three states, not two: a table nobody has chosen for, one the reader has chosen **None** for,
/// and one with a named column. `ForeignKeyLabelChoice` owns the encoding.
@MainActor
internal final class ForeignKeyLabelColumnStore: TableScopedSettingsStore {
    static let shared = ForeignKeyLabelColumnStore()

    private static let keyPrefix = PreferenceKeys.foreignKeyLabelColumnPrefix

    private let store: KeyValueStore

    init(defaults: KeyValueStore = AppStorageEnvironment.shared.defaults) {
        store = defaults
    }

    func labelChoice(for scope: TableScope) -> ForeignKeyLabelChoice {
        ForeignKeyLabelChoice(
            storedData: store.dataValue(forKey: PreferenceKeys.foreignKeyLabelColumn(scope).name)
        )
    }

    func setLabelChoice(_ choice: ForeignKeyLabelChoice, for scope: TableScope) {
        store.setDataValue(choice.storedData, forKey: PreferenceKeys.foreignKeyLabelColumn(scope).name)
    }

    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        store.moveValue(
            fromKey: PreferenceKeys.foreignKeyLabelColumn(oldScope).name,
            toKey: PreferenceKeys.foreignKeyLabelColumn(newScope).name
        )
    }

    func renameContainer(
        connectionId: UUID,
        fromDatabase: String,
        fromSchema: String?,
        toDatabase: String,
        toSchema: String?
    ) {
        store.moveValues(
            withPrefix: Self.keyPrefix
                + TableScope.storagePrefix(connectionId: connectionId, database: fromDatabase, schema: fromSchema),
            toPrefix: Self.keyPrefix
                + TableScope.storagePrefix(connectionId: connectionId, database: toDatabase, schema: toSchema)
        )
    }

    func purgeConnections(_ connectionIds: Set<UUID>) {
        for connectionId in connectionIds {
            store.removeValues(withPrefix: Self.keyPrefix + TableScope.storagePrefix(connectionId: connectionId))
        }
    }
}
