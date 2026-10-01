//
//  ColumnLayoutPersister.swift
//  TablePro
//

import Foundation
import os
import TableProSyncTransport

@MainActor
final class FileColumnLayoutPersister: ColumnLayoutPersisting, TableScopedSettingsStore {
    static let shared: FileColumnLayoutPersister = {
        let persister = FileColumnLayoutPersister()
        persister.performScopeMigration()
        return persister
    }()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ColumnLayoutPersister")
    private static let legacyUserDefaultsPrefix = "com.TablePro.columns.layout."
    private static let legacyVisibilityPrefix = "com.TablePro.columns.hiddenColumns."
    private static let scopeMigrationKey = "com.TablePro.columnLayoutSchemaScopeMigrationComplete"

    private struct PersistedColumnLayout: Codable {
        var columnWidths: [String: CGFloat]
        var columnContentWidths: [String: CGFloat]?
        var columnOrder: [String]?
        var hiddenColumns: [String]?
    }

    nonisolated static let syncCategoryPrefix = "columnLayout."

    private let storageDirectory: URL
    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cache: [UUID: [String: PersistedColumnLayout]] = [:]

    init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard, syncTracker: SyncChangeTracker = .shared) {
        self.storageDirectory = storageDirectory ?? Self.resolvedStorageDirectory()
        self.defaults = defaults
        self.syncTracker = syncTracker

        do {
            try FileManager.default.createDirectory(
                at: self.storageDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            Self.logger.error("Failed to create storage directory: \(error.localizedDescription)")
        }
    }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {
        guard !layout.columnWidths.isEmpty
            || layout.columnContentWidths?.isEmpty == false
            || layout.columnOrder != nil
        else { return }

        var entries = loadEntries(for: key.connectionId)
        var entry = entries[key.storageKey] ?? PersistedColumnLayout(
            columnWidths: [:],
            columnContentWidths: nil,
            columnOrder: nil,
            hiddenColumns: nil
        )
        entry.columnWidths = layout.columnWidths
        entry.columnContentWidths = layout.columnContentWidths
        entry.columnOrder = ColumnLayoutState.mergedColumnOrder(
            current: entry.columnOrder,
            incoming: layout.columnOrder
        )
        entries[key.storageKey] = entry
        cache[key.connectionId] = entries
        writeEntries(entries, for: key.connectionId)
        syncTracker.markDirty(.settings, id: Self.syncCategory(for: key.storageKey))
    }

    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? {
        let entries = loadEntries(for: key.connectionId)
        guard let persisted = entries[key.storageKey],
              !persisted.columnWidths.isEmpty
              || persisted.columnContentWidths?.isEmpty == false
              || persisted.columnOrder != nil
        else { return nil }

        var state = ColumnLayoutState()
        state.columnWidths = persisted.columnWidths
        state.columnContentWidths = persisted.columnContentWidths
        state.columnOrder = persisted.columnOrder
        return state
    }

    func loadHiddenColumns(for key: ColumnLayoutTableKey) -> Set<String> {
        let entries = loadEntries(for: key.connectionId)
        if let hidden = entries[key.storageKey]?.hiddenColumns {
            return Set(hidden)
        }
        return migrateLegacyHidden(for: key)
    }

    func saveHiddenColumns(_ hidden: Set<String>, for key: ColumnLayoutTableKey) {
        removeLegacyHidden(for: key)

        var entries = loadEntries(for: key.connectionId)
        var entry = entries[key.storageKey] ?? PersistedColumnLayout(
            columnWidths: [:],
            columnContentWidths: nil,
            columnOrder: nil,
            hiddenColumns: nil
        )
        entry.hiddenColumns = hidden.isEmpty ? nil : Array(hidden)

        if entry.columnWidths.isEmpty,
           entry.columnContentWidths?.isEmpty != false,
           entry.columnOrder == nil,
           entry.hiddenColumns == nil {
            clear(for: key)
            return
        }

        entries[key.storageKey] = entry
        cache[key.connectionId] = entries
        writeEntries(entries, for: key.connectionId)
        syncTracker.markDirty(.settings, id: Self.syncCategory(for: key.storageKey))
    }

    /// Moves a table's saved widths, order and hidden columns onto its new name.
    ///
    /// Persisted before either sync marker is written, because `markDeleted` posts a change
    /// notification that can start a sync, and a sync reading the old file would put the entry
    /// back under the name that has gone.
    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        let oldKey = oldScope.storageComponent
        let newKey = newScope.storageComponent
        guard oldKey != newKey else { return }
        var entries = loadEntries(for: oldScope.connectionId)
        guard let entry = entries.removeValue(forKey: oldKey) else { return }
        entries[newKey] = entry
        cache[oldScope.connectionId] = entries
        writeEntries(entries, for: oldScope.connectionId)
        syncTracker.markDirty(.settings, id: Self.syncCategory(for: newKey))
        syncTracker.markDeleted(.settings, ids: [Self.syncCategory(for: oldKey)], owner: oldScope.connectionId)
    }

    /// Moves every table's saved layout from one container to another. Same prefix rewrite as the
    /// filter store, and for the same reason: the tables that have a layout are whatever the user
    /// has opened over the life of the connection, not what is loaded now.
    func renameContainer(
        connectionId: UUID,
        fromDatabase: String,
        fromSchema: String?,
        toDatabase: String,
        toSchema: String?
    ) {
        let oldPrefix = TableScope.storagePrefix(
            connectionId: connectionId, database: fromDatabase, schema: fromSchema
        )
        let newPrefix = TableScope.storagePrefix(
            connectionId: connectionId, database: toDatabase, schema: toSchema
        )
        guard oldPrefix != newPrefix else { return }

        var entries = loadEntries(for: connectionId)
        let moving = entries.keys.filter { $0.hasPrefix(oldPrefix) }
        guard !moving.isEmpty else { return }
        for key in moving {
            let moved = newPrefix + key.dropFirst(oldPrefix.count)
            entries[moved] = entries.removeValue(forKey: key)
        }
        cache[connectionId] = entries
        writeEntries(entries, for: connectionId)
        for key in moving {
            syncTracker.markDirty(.settings, id: Self.syncCategory(for: newPrefix + key.dropFirst(oldPrefix.count)))
            syncTracker.markDeleted(.settings, ids: [Self.syncCategory(for: key)], owner: connectionId)
        }
    }

    func dropTable(_ scope: TableScope) {
        guard let database = scope.database else { return }
        clear(for: ColumnLayoutTableKey(
            connectionId: scope.connectionId,
            databaseName: database,
            schemaName: scope.schema,
            tableName: scope.table
        ))
    }

    /// Drops every table's layout under a container. The sync deletions go out after the file is
    /// written, not before, so a sync fired by the notification cannot read the entries back off a
    /// stale file and re-upload them.
    func dropContainer(connectionId: UUID, database: String, schema: String?) {
        let prefix = TableScope.storagePrefix(connectionId: connectionId, database: database, schema: schema)
        var entries = loadEntries(for: connectionId)
        let dropping = entries.keys.filter { $0.hasPrefix(prefix) }
        guard !dropping.isEmpty else { return }
        for key in dropping {
            entries.removeValue(forKey: key)
        }

        guard store(entries, for: connectionId) else { return }
        syncTracker.markDeleted(.settings, ids: dropping.map(Self.syncCategory(for:)), owner: connectionId)
    }

    func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool) {
        var categoriesByConnection: [UUID: Set<String>] = [:]
        for connectionId in connectionIds {
            categoriesByConnection[connectionId] = Set(loadEntries(for: connectionId).keys.map(Self.syncCategory(for:)))
            cache[connectionId] = [:]
            removeFile(for: connectionId)
        }
        /// The dirty marks go either way. A tombstone from a remote delete would push the sender's
        /// own deletion back at it, but leaving the ids dirty means the next push looks for entries
        /// that are gone and never drains them.
        if leavesTombstones {
            syncTracker.markDeleted(.settings, idsByOwner: categoriesByConnection)
        } else {
            syncTracker.discardDirty(.settings, ids: categoriesByConnection.values.flatMap { $0 })
        }
    }

    func clear(for key: ColumnLayoutTableKey) {
        removeLegacyHidden(for: key)

        var entries = loadEntries(for: key.connectionId)
        guard entries.removeValue(forKey: key.storageKey) != nil else { return }

        guard store(entries, for: key.connectionId) else { return }
        syncTracker.markDeleted(.settings, ids: [Self.syncCategory(for: key.storageKey)], owner: key.connectionId)
    }

    func clearGeometry(for key: ColumnLayoutTableKey) {
        var entries = loadEntries(for: key.connectionId)
        guard var entry = entries[key.storageKey] else { return }
        entry.columnWidths = [:]
        entry.columnContentWidths = nil
        entry.columnOrder = nil

        if entry.hiddenColumns?.isEmpty == false {
            entries[key.storageKey] = entry
            cache[key.connectionId] = entries
            writeEntries(entries, for: key.connectionId)
            syncTracker.markDirty(.settings, id: Self.syncCategory(for: key.storageKey))
        } else {
            entries.removeValue(forKey: key.storageKey)
            guard store(entries, for: key.connectionId) else { return }
            syncTracker.markDeleted(.settings, ids: [Self.syncCategory(for: key.storageKey)], owner: key.connectionId)
        }
    }

    static func syncCategory(for storageKey: String) -> String {
        syncCategoryPrefix + storageKey
    }

    nonisolated static func connectionId(ofSyncCategory category: String) -> UUID? {
        guard category.hasPrefix(syncCategoryPrefix) else { return nil }
        return TableScope(storageComponent: String(category.dropFirst(syncCategoryPrefix.count)))?.connectionId
    }

    func storageKeys(forSyncRecordNames recordNames: Set<String>) -> [String] {
        let layoutPrefix = SyncRecordType.settings.recordNamePrefix + Self.syncCategoryPrefix
        let digestPrefix = SyncRecordType.settings.recordNamePrefix + SyncRecordName.digestPrefix
        let named = recordNames.filter { $0.hasPrefix(layoutPrefix) }.map { String($0.dropFirst(layoutPrefix.count)) }
        let digested = recordNames.filter { $0.hasPrefix(digestPrefix) }
        guard !digested.isEmpty else { return named }
        return named + customizedStorageKeys().filter { storageKey in
            digested.contains(SyncRecordType.settings.recordName(for: Self.syncCategory(for: storageKey)))
        }
    }

    func removeWithoutSync(storageKeys: [String]) -> Bool {
        let scoped = storageKeys.compactMap { key in TableScope(storageComponent: key).map { (key, $0.connectionId) } }
        var persisted = true
        for (connectionId, keys) in Dictionary(grouping: scoped, by: \.1) {
            var entries = loadEntries(for: connectionId)
            let removed = keys.map(\.0).filter { entries.removeValue(forKey: $0) != nil }
            guard !removed.isEmpty else { continue }
            guard store(entries, for: connectionId) else {
                persisted = false
                continue
            }
            removed.forEach(removeLegacyHidden(storageKey:))
            syncTracker.discardDirty(.settings, ids: removed.map(Self.syncCategory(for:)))
        }
        return persisted
    }

    func rawData(forStorageKey storageKey: String) -> Data? {
        guard let scope = TableScope(storageComponent: storageKey),
              let entry = loadEntries(for: scope.connectionId)[storageKey] else { return nil }
        return try? encoder.encode(entry)
    }

    func applyRemote(storageKey: String, data: Data) {
        guard let scope = TableScope(storageComponent: storageKey),
              let entry = try? decoder.decode(PersistedColumnLayout.self, from: data) else { return }
        var entries = loadEntries(for: scope.connectionId)
        entries[storageKey] = entry
        cache[scope.connectionId] = entries
        writeEntries(entries, for: scope.connectionId)
    }

    func customizedStorageKeys() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var keys: [String] = []
        for file in files where file.pathExtension == "json" {
            guard let connectionId = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            keys.append(contentsOf: loadEntries(for: connectionId).keys)
        }
        return keys
    }

    private func migrateLegacyHidden(for key: ColumnLayoutTableKey) -> Set<String> {
        guard let array = defaults.stringArray(forKey: Self.legacyVisibilityPrefix + key.storageKey),
              !array.isEmpty else { return [] }
        let hidden = Set(array)
        saveHiddenColumns(hidden, for: key)
        return hidden
    }

    private func removeLegacyHidden(for key: ColumnLayoutTableKey) {
        removeLegacyHidden(storageKey: key.storageKey)
    }

    private func removeLegacyHidden(storageKey: String) {
        defaults.removeObject(forKey: Self.legacyVisibilityPrefix + storageKey)
    }

    @discardableResult
    private func store(_ entries: [String: PersistedColumnLayout], for connectionId: UUID) -> Bool {
        let stored = entries.isEmpty ? removeFile(for: connectionId) : writeEntries(entries, for: connectionId)
        cache[connectionId] = stored ? entries : nil
        return stored
    }

    private func loadEntries(for connectionId: UUID) -> [String: PersistedColumnLayout] {
        if let cached = cache[connectionId] { return cached }

        let fileURL = fileURL(for: connectionId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache[connectionId] = [:]
            return [:]
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let entries = try decoder.decode([String: PersistedColumnLayout].self, from: data)
            cache[connectionId] = entries
            return entries
        } catch {
            Self.logger.error(
                "Failed to load column layouts for \(connectionId): \(error.localizedDescription)"
            )
            cache[connectionId] = [:]
            return [:]
        }
    }

    @discardableResult
    private func writeEntries(_ entries: [String: PersistedColumnLayout], for connectionId: UUID) -> Bool {
        let fileURL = fileURL(for: connectionId)
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            Self.logger.error(
                "Failed to write column layouts for \(connectionId): \(error.localizedDescription)"
            )
            return false
        }
    }

    @discardableResult
    private func removeFile(for connectionId: UUID) -> Bool {
        let fileURL = fileURL(for: connectionId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            Self.logger.error(
                "Failed to remove column layout file for \(connectionId): \(error.localizedDescription)"
            )
            return false
        }
    }

    private func fileURL(for connectionId: UUID) -> URL {
        storageDirectory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    private static func resolvedStorageDirectory() -> URL {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        return appSupport
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("ColumnLayout", isDirectory: true)
    }

    private func performScopeMigration() {
        guard !defaults.bool(forKey: Self.scopeMigrationKey) else { return }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }

        let legacyKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(Self.legacyUserDefaultsPrefix) || $0.hasPrefix(Self.legacyVisibilityPrefix)
        }
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }

        defaults.set(true, forKey: Self.scopeMigrationKey)
    }
}
