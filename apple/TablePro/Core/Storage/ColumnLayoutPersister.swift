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
        var frozenColumnCount: Int?
    }

    nonisolated static let syncCategoryPrefix = "columnLayout."

    private let storageDirectory: URL
    private let defaults: UserDefaults
    private let syncJournal: SyncHostJournal
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cache: [UUID: [String: PersistedColumnLayout]] = [:]

    init(storageDirectory: URL? = nil, defaults: UserDefaults = AppStorageEnvironment.shared.defaults, syncJournal: SyncHostJournal = .shared) {
        self.storageDirectory = storageDirectory ?? Self.resolvedStorageDirectory()
        self.defaults = defaults
        self.syncJournal = syncJournal

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
            || layout.frozenColumnCount > 0
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
        entry.frozenColumnCount = layout.frozenColumnCount > 0 ? layout.frozenColumnCount : nil
        entries[key.storageKey] = entry
        cache[key.connectionId] = entries
        writeEntries(entries, for: key.connectionId)
        syncJournal.recorded(.settings, written: [Self.syncCategory(for: key.storageKey)])
    }

    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? {
        let entries = loadEntries(for: key.connectionId)
        guard let persisted = entries[key.storageKey],
              !persisted.columnWidths.isEmpty
              || persisted.columnContentWidths?.isEmpty == false
              || persisted.columnOrder != nil
              || (persisted.frozenColumnCount ?? 0) > 0
        else { return nil }

        var state = ColumnLayoutState()
        state.columnWidths = persisted.columnWidths
        state.columnContentWidths = persisted.columnContentWidths
        state.columnOrder = persisted.columnOrder
        state.frozenColumnCount = max(0, persisted.frozenColumnCount ?? 0)
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
           entry.frozenColumnCount == nil,
           entry.hiddenColumns == nil {
            clear(for: key)
            return
        }

        entries[key.storageKey] = entry
        cache[key.connectionId] = entries
        writeEntries(entries, for: key.connectionId)
        syncJournal.recorded(.settings, written: [Self.syncCategory(for: key.storageKey)])
    }

    /// Moves a table's saved widths, order and hidden columns onto its new name.
    func renameTable(from oldScope: TableScope, to newScope: TableScope) {
        let oldKey = oldScope.storageComponent
        let newKey = newScope.storageComponent
        guard oldKey != newKey else { return }
        var entries = loadEntries(for: oldScope.connectionId)
        guard let entry = entries.removeValue(forKey: oldKey) else { return }
        entries[newKey] = entry
        cache[oldScope.connectionId] = entries
        writeEntries(entries, for: oldScope.connectionId)
        syncJournal.recorded(.settings, written: [Self.syncCategory(for: newKey)], deleted: [Self.syncCategory(for: oldKey)])
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
        syncJournal.recorded(
            .settings,
            written: moving.map { Self.syncCategory(for: newPrefix + $0.dropFirst(oldPrefix.count)) },
            deleted: moving.map(Self.syncCategory(for:))
        )
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

    /// Drops every table's layout under a container.
    func dropContainer(connectionId: UUID, database: String, schema: String?) {
        let prefix = TableScope.storagePrefix(connectionId: connectionId, database: database, schema: schema)
        var entries = loadEntries(for: connectionId)
        let dropping = entries.keys.filter { $0.hasPrefix(prefix) }
        guard !dropping.isEmpty else { return }
        for key in dropping {
            entries.removeValue(forKey: key)
        }

        guard store(entries, for: connectionId) else { return }
        syncJournal.recorded(.settings, deleted: dropping.map(Self.syncCategory(for:)))
    }

    func purgeConnections(_ connectionIds: Set<UUID>) {
        var categories: [String] = []
        for connectionId in connectionIds {
            categories += loadEntries(for: connectionId).keys.map(Self.syncCategory(for:))
            cache[connectionId] = [:]
            removeFile(for: connectionId)
        }
        syncJournal.recorded(.settings, deleted: categories)
    }

    func clear(for key: ColumnLayoutTableKey) {
        removeLegacyHidden(for: key)

        var entries = loadEntries(for: key.connectionId)
        guard entries.removeValue(forKey: key.storageKey) != nil else { return }

        guard store(entries, for: key.connectionId) else { return }
        syncJournal.recorded(.settings, deleted: [Self.syncCategory(for: key.storageKey)])
    }

    func clearGeometry(for key: ColumnLayoutTableKey) {
        var entries = loadEntries(for: key.connectionId)
        guard var entry = entries[key.storageKey] else { return }
        entry.columnWidths = [:]
        entry.columnContentWidths = nil
        entry.columnOrder = nil
        entry.frozenColumnCount = nil

        if entry.hiddenColumns?.isEmpty == false {
            entries[key.storageKey] = entry
            cache[key.connectionId] = entries
            writeEntries(entries, for: key.connectionId)
            syncJournal.recorded(.settings, written: [Self.syncCategory(for: key.storageKey)])
        } else {
            entries.removeValue(forKey: key.storageKey)
            guard store(entries, for: key.connectionId) else { return }
            syncJournal.recorded(.settings, deleted: [Self.syncCategory(for: key.storageKey)])
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

    // MARK: - Sync

    // Every layout the files hold, read from disk rather than the cache, which a failed load leaves empty. A file it
    // cannot read fails the read, so a damaged file stops the pass instead of reading as layouts removed on every Mac.
    func syncedLayouts() throws -> [String: Data] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        }
        var layouts: [String: Data] = [:]
        for file in files where file.pathExtension == "json" {
            guard let connectionId = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            for (storageKey, entry) in try readEntries(for: connectionId) {
                layouts[storageKey] = try encoder.encode(entry)
            }
        }
        return layouts
    }

    func syncedLayout(storageKey: String) throws -> Data? {
        guard let scope = TableScope(storageComponent: storageKey) else { return nil }
        return try readEntries(for: scope.connectionId)[storageKey].map { try encoder.encode($0) }
    }

    // False when the document is no layout. A file this Mac cannot read is never written over, and the cache takes the
    // layout only once it is on disk, so a failed write is tried again instead of read back as stored.
    func applyPulled(storageKey: String, data: Data) throws -> Bool {
        guard let scope = TableScope(storageComponent: storageKey),
              let entry = try? decoder.decode(PersistedColumnLayout.self, from: data)
        else { return false }
        var entries = try readEntries(for: scope.connectionId)
        entries[storageKey] = entry
        try persist(entries, for: scope.connectionId)
        cache[scope.connectionId] = entries
        return true
    }

    func removePulled(storageKey: String) throws {
        guard let scope = TableScope(storageComponent: storageKey) else { return }
        var entries = try readEntries(for: scope.connectionId)
        guard entries.removeValue(forKey: storageKey) != nil else { return }
        if entries.isEmpty {
            try deleteFile(for: scope.connectionId)
        } else {
            try persist(entries, for: scope.connectionId)
        }
        cache[scope.connectionId] = entries
        removeLegacyHidden(storageKey: storageKey)
    }

    private func readEntries(for connectionId: UUID) throws -> [String: PersistedColumnLayout] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL(for: connectionId))
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        }
        return try decoder.decode([String: PersistedColumnLayout].self, from: data)
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

    private func persist(_ entries: [String: PersistedColumnLayout], for connectionId: UUID) throws {
        try encoder.encode(entries).write(to: fileURL(for: connectionId), options: .atomic)
    }

    private func deleteFile(for connectionId: UUID) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(for: connectionId))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    @discardableResult
    private func writeEntries(_ entries: [String: PersistedColumnLayout], for connectionId: UUID) -> Bool {
        do {
            try persist(entries, for: connectionId)
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
