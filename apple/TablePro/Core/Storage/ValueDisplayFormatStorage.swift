//
//  ValueDisplayFormatStorage.swift
//  TablePro
//

import Foundation

// 0.83 decodes a table's formats as one dictionary and drops all of them on a name it does not know, so a
// format added since lives in a second key under the same prefix. Each key is read entry by entry, the first
// wins for a column in both (0.83 writes only the first), and a name this build does not know is kept.
@MainActor
internal final class ValueDisplayFormatStorage: TableScopedSettingsStore {
    static let shared = ValueDisplayFormatStorage()

    private static let namesReadBy083: Set<String> = [
        "raw", "text", "uuid", "uuidSwappedTime", "unixTimestamp", "unixTimestampMillis", "json", "phpSerialized",
        "messagePack", "protobuf",
    ]

    private let store: KeyValueStore
    private let schemas: AvroSchemaStore

    init(defaults: KeyValueStore = AppStorageEnvironment.shared.defaults, schemas: AvroSchemaStore = .shared) {
        store = defaults
        self.schemas = schemas
    }

    func save(_ formats: [String: ValueDisplayFormat], for scope: TableScope) {
        let key = Self.key(for: scope)
        let addedKey = Self.addedKey(for: scope)
        var first: [String: String] = [:]
        var added = (Self.names(store.dataValue(forKey: addedKey)) ?? [:])
            .filter { ValueDisplayFormat(rawValue: $0.value) == nil && formats[$0.key] == nil }
        for (column, format) in formats {
            if Self.namesReadBy083.contains(format.rawValue) {
                first[column] = format.rawValue
            } else {
                added[column] = format.rawValue
            }
        }
        write(first, forKey: key)
        write(added, forKey: addedKey)
        removeLegacy(for: scope)
        sweepSchemas()
    }

    func load(for scope: TableScope) -> [String: ValueDisplayFormat]? {
        let first = Self.names(store.dataValue(forKey: Self.key(for: scope)))
        let added = Self.names(store.dataValue(forKey: Self.addedKey(for: scope)))
        guard first != nil || added != nil else { return migrateLegacy(for: scope) }
        let names = (added ?? [:]).merging(first ?? [:]) { _, firstName in firstName }
        return names.compactMapValues(ValueDisplayFormat.init(rawValue:))
    }

    func clear(for scope: TableScope) {
        store.setDataValue(nil, forKey: Self.key(for: scope))
        store.setDataValue(nil, forKey: Self.addedKey(for: scope))
        removeLegacy(for: scope)
        sweepSchemas()
    }

    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        let oldKey = Self.key(for: oldScope)
        if store.dataValue(forKey: oldKey) == nil {
            migrateLegacy(for: oldScope)
        }
        store.moveValue(fromKey: oldKey, toKey: Self.key(for: newScope))
        store.moveValue(fromKey: Self.addedKey(for: oldScope), toKey: Self.addedKey(for: newScope))
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
        clear(for: scope)
    }

    // The legacy key names no database or schema, so nothing here can tell which container it belonged to,
    // and sweeping the connection's would take the formats of tables in databases that still exist.
    // `dropTable` clears it, because there the table is named.
    func dropContainer(connectionId: UUID, database: String, schema: String?) {
        store.removeValues(
            withPrefix: Self.keyPrefix
                + TableScope.storagePrefix(connectionId: connectionId, database: database, schema: schema)
        )
        sweepSchemas()
    }

    func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool) {
        for connectionId in connectionIds {
            store.removeValues(withPrefix: Self.keyPrefix + TableScope.storagePrefix(connectionId: connectionId))
            store.removeValues(withPrefix: Self.legacyKeyPrefix(for: connectionId))
        }
        sweepSchemas()
    }

    // A schema file lives as long as a saved format names it.
    private func sweepSchemas() {
        guard !schemas.storedIDs.isEmpty else { return }
        var named: Set<String> = []
        for key in store.keys(withPrefix: Self.keyPrefix) where key.hasSuffix(Self.addedSuffix) {
            for name in (Self.names(store.dataValue(forKey: key)) ?? [:]).values {
                if case .avro(let schemaID)? = ValueDisplayFormat(rawValue: name) { named.insert(schemaID) }
            }
        }
        schemas.removeAll(except: named)
    }

    @discardableResult
    private func migrateLegacy(for scope: TableScope) -> [String: ValueDisplayFormat]? {
        let legacyKey = Self.legacyKey(for: scope)
        guard let names = Self.names(store.dataValue(forKey: legacyKey)), !names.isEmpty else { return nil }
        write(names, forKey: Self.key(for: scope))
        store.setDataValue(nil, forKey: legacyKey)
        return names.compactMapValues(ValueDisplayFormat.init(rawValue:))
    }

    private func write(_ names: [String: String], forKey key: String) {
        guard !names.isEmpty, let data = try? JSONEncoder().encode(names) else {
            store.setDataValue(nil, forKey: key)
            return
        }
        store.setDataValue(data, forKey: key)
    }

    private func removeLegacy(for scope: TableScope) {
        store.setDataValue(nil, forKey: Self.legacyKey(for: scope))
    }

    private static func names(_ data: Data?) -> [String: String]? {
        data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    private static let keyPrefix = PreferenceKeys.columnDisplayFormatsPrefix

    // A table key is four dot-joined, percent-encoded parts, so a fifth part never names another table.
    private static let addedSuffix = ".added"

    private static func key(for scope: TableScope) -> String {
        PreferenceKeys.columnDisplayFormats(scope).name
    }

    private static func addedKey(for scope: TableScope) -> String {
        key(for: scope) + addedSuffix
    }

    private static func legacyKey(for scope: TableScope) -> String {
        legacyKeyPrefix(for: scope.connectionId) + scope.table
    }

    private static func legacyKeyPrefix(for connectionId: UUID) -> String {
        "\(keyPrefix)\(connectionId.uuidString)."
    }
}
