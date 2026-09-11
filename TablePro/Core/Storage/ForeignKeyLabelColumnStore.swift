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
@MainActor
internal final class ForeignKeyLabelColumnStore: TableScopedSettingsStore {
    static let shared = ForeignKeyLabelColumnStore()

    private static let keyPrefix = PreferenceKeys.foreignKeyLabelColumnPrefix

    private let store: KeyValueStore

    init(defaults: KeyValueStore = AppStorageEnvironment.shared.defaults) {
        store = defaults
    }

    func labelColumn(for scope: TableScope) -> String? {
        guard let data = store.dataValue(forKey: PreferenceKeys.foreignKeyLabelColumn(scope).name) else {
            return nil
        }
        guard let name = String(bytes: data, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }

    func setLabelColumn(_ name: String?, for scope: TableScope) {
        guard let name, !name.isEmpty else {
            store.setDataValue(nil, forKey: PreferenceKeys.foreignKeyLabelColumn(scope).name)
            return
        }
        store.setDataValue(Data(name.utf8), forKey: PreferenceKeys.foreignKeyLabelColumn(scope).name)
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
