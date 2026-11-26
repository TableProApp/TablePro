//
//  ImportColumnMappingStore.swift
//  TablePro
//

import Foundation

// Keyed by table, not file, since the same export comes back under new names. Device-local: no CloudKit record type.
@MainActor
internal final class ImportColumnMappingStore: TableScopedSettingsStore {
    static let shared = ImportColumnMappingStore()

    private static let keyPrefix = PreferenceKeys.importColumnMappingPrefix

    private let store: KeyValueStore

    init(defaults: KeyValueStore = AppStorageEnvironment.shared.defaults) {
        store = defaults
    }

    func overrides(for scope: TableScope) -> [String: ImportMappingOverride] {
        store.read(PreferenceKeys.importColumnMapping(scope)).value ?? [:]
    }

    func remember(_ overrides: [String: ImportMappingOverride], forFields fields: [String], in scope: TableScope) {
        let merged = ImportColumnMatcher.merging(overrides, forFields: fields, into: self.overrides(for: scope))
        let key = PreferenceKeys.importColumnMapping(scope)
        guard !merged.isEmpty else {
            store.removeValue(for: key)
            return
        }
        do {
            try store.write(merged, to: key)
        } catch {
            store.removeValue(for: key)
        }
    }

    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        store.moveValue(
            fromKey: PreferenceKeys.importColumnMapping(oldScope).name,
            toKey: PreferenceKeys.importColumnMapping(newScope).name
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
        store.removeValue(for: PreferenceKeys.importColumnMapping(scope))
    }

    func dropContainer(connectionId: UUID, database: String, schema: String?) {
        store.removeValues(
            withPrefix: Self.keyPrefix
                + TableScope.storagePrefix(connectionId: connectionId, database: database, schema: schema)
        )
    }

    func purgeConnections(_ connectionIds: Set<UUID>) {
        for connectionId in connectionIds {
            store.removeValues(withPrefix: Self.keyPrefix + TableScope.storagePrefix(connectionId: connectionId))
        }
    }
}
