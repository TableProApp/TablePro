//
//  SQLFavoriteManager.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProSyncTransport

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
        guard result.succeeded else { return false }
        syncTracker.markDirty(.favorite, id: favorite.id.uuidString)
        postUpdateNotification(for: result, newConnectionId: favorite.connectionId)
        return true
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

    /// Tombstones every record it removed, the same as the other delete paths. Deleting a
    /// connection is the one delete that was keyed on something other than the records themselves,
    /// and it was the one that never marked them deleted, so a deleted connection's SQL favorites
    /// and folders outlived it in CloudKit and came back on the next device to sync.
    ///
    /// `markDeleted` runs after the storage delete has committed, per the sync ordering rule: it
    /// posts a change notification that can start a sync, and a sync that reads a file still
    /// holding the record re-uploads what was just deleted.
    func removeFavoritesAndFolders(for connectionId: UUID) async {
        let removed = await storage.deleteFavoritesAndFolders(connectionId: connectionId)
        guard !removed.isEmpty else { return }
        for id in removed.favorites {
            syncTracker.markDeleted(.favorite, id: id.uuidString)
        }
        for id in removed.folders {
            syncTracker.markDeleted(.favoriteFolder, id: id.uuidString)
        }
        markDetachedDirty(removed.detached)
        postUpdateNotification(connectionId: nil)
    }

    /// A row that survived the delete holding a reference the delete had to clear is a local edit
    /// like any other, so it is pushed rather than tombstoned. Without this the survivor kept the
    /// deleted folder's id everywhere else and on a fresh install, while this Mac drew it correctly.
    ///
    /// Only on the path that owns the deletion. When another device deleted the connection it runs
    /// the same cleanup over the same rows and pushes the result itself, and the caller that exists
    /// for that case deliberately does not mark anything.
    private func markDetachedDirty(_ detached: DetachedFavoriteRecords) {
        guard !detached.isEmpty else { return }
        syncTracker.markDirty(.favorite, ids: detached.favorites.map(\.uuidString))
        syncTracker.markDirty(.favoriteFolder, ids: detached.folders.map(\.uuidString))
    }

    /// Used when another device deleted the connection. Marking tombstones here would push its own
    /// deletion straight back at it, which is the reason `FavoriteTablesStorage` splits the same
    /// way.
    func removeFavoritesAndFoldersWithoutSync(for connectionId: UUID) async {
        let removed = await storage.deleteFavoritesAndFolders(connectionId: connectionId)
        guard !removed.isEmpty else { return }
        syncTracker.discardDirty(.favorite, ids: removed.favorites.map(\.uuidString))
        syncTracker.discardDirty(.favoriteFolder, ids: removed.folders.map(\.uuidString))
        postUpdateNotification(connectionId: nil)
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
        searchText: String? = nil,
        allowedConnectionIds: Set<UUID>? = nil
    ) async -> [SQLFavorite] {
        await storage.fetchFavorites(
            connectionId: connectionId,
            folderId: folderId,
            searchText: searchText,
            allowedConnectionIds: allowedConnectionIds
        )
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
        guard result.succeeded else { return false }
        syncTracker.markDirty(.favoriteFolder, id: folder.id.uuidString)
        postUpdateNotification(for: result, newConnectionId: folder.connectionId)
        return true
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

    func fetchFolder(id: UUID) async -> SQLFavoriteFolder? {
        await storage.fetchFolder(id: id)
    }

    func renameFolder(id: UUID, name: String) async -> Bool {
        let result = await storage.renameFolder(id: id, name: name)
        guard result.succeeded else { return false }
        syncTracker.markDirty(.favoriteFolder, id: id.uuidString)
        postUpdateNotification(connectionId: result.retainedScope)
        return true
    }

    /// The mark runs after the write has committed, per the sync ordering rule: `markDirty` posts a
    /// change notification that can start a sync, and a sync reading the database before the write
    /// lands pushes the scope the folder is leaving.
    func setFolderScope(id: UUID, connectionId: UUID?) async -> Bool {
        let result = await storage.setFolderScope(id: id, connectionId: connectionId)
        guard result.succeeded else { return false }
        syncTracker.markDirty(.favoriteFolder, id: id.uuidString)
        postUpdateNotification(for: result, newConnectionId: connectionId)
        return true
    }

    func setFavoriteFolder(id: UUID, folderId: UUID?) async -> Bool {
        let result = await storage.setFavoriteFolder(id: id, folderId: folderId)
        guard result.succeeded else { return false }
        syncTracker.markDirty(.favorite, id: id.uuidString)
        postUpdateNotification(connectionId: result.retainedScope)
        return true
    }

    // MARK: - Remote Apply (does not mark dirty, to avoid sync loops)

    func applyRemoteFavorite(_ favorite: SQLFavorite) async {
        let result = await storage.upsertFavorite(favorite)
        guard result.succeeded else { return }
        postUpdateNotification(for: result, newConnectionId: favorite.connectionId)
    }

    func applyRemoteFolder(_ folder: SQLFavoriteFolder) async {
        let result = await storage.upsertFolder(folder)
        guard result.succeeded else { return }
        postUpdateNotification(for: result, newConnectionId: folder.connectionId)
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

    private func postUpdateNotification(for write: FavoriteScopeWrite, newConnectionId: UUID?) {
        postUpdateNotification(connectionId: Self.scopeToAnnounce(for: write, newConnectionId: newConnectionId))
    }

    /// Which connection a write has to be announced to, where nil means all of them.
    ///
    /// A record scoped to one connection is in that connection's list alone, so naming it is
    /// enough. A record that moved between scopes has left a list it used to be in, and the
    /// subscriber holding that list filters for a connection this event does not name, so it never
    /// hears about it and goes on showing the record. Every global record is in every connection's
    /// list, which is what makes a move to or from global everybody's business.
    internal static func scopeToAnnounce(for write: FavoriteScopeWrite, newConnectionId: UUID?) -> UUID? {
        guard case .updatedExisting(let previousConnectionId) = write else { return newConnectionId }
        return previousConnectionId == newConnectionId ? newConnectionId : nil
    }
}
