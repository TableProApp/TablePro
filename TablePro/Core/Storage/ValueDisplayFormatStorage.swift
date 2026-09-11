//
//  ValueDisplayFormatStorage.swift
//  TablePro
//

import Foundation

@MainActor
internal final class ValueDisplayFormatStorage: TableScopedSettingsStore {
    static let shared = ValueDisplayFormatStorage()

    private let store: KeyValueStore

    init(defaults: KeyValueStore = AppStorageEnvironment.shared.defaults) {
        store = defaults
    }

    func save(_ formats: [String: ValueDisplayFormat], for scope: TableScope) {
        guard !formats.isEmpty else {
            clear(for: scope)
            return
        }
        guard let data = try? JSONEncoder().encode(formats) else { return }
        store.setDataValue(data, forKey: PreferenceKeys.columnDisplayFormats(scope).name)
        removeLegacy(for: scope)
    }

    func load(for scope: TableScope) -> [String: ValueDisplayFormat]? {
        if let data = store.dataValue(forKey: PreferenceKeys.columnDisplayFormats(scope).name),
           let formats = try? JSONDecoder().decode([String: ValueDisplayFormat].self, from: data) {
            return formats
        }
        return migrateLegacy(for: scope)
    }

    func clear(for scope: TableScope) {
        store.setDataValue(nil, forKey: PreferenceKeys.columnDisplayFormats(scope).name)
        removeLegacy(for: scope)
    }

    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        let oldKey = PreferenceKeys.columnDisplayFormats(oldScope).name
        if store.dataValue(forKey: oldKey) == nil {
            migrateLegacy(for: oldScope)
        }
        store.moveValue(fromKey: oldKey, toKey: PreferenceKeys.columnDisplayFormats(newScope).name)
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
            store.removeValues(withPrefix: Self.legacyKeyPrefix(for: connectionId))
        }
    }

    @discardableResult
    private func migrateLegacy(for scope: TableScope) -> [String: ValueDisplayFormat]? {
        let legacyKey = Self.legacyKey(for: scope)
        guard let data = store.dataValue(forKey: legacyKey),
              let formats = try? JSONDecoder().decode([String: ValueDisplayFormat].self, from: data),
              !formats.isEmpty else {
            return nil
        }
        if let encoded = try? JSONEncoder().encode(formats) {
            store.setDataValue(encoded, forKey: PreferenceKeys.columnDisplayFormats(scope).name)
        }
        store.setDataValue(nil, forKey: legacyKey)
        return formats
    }

    private func removeLegacy(for scope: TableScope) {
        store.setDataValue(nil, forKey: Self.legacyKey(for: scope))
    }

    private static let keyPrefix = PreferenceKeys.columnDisplayFormatsPrefix

    private static func legacyKey(for scope: TableScope) -> String {
        legacyKeyPrefix(for: scope.connectionId) + scope.table
    }

    private static func legacyKeyPrefix(for connectionId: UUID) -> String {
        "\(keyPrefix)\(connectionId.uuidString)."
    }
}
