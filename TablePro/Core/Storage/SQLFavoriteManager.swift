//
//  SQLFavoriteManager.swift
//  TablePro
//

import Combine
import Foundation
import os

/// Manages SQL favorites with notifications
internal final class SQLFavoriteManager: @unchecked Sendable {
    static let shared = SQLFavoriteManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFavoriteManager")

    private let storage: SQLFavoriteStorage
    private let syncTracker: SyncChangeTracker

    init(storage: SQLFavoriteStorage = SQLFavoriteStorage(), syncTracker: SyncChangeTracker = .shared) {
        self.storage = storage
        self.syncTracker = syncTracker
    }

    // MARK: - Favorites

    func addFavorite(_ favorite: SQLFavorite) async -> Bool {
        let result = await storage.addFavorite(favorite)
        if result {
            syncTracker.markDirty(.favorite, id: favorite.id.uuidString)
            postUpdateNotification(connectionId: favorite.connectionId)
        }
        return result
    }

    func updateFavorite(_ favorite: SQLFavorite) async -> Bool {
        let result = await storage.updateFavorite(favorite)
        if result {
            syncTracker.markDirty(.favorite, id: favorite.id.uuidString)
            postUpdateNotification(connectionId: favorite.connectionId)
        }
        return result
    }

    func deleteFavorite(id: UUID) async -> Bool {
        let result = await storage.deleteFavorite(id: id)
        if result {
            syncTracker.markDeleted(.favorite, id: id.uuidString)
            postUpdateNotification(connectionId: nil)
        }
        return result
    }

    func deleteFavorites(ids: [UUID]) async {
        let result = await storage.deleteFavorites(ids: ids)
        if result {
            for id in ids {
                syncTracker.markDeleted(.favorite, id: id.uuidString)
            }
            postUpdateNotification(connectionId: nil)
        }
    }

    func removeFavoritesAndFolders(for connectionId: UUID) async {
        let removed = await storage.deleteFavoritesAndFolders(connectionId: connectionId)
        if removed {
            postUpdateNotification(connectionId: nil)
        }
    }

    func pruneOrphaned(activeConnectionIds: Set<UUID>) async {
        await storage.pruneOrphaned(retaining: activeConnectionIds)
    }

    func hasFavorites(for connectionIds: [UUID]) async -> Bool {
        await storage.hasFavorites(connectionIds: connectionIds)
    }

    func fetchFavorite(id: UUID) async -> SQLFavorite? {
        await storage.fetchFavorite(id: id)
    }

    func fetchFavorites(
        connectionId: UUID? = nil,
        folderId: UUID? = nil,
        searchText: String? = nil
    ) async -> [SQLFavorite] {
        await storage.fetchFavorites(connectionId: connectionId, folderId: folderId, searchText: searchText)
    }

    // MARK: - Folders

    func addFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        let result = await storage.addFolder(folder)
        if result {
            syncTracker.markDirty(.favoriteFolder, id: folder.id.uuidString)
            postUpdateNotification(connectionId: folder.connectionId)
        }
        return result
    }

    func updateFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        let result = await storage.updateFolder(folder)
        if result {
            syncTracker.markDirty(.favoriteFolder, id: folder.id.uuidString)
            postUpdateNotification(connectionId: folder.connectionId)
        }
        return result
    }

    func deleteFolder(id: UUID) async -> Bool {
        let result = await storage.deleteFolder(id: id)
        if result {
            syncTracker.markDeleted(.favoriteFolder, id: id.uuidString)
            postUpdateNotification(connectionId: nil)
        }
        return result
    }

    func fetchFolders(connectionId: UUID? = nil) async -> [SQLFavoriteFolder] {
        await storage.fetchFolders(connectionId: connectionId)
    }

    // MARK: - Remote Apply (does not mark dirty, to avoid sync loops)

    func applyRemoteFavorite(_ favorite: SQLFavorite) async {
        if await storage.upsertFavorite(favorite) {
            postUpdateNotification(connectionId: favorite.connectionId)
        }
    }

    func applyRemoteFolder(_ folder: SQLFavoriteFolder) async {
        if await storage.upsertFolder(folder) {
            postUpdateNotification(connectionId: folder.connectionId)
        }
    }

    func applyRemoteDeleteFavorite(id: UUID) async {
        if await storage.deleteFavorite(id: id) {
            postUpdateNotification(connectionId: nil)
        }
    }

    func applyRemoteDeleteFolder(id: UUID) async {
        if await storage.deleteFolder(id: id) {
            postUpdateNotification(connectionId: nil)
        }
    }

    // MARK: - Keyword Support

    func fetchKeywordMap(connectionId: UUID? = nil) async -> [String: (name: String, query: String)] {
        var map = await storage.fetchKeywordMap(connectionId: connectionId)
        let linked = await fetchLinkedKeywordMap(connectionId: connectionId)
        for (keyword, value) in linked where map[keyword] == nil {
            map[keyword] = value
        }
        return map
    }

    private func fetchLinkedKeywordMap(connectionId: UUID?) async -> [String: (name: String, query: String)] {
        let folders = LinkedSQLFolderStorage.shared.loadFolders()
            .filter { $0.isEnabled }
            .filter { $0.connectionId == nil || $0.connectionId == connectionId }
        guard !folders.isEmpty else { return [:] }

        let folderIds = Set(folders.map(\.id))
        let folderURLsById = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.expandedURL) })

        let rows = await LinkedSQLIndex.shared.fetchKeywordRows(folderIds: folderIds)
        guard !rows.isEmpty else { return [:] }

        return await Task.detached(priority: .utility) {
            await withTaskGroup(of: (String, (name: String, query: String))?.self) { group in
                for row in rows {
                    guard let folderURL = folderURLsById[row.folderId] else { continue }
                    let fileURL = folderURL.appendingPathComponent(row.relativePath)
                    let keyword = row.keyword
                    let name = row.name
                    group.addTask {
                        guard let loaded = FileTextLoader.load(fileURL) else { return nil }
                        return (keyword, (name: name, query: loaded.content))
                    }
                }

                var map: [String: (name: String, query: String)] = [:]
                for await result in group {
                    if let (keyword, value) = result, map[keyword] == nil {
                        map[keyword] = value
                    }
                }
                return map
            }
        }.value
    }

    func isKeywordAvailable(
        _ keyword: String,
        connectionId: UUID?,
        excludingFavoriteId: UUID? = nil
    ) async -> Bool {
        await storage.isKeywordAvailable(keyword, connectionId: connectionId, excludingFavoriteId: excludingFavoriteId)
    }

    // MARK: - Notifications

    private func postUpdateNotification(connectionId: UUID?) {
        Task { @MainActor in
            AppEvents.shared.sqlFavoritesDidUpdate.send(connectionId)
        }
    }
}
