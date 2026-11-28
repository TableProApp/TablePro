//
//  SavedQueryCoreAdapter.swift
//  TablePro
//

import Foundation
import TableProFFI

internal enum SavedQueryMirrorKey: Hashable, Sendable, Encodable {
    case query(UUID)
    case folder(UUID)
}

// Times in whole milliseconds, the precision the core and a CloudKit date keep.
internal enum SavedQueryMirrorValue: Equatable, Sendable, Encodable {
    case query(Query)
    case folder(Folder)

    internal struct Query: Equatable, Sendable, Encodable {
        let id: UUID
        let name: String
        let sql: String
        let keyword: String?
        let folderId: UUID?
        let connectionId: UUID?
        let order: Int64
        let createdAtMs: Int64
        let updatedAtMs: Int64
    }

    internal struct Folder: Equatable, Sendable, Encodable {
        let id: UUID
        let name: String
        let parentId: UUID?
        let connectionId: UUID?
        let order: Int64
        let createdAtMs: Int64
        let updatedAtMs: Int64
    }
}

// `sql_favorites.db` and the core's saved queries and folders (core ADR 0010, slice 3).
internal struct SavedQueryCoreAdapter: CoreMirrorAdapter {
    let storage: SQLFavoriteStorage
    let database: CoreHistoryDatabase
    let announceSettled: @Sendable (_ queries: [UUID], _ folders: [UUID]) async -> Void
    // The store took the core's records, a pull's among them, so what shows them reads again.
    let applied: @Sendable () async -> Void

    var name: String { "savedQueries" }

    func key(of value: SavedQueryMirrorValue) -> SavedQueryMirrorKey {
        switch value {
        case .query(let query): .query(query.id)
        case .folder(let folder): .folder(folder.id)
        }
    }

    func readLegacy() async -> CoreMirrorLegacyRead<SavedQueryMirrorValue>? {
        guard let read = await storage.readAllFavoritesAndFolders() else { return nil }
        let refilling = await storage.isAwaitingSyncRefill()
        let values = read.favorites.map { SavedQueryMirrorValue.query(.init($0)) }
            + read.folders.map { SavedQueryMirrorValue.folder(.init($0)) }
        return CoreMirrorLegacyRead(values: values, allowsRemovals: !refilling)
    }

    func readCore() async throws -> CoreMirrorCoreRead<SavedQueryMirrorValue> {
        let contents = try await database.savedQueries().contents()
        let values = contents.queries.compactMap(SavedQueryMirrorValue.Query.init).map(SavedQueryMirrorValue.query)
            + contents.folders.compactMap(SavedQueryMirrorValue.Folder.init).map(SavedQueryMirrorValue.folder)
        return CoreMirrorCoreRead(values: values, digest: contents.digest)
    }

    func writeCore(puts: [SavedQueryMirrorValue], removals: [SavedQueryMirrorKey]) async throws {
        let (queries, folders) = Self.records(puts)
        _ = try await database.savedQueries().writeRecords(write: SavedQueryRecordWrite(
            queries: queries,
            folders: folders,
            removedQueries: removals.compactMap { key in
                guard case .query(let id) = key else { return nil }
                return id.uuidString
            },
            removedFolders: removals.compactMap { key in
                guard case .folder(let id) = key else { return nil }
                return id.uuidString
            }
        ))
    }

    func replaceCore(expected: String, values: [SavedQueryMirrorValue]) async throws {
        let (queries, folders) = Self.records(values)
        let store = try await database.savedQueries()
        try await refusingOutdated {
            _ = try await store.replaceRecords(expectedDigest: expected, queries: queries, folders: folders)
        }
    }

    func applyToLegacy(
        puts: [SavedQueryMirrorValue],
        removals: [SavedQueryMirrorKey],
        expected: [SavedQueryMirrorKey: SavedQueryMirrorValue]
    ) async -> Bool {
        var favorites: [SQLFavorite] = []
        var folders: [SQLFavoriteFolder] = []
        for value in puts {
            switch value {
            case .query(let query): favorites.append(query.favorite)
            case .folder(let folder): folders.append(folder.folder)
            }
        }
        var removedFavorites: [UUID] = []
        var removedFolders: [UUID] = []
        for key in removals {
            switch key {
            case .query(let id): removedFavorites.append(id)
            case .folder(let id): removedFolders.append(id)
            }
        }
        let wrote = await storage.applyCoreRecords(
            favorites: favorites,
            folders: folders,
            removedFavoriteIds: removedFavorites,
            removedFolderIds: removedFolders,
            expected: expected
        )
        if wrote {
            await applied()
        }
        return wrote
    }

    func announce(settled: [SavedQueryMirrorValue]) async {
        var queries: [UUID] = []
        var folders: [UUID] = []
        for value in settled {
            switch value {
            case .query(let query): queries.append(query.id)
            case .folder(let folder): folders.append(folder.id)
            }
        }
        await announceSettled(queries, folders)
    }

    // The connection's name is a display copy only the core keeps; no Mac store holds it.
    private static func records(_ values: [SavedQueryMirrorValue]) -> ([SavedQueryRecord], [SavedQueryFolderRecord]) {
        var queries: [SavedQueryRecord] = []
        var folders: [SavedQueryFolderRecord] = []
        for value in values {
            switch value {
            case .query(let query):
                queries.append(SavedQueryRecord(
                    id: query.id.uuidString,
                    name: query.name,
                    sql: query.sql,
                    keyword: query.keyword,
                    connectionId: query.connectionId?.uuidString,
                    connectionName: "",
                    folderId: query.folderId?.uuidString,
                    order: query.order,
                    createdAtMs: query.createdAtMs,
                    updatedAtMs: query.updatedAtMs
                ))
            case .folder(let folder):
                folders.append(SavedQueryFolderRecord(
                    id: folder.id.uuidString,
                    name: folder.name,
                    connectionId: folder.connectionId?.uuidString,
                    parentId: folder.parentId?.uuidString,
                    order: folder.order,
                    createdAtMs: folder.createdAtMs,
                    updatedAtMs: folder.updatedAtMs
                ))
            }
        }
        return (queries, folders)
    }
}

// To the nearest millisecond, so a time read back from a store that keeps seconds as a double maps to the same value.
internal enum CoreMirrorTime {
    static func milliseconds(_ date: Date) -> Int64 {
        milliseconds(seconds: date.timeIntervalSince1970)
    }

    // A value the Swift store holds outside what an Int64 of milliseconds takes is pinned to its end, never a trap.
    static func milliseconds(seconds: Double) -> Int64 {
        let value = (seconds * 1_000).rounded()
        guard value.isFinite else { return 0 }
        guard value < Double(Int64.max) else { return .max }
        guard value > Double(Int64.min) else { return .min }
        return Int64(value)
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

extension SavedQueryMirrorValue.Query {
    init(_ favorite: SQLFavorite) {
        self.init(
            id: favorite.id,
            name: favorite.name,
            sql: favorite.query,
            keyword: favorite.keyword,
            folderId: favorite.folderId,
            connectionId: favorite.connectionId,
            order: Int64(favorite.sortOrder),
            createdAtMs: CoreMirrorTime.milliseconds(favorite.createdAt),
            updatedAtMs: CoreMirrorTime.milliseconds(favorite.updatedAt)
        )
    }

    init?(_ record: SavedQueryRecord) {
        guard let id = UUID(uuidString: record.id) else { return nil }
        self.init(
            id: id,
            name: record.name,
            sql: record.sql,
            keyword: record.keyword,
            folderId: record.folderId.flatMap(UUID.init(uuidString:)),
            connectionId: record.connectionId.flatMap(UUID.init(uuidString:)),
            order: record.order,
            createdAtMs: record.createdAtMs,
            updatedAtMs: record.updatedAtMs
        )
    }

    var favorite: SQLFavorite {
        SQLFavorite(
            id: id,
            name: name,
            query: sql,
            keyword: keyword,
            folderId: folderId,
            connectionId: connectionId,
            sortOrder: Int(clamping: order),
            createdAt: CoreMirrorTime.date(createdAtMs),
            updatedAt: CoreMirrorTime.date(updatedAtMs)
        )
    }
}

extension SavedQueryMirrorValue.Folder {
    init(_ folder: SQLFavoriteFolder) {
        self.init(
            id: folder.id,
            name: folder.name,
            parentId: folder.parentId,
            connectionId: folder.connectionId,
            order: Int64(folder.sortOrder),
            createdAtMs: CoreMirrorTime.milliseconds(folder.createdAt),
            updatedAtMs: CoreMirrorTime.milliseconds(folder.updatedAt)
        )
    }

    init?(_ record: SavedQueryFolderRecord) {
        guard let id = UUID(uuidString: record.id) else { return nil }
        self.init(
            id: id,
            name: record.name,
            parentId: record.parentId.flatMap(UUID.init(uuidString:)),
            connectionId: record.connectionId.flatMap(UUID.init(uuidString:)),
            order: record.order,
            createdAtMs: record.createdAtMs,
            updatedAtMs: record.updatedAtMs
        )
    }

    var folder: SQLFavoriteFolder {
        SQLFavoriteFolder(
            id: id,
            name: name,
            parentId: parentId,
            connectionId: connectionId,
            sortOrder: Int(clamping: order),
            createdAt: CoreMirrorTime.date(createdAtMs),
            updatedAt: CoreMirrorTime.date(updatedAtMs)
        )
    }
}
