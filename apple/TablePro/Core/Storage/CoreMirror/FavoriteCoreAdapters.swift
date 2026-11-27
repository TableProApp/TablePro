//
//  FavoriteCoreAdapters.swift
//  TablePro
//

import Foundation
import TableProFFI

// The favourite tables in UserDefaults and the core's (core ADR 0010, slice 9). A table is its own key.
internal final class FavoriteTablesCoreAdapter: CoreMirrorAdapter, @unchecked Sendable {
    private weak var store: FavoriteTablesStorage?
    private let database: CoreHistoryDatabase

    init(store: FavoriteTablesStorage, database: CoreHistoryDatabase) {
        self.store = store
        self.database = database
    }

    var name: String { "favoriteTables" }

    func key(of value: FavoriteTablesStorage.FavoriteEntry) -> FavoriteTablesStorage.FavoriteEntry {
        value
    }

    func readLegacy() async -> CoreMirrorLegacyRead<FavoriteTablesStorage.FavoriteEntry>? {
        guard let store else { return nil }
        return CoreMirrorLegacyRead(values: Array(store.loadFavorites()), allowsRemovals: store.storedFavoritesRead)
    }

    func readCore() async throws -> CoreMirrorCoreRead<FavoriteTablesStorage.FavoriteEntry> {
        let contents = try await database.favourites().contents()
        let values = contents.tables.compactMap { record -> FavoriteTablesStorage.FavoriteEntry? in
            guard let connectionId = UUID(uuidString: record.connectionId) else { return nil }
            return FavoriteTablesStorage.FavoriteEntry(
                connectionId: connectionId,
                database: record.database,
                schema: record.schema,
                name: record.name
            )
        }
        return CoreMirrorCoreRead(values: values, digest: contents.digests.tables)
    }

    func writeCore(puts: [FavoriteTablesStorage.FavoriteEntry], removals: [FavoriteTablesStorage.FavoriteEntry]) async throws {
        _ = try await database.favourites().writeRecords(write: FavouriteRecordWrite(
            tables: puts.map(Self.record),
            databases: [],
            removedTables: removals.map(Self.record),
            removedDatabases: []
        ))
    }

    func replaceCore(expected: String, values: [FavoriteTablesStorage.FavoriteEntry]) async throws {
        let store = try await database.favourites()
        try await refusingOutdated {
            _ = try await store.replaceTables(expectedDigest: expected, held: values.map(Self.record))
        }
    }

    func applyToLegacy(
        puts: [FavoriteTablesStorage.FavoriteEntry],
        removals: [FavoriteTablesStorage.FavoriteEntry],
        expected: [FavoriteTablesStorage.FavoriteEntry: FavoriteTablesStorage.FavoriteEntry]
    ) async -> Bool {
        guard let store else { return false }
        // Every write to these favourites runs on the main actor, so the check and the write see the same set.
        return await MainActor.run {
            // A document that does not decode is never written over: what it holds is only unread.
            guard store.storedFavoritesRead else { return false }
            let held = store.loadFavorites()
            guard (puts + removals).allSatisfy({ held.contains($0) == (expected[$0] != nil) }) else { return false }
            store.applyCoreFavorites(puts: puts, removals: removals)
            return true
        }
    }

    func announce(settled: [FavoriteTablesStorage.FavoriteEntry]) async {}

    private static func record(_ entry: FavoriteTablesStorage.FavoriteEntry) -> FavouriteTableRecord {
        FavouriteTableRecord(
            connectionId: entry.connectionId.uuidString,
            database: entry.database,
            schema: entry.schema,
            name: entry.name
        )
    }
}

// The favourite databases in UserDefaults and the core's, keyed by connection and database.
internal final class FavoriteDatabasesCoreAdapter: CoreMirrorAdapter, @unchecked Sendable {
    private weak var store: FavoriteDatabasesStorage?
    private let database: CoreHistoryDatabase

    init(store: FavoriteDatabasesStorage, database: CoreHistoryDatabase) {
        self.store = store
        self.database = database
    }

    var name: String { "favoriteDatabases" }

    func key(of value: FavoriteDatabaseEntry) -> String {
        value.id
    }

    func readLegacy() async -> CoreMirrorLegacyRead<FavoriteDatabaseEntry>? {
        guard let store else { return nil }
        return await MainActor.run {
            CoreMirrorLegacyRead(values: Array(store.loadFavorites()), allowsRemovals: store.storedFavoritesRead)
        }
    }

    func readCore() async throws -> CoreMirrorCoreRead<FavoriteDatabaseEntry> {
        let contents = try await database.favourites().contents()
        let values = contents.databases.compactMap { record -> FavoriteDatabaseEntry? in
            guard let connectionId = UUID(uuidString: record.connectionId) else { return nil }
            return FavoriteDatabaseEntry(
                connectionId: connectionId,
                database: record.database,
                environment: Self.environment(record.environment)
            )
        }
        return CoreMirrorCoreRead(values: values, digest: contents.digests.databases)
    }

    func writeCore(puts: [FavoriteDatabaseEntry], removals: [String]) async throws {
        let removed = removals.compactMap(Self.key(from:))
        _ = try await database.favourites().writeRecords(write: FavouriteRecordWrite(
            tables: [],
            databases: puts.map(Self.record),
            removedTables: [],
            removedDatabases: removed
        ))
    }

    func replaceCore(expected: String, values: [FavoriteDatabaseEntry]) async throws {
        let store = try await database.favourites()
        try await refusingOutdated {
            _ = try await store.replaceDatabases(expectedDigest: expected, held: values.map(Self.record))
        }
    }

    func applyToLegacy(
        puts: [FavoriteDatabaseEntry],
        removals: [String],
        expected: [String: FavoriteDatabaseEntry]
    ) async -> Bool {
        guard let store else { return false }
        return await MainActor.run {
            guard store.storedFavoritesRead else { return false }
            let held = Dictionary(store.loadFavorites().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard (puts.map(\.id) + removals).allSatisfy({ held[$0] == expected[$0] }) else { return false }
            store.applyCoreFavorites(puts: puts, removals: removals)
            return true
        }
    }

    func announce(settled: [FavoriteDatabaseEntry]) async {}

    private static func record(_ entry: FavoriteDatabaseEntry) -> FavouriteDatabaseRecord {
        FavouriteDatabaseRecord(
            connectionId: entry.connectionId.uuidString,
            database: entry.database,
            environment: tag(entry.environment)
        )
    }

    // The entry's id is its connection, then U+0001, then the database name.
    private static func key(from id: String) -> FavouriteDatabaseKey? {
        guard let separator = id.firstIndex(of: "\u{1}") else { return nil }
        return FavouriteDatabaseKey(
            connectionId: String(id[..<separator]),
            database: String(id[id.index(after: separator)...])
        )
    }

    private static func tag(_ environment: FavoriteDatabaseEnvironment) -> DatabaseEnvironmentTag {
        switch environment {
        case .development: .development
        case .testing: .testing
        case .production: .production
        case .unassigned: .unassigned
        }
    }

    private static func environment(_ tag: DatabaseEnvironmentTag) -> FavoriteDatabaseEnvironment {
        switch tag {
        case .development: .development
        case .testing: .testing
        case .production: .production
        case .unassigned: .unassigned
        }
    }
}

internal enum TableFolderMirrorKey: Hashable, Sendable, Encodable {
    case folder(UUID)
    case item(TableFolderItemKey)
}

// A folder's times in whole milliseconds, the precision the core and a CloudKit date keep.
internal enum TableFolderMirrorValue: Equatable, Sendable, Encodable {
    case folder(Folder)
    case item(TableFolderItem)

    internal struct Folder: Equatable, Sendable, Encodable {
        let id: UUID
        let scope: DatabaseScope
        let name: String
        let createdAtMs: Int64
        let updatedAtMs: Int64
    }
}

// The table folders in UserDefaults, one document per connection, and the core's (core ADR 0010, slice 9).
internal final class TableFolderCoreAdapter: CoreMirrorAdapter, @unchecked Sendable {
    private weak var store: TableFolderStorage?
    private let database: CoreHistoryDatabase

    init(store: TableFolderStorage, database: CoreHistoryDatabase) {
        self.store = store
        self.database = database
    }

    var name: String { "tableFolders" }

    func readLegacy() async -> CoreMirrorLegacyRead<TableFolderMirrorValue>? {
        guard let store else { return nil }
        return await MainActor.run { () -> CoreMirrorLegacyRead<TableFolderMirrorValue> in
            let values = Self.values(store.allFolders(), store.allItems())
            // A document that does not read stands for folders this build cannot see, which the core keeps.
            return CoreMirrorLegacyRead(values: values, allowsRemovals: !store.hasUnreadableDocumentsAfterReadingAll)
        }
    }

    func key(of value: TableFolderMirrorValue) -> TableFolderMirrorKey {
        Self.key(of: value)
    }

    private static func key(of value: TableFolderMirrorValue) -> TableFolderMirrorKey {
        switch value {
        case .folder(let folder): .folder(folder.id)
        case .item(let item): .item(item.key)
        }
    }

    private static func values(_ folders: [TableFolder], _ items: [TableFolderItem]) -> [TableFolderMirrorValue] {
        let folders = folders.map { folder in
            TableFolderMirrorValue.folder(.init(
                id: folder.id,
                scope: folder.scope,
                name: folder.name,
                createdAtMs: CoreMirrorTime.milliseconds(folder.createdAt),
                updatedAtMs: CoreMirrorTime.milliseconds(folder.updatedAt)
            ))
        }
        return folders + items.map(TableFolderMirrorValue.item)
    }

    func readCore() async throws -> CoreMirrorCoreRead<TableFolderMirrorValue> {
        let contents = try await database.tableFolders().contents()
        let folders = contents.folders.compactMap { record -> TableFolderMirrorValue? in
            guard let id = UUID(uuidString: record.id), let connectionId = UUID(uuidString: record.connectionId) else {
                return nil
            }
            return .folder(.init(
                id: id,
                scope: Self.scope(connectionId, record.database, record.schema),
                name: record.name,
                createdAtMs: record.createdAtMs,
                updatedAtMs: record.updatedAtMs
            ))
        }
        let items = contents.items.compactMap { record -> TableFolderMirrorValue? in
            guard let connectionId = UUID(uuidString: record.connectionId),
                  let folderId = UUID(uuidString: record.folderId) else { return nil }
            return .item(TableFolderItem(
                scope: Self.scope(connectionId, record.table.database, record.table.schema),
                name: record.table.name,
                folderId: folderId
            ))
        }
        return CoreMirrorCoreRead(values: folders + items, digest: contents.digest)
    }

    func writeCore(puts: [TableFolderMirrorValue], removals: [TableFolderMirrorKey]) async throws {
        let (folders, items) = Self.records(puts)
        var removedFolders: [String] = []
        var removedItems: [TableKeyRecord] = []
        for key in removals {
            switch key {
            case .folder(let id):
                removedFolders.append(id.uuidString)
            case .item(let item):
                removedItems.append(TableKeyRecord(
                    connectionId: item.scope.connectionId.uuidString,
                    table: Self.table(item.scope, item.name)
                ))
            }
        }
        _ = try await database.tableFolders().writeRecords(write: TableFolderRecordWrite(
            folders: folders,
            items: items,
            removedFolders: removedFolders,
            removedItems: removedItems
        ))
    }

    func replaceCore(expected: String, values: [TableFolderMirrorValue]) async throws {
        let (folders, items) = Self.records(values)
        let store = try await database.tableFolders()
        try await refusingOutdated {
            _ = try await store.replaceRecords(expectedDigest: expected, foldersHeld: folders, itemsHeld: items)
        }
    }

    func applyToLegacy(
        puts: [TableFolderMirrorValue],
        removals: [TableFolderMirrorKey],
        expected: [TableFolderMirrorKey: TableFolderMirrorValue]
    ) async -> Bool {
        var folders: [TableFolder] = []
        var items: [TableFolderItem] = []
        for value in puts {
            switch value {
            case .folder(let folder):
                folders.append(TableFolder(
                    id: folder.id,
                    scope: folder.scope,
                    name: folder.name,
                    createdAt: CoreMirrorTime.date(folder.createdAtMs),
                    updatedAt: CoreMirrorTime.date(folder.updatedAtMs)
                ))
            case .item(let item):
                items.append(item)
            }
        }
        var removedFolders: Set<UUID> = []
        var removedItems: Set<TableFolderItemKey> = []
        for key in removals {
            switch key {
            case .folder(let id): removedFolders.insert(id)
            case .item(let item): removedItems.insert(item)
            }
        }
        let touched = puts.map(key(of:)) + removals
        guard let store else { return false }
        return await MainActor.run { [folders, items, removedFolders, removedItems] in
            // The store refuses to write a document that does not read, so nothing would land.
            guard !store.hasUnreadableDocumentsAfterReadingAll else { return false }
            let held = Dictionary(
                Self.values(store.allFolders(), store.allItems()).map { (Self.key(of: $0), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            guard touched.allSatisfy({ held[$0] == expected[$0] }) else { return false }
            store.applyCoreRecords(
                folders: folders,
                items: items,
                removedFolderIds: removedFolders,
                removedItemKeys: removedItems
            )
            return true
        }
    }

    func announce(settled: [TableFolderMirrorValue]) async {}

    // The core names a database or schema an engine lacks by the empty string; the Mac by none.
    private static func scope(_ connectionId: UUID, _ database: String, _ schema: String) -> DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema.isEmpty ? nil : schema)
    }

    private static func table(_ scope: DatabaseScope, _ name: String) -> TableRefRecord {
        TableRefRecord(database: scope.database, schema: scope.schema ?? "", name: name)
    }

    private static func records(_ values: [TableFolderMirrorValue]) -> ([TableFolderRecord], [TablePlacementRecord]) {
        var folders: [TableFolderRecord] = []
        var items: [TablePlacementRecord] = []
        for value in values {
            switch value {
            case .folder(let folder):
                folders.append(TableFolderRecord(
                    id: folder.id.uuidString,
                    connectionId: folder.scope.connectionId.uuidString,
                    database: folder.scope.database,
                    schema: folder.scope.schema ?? "",
                    name: folder.name,
                    createdAtMs: folder.createdAtMs,
                    updatedAtMs: folder.updatedAtMs
                ))
            case .item(let item):
                items.append(TablePlacementRecord(
                    connectionId: item.scope.connectionId.uuidString,
                    table: table(item.scope, item.name),
                    folderId: item.folderId.uuidString
                ))
            }
        }
        return (folders, items)
    }
}
