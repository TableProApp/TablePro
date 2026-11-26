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
    private let protobufSchemas: ProtobufSchemaStore

    init(
        defaults: KeyValueStore = AppStorageEnvironment.shared.defaults,
        schemas: AvroSchemaStore = .shared,
        protobufSchemas: ProtobufSchemaStore = .shared
    ) {
        store = defaults
        self.schemas = schemas
        self.protobufSchemas = protobufSchemas
    }

    func save(_ formats: [String: ValueDisplayFormat], for scope: TableScope) {
        let key = Self.key(for: scope)
        let addedKey = Self.addedKey(for: scope)
        var first: [String: String] = [:]
        var added = (store.read(addedKey).value ?? [:])
            .filter { ValueDisplayFormat(rawValue: $0.value) == nil && formats[$0.key] == nil }
        for (column, format) in formats {
            if Self.namesReadBy083.contains(format.rawValue) {
                first[column] = format.rawValue
            } else {
                added[column] = format.rawValue
            }
        }
        write(first, to: key)
        write(added, to: addedKey)
        removeLegacy(for: scope)
        sweepSchemas()
    }

    func load(for scope: TableScope) -> [String: ValueDisplayFormat]? {
        let first = store.read(Self.key(for: scope)).value
        let added = store.read(Self.addedKey(for: scope)).value
        guard first != nil || added != nil else { return migrateLegacy(for: scope) }
        let names = (added ?? [:]).merging(first ?? [:]) { _, firstName in firstName }
        return names.compactMapValues(ValueDisplayFormat.init(rawValue:))
    }

    func clear(for scope: TableScope) {
        store.removeValue(for: Self.key(for: scope))
        store.removeValue(for: Self.addedKey(for: scope))
        removeLegacy(for: scope)
        sweepSchemas()
    }

    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        let oldKey = Self.key(for: oldScope).name
        if store.dataValue(forKey: oldKey) == nil {
            migrateLegacy(for: oldScope)
        }
        store.moveValue(fromKey: oldKey, toKey: Self.key(for: newScope).name)
        store.moveValue(fromKey: Self.addedKey(for: oldScope).name, toKey: Self.addedKey(for: newScope).name)
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

    func purgeConnections(_ connectionIds: Set<UUID>) {
        for connectionId in connectionIds {
            store.removeValues(withPrefix: Self.keyPrefix + TableScope.storagePrefix(connectionId: connectionId))
            store.removeValues(withPrefix: Self.legacyKeyPrefix(for: connectionId))
        }
        sweepSchemas()
    }

    // A schema file lives as long as a saved format names it.
    private func sweepSchemas() {
        guard !schemas.storedIDs.isEmpty || !protobufSchemas.storedIDs.isEmpty else { return }
        var avro: Set<String> = []
        var protobuf: Set<String> = []
        for key in store.keys(withPrefix: Self.keyPrefix) where key.hasSuffix(Self.addedSuffix) {
            for name in (store.read(JSONDefaultsKey<[String: String]>(key)).value ?? [:]).values {
                switch ValueDisplayFormat(rawValue: name) {
                case .avro(let schemaID)?: avro.insert(schemaID)
                case .protobufSchema(let schemaID, _)?: protobuf.insert(schemaID)
                default: break
                }
            }
        }
        schemas.removeAll(except: avro)
        protobufSchemas.removeAll(except: protobuf)
    }

    @discardableResult
    private func migrateLegacy(for scope: TableScope) -> [String: ValueDisplayFormat]? {
        let legacyKey = Self.legacyKey(for: scope)
        guard let names = store.read(legacyKey).value, !names.isEmpty else { return nil }
        write(names, to: Self.key(for: scope))
        store.removeValue(for: legacyKey)
        return names.compactMapValues(ValueDisplayFormat.init(rawValue:))
    }

    private func write(_ names: [String: String], to key: JSONDefaultsKey<[String: String]>) {
        guard !names.isEmpty else {
            store.removeValue(for: key)
            return
        }
        do {
            try store.write(names, to: key)
        } catch {
            store.removeValue(for: key)
        }
    }

    private func removeLegacy(for scope: TableScope) {
        store.removeValue(for: Self.legacyKey(for: scope))
    }

    private static let keyPrefix = PreferenceKeys.columnDisplayFormatsPrefix

    // A table key is four dot-joined, percent-encoded parts, so a fifth part never names another table.
    private static let addedSuffix = ".added"

    private static func key(for scope: TableScope) -> JSONDefaultsKey<[String: String]> {
        PreferenceKeys.columnDisplayFormats(scope)
    }

    private static func addedKey(for scope: TableScope) -> JSONDefaultsKey<[String: String]> {
        JSONDefaultsKey(key(for: scope).name + addedSuffix)
    }

    private static func legacyKey(for scope: TableScope) -> JSONDefaultsKey<[String: String]> {
        JSONDefaultsKey(legacyKeyPrefix(for: scope.connectionId) + scope.table)
    }

    private static func legacyKeyPrefix(for connectionId: UUID) -> String {
        "\(keyPrefix)\(connectionId.uuidString)."
    }
}
