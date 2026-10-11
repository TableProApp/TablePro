//
//  ImportColumnMappingStore.swift
//  TablePro
//

import Foundation

/// Keyed by the table rather than the file, because the same export is downloaded again under new
/// names. Device-local, so it needs no CloudKit record type.
@MainActor
internal final class ImportColumnMappingStore: TableScopedSettingsStore {
    static let shared = ImportColumnMappingStore()

    private static let keyPrefix = PreferenceKeys.importColumnMappingPrefix

    private let store: KeyValueStore

    init(defaults: KeyValueStore = AppStorageEnvironment.shared.defaults) {
        store = defaults
    }

    func overrides(for scope: TableScope) -> [String: ImportMappingOverride] {
        guard let data = store.dataValue(forKey: PreferenceKeys.importColumnMapping(scope).name),
              let overrides = try? JSONDecoder().decode([String: ImportMappingOverride].self, from: data) else {
            return [:]
        }
        return overrides
    }

    func remember(_ overrides: [String: ImportMappingOverride], forFields fields: [String], in scope: TableScope) {
        let merged = ImportColumnMatcher.merging(overrides, forFields: fields, into: self.overrides(for: scope))
        let key = PreferenceKeys.importColumnMapping(scope).name
        guard !merged.isEmpty, let data = try? JSONEncoder().encode(merged) else {
            store.setDataValue(nil, forKey: key)
            return
        }
        store.setDataValue(data, forKey: key)
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
        store.setDataValue(nil, forKey: PreferenceKeys.importColumnMapping(scope).name)
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
