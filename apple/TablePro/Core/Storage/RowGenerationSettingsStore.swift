//
//  RowGenerationSettingsStore.swift
//  TablePro
//

import Foundation

// Generate Rows settings, one value per table. Device-local, so it needs no CloudKit record type.
@MainActor
internal final class RowGenerationSettingsStore: TableScopedSettingsStore {
    static let shared = RowGenerationSettingsStore()

    private static let keyPrefix = PreferenceKeys.rowGenerationPrefix

    private let store: KeyValueStore

    init(defaults: KeyValueStore = AppStorageEnvironment.shared.defaults) {
        store = defaults
    }

    func settings(for scope: TableScope) -> RowGenerationSettings? {
        store.read(PreferenceKeys.rowGeneration(scope)).value
    }

    func save(_ settings: RowGenerationSettings, for scope: TableScope) {
        try? store.write(settings, to: PreferenceKeys.rowGeneration(scope))
    }

    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        store.moveValue(
            fromKey: PreferenceKeys.rowGeneration(oldScope).name,
            toKey: PreferenceKeys.rowGeneration(newScope).name
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

    func dropTable(_ scope: TableScope) {
        store.removeValue(for: PreferenceKeys.rowGeneration(scope))
    }

    func dropContainer(connectionId: UUID, database: String, schema: String?) {
        store.removeValues(
            withPrefix: Self.keyPrefix
                + TableScope.storagePrefix(connectionId: connectionId, database: database, schema: schema)
        )
    }

    func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool) {
        for connectionId in connectionIds {
            store.removeValues(withPrefix: Self.keyPrefix + TableScope.storagePrefix(connectionId: connectionId))
        }
    }
}
