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
    private let operations = MainActorSerialQueue()

    init(storage: SQLFavoriteStorage = SQLFavoriteStorage(), syncTracker: SyncChangeTracker = .shared) {
        self.storage = storage
        self.syncTracker = syncTracker
    }

    // MARK: - Favorites

    func addFavorite(_ favorite: SQLFavorite) async -> Bool {
        await operations.run { [self] in
            guard await storage.addFavorite(favorite) else { return false }
            syncTracker.markDirty(.favorite, id: favorite.id.uuidString)
            postUpdateNotification(connectionId: favorite.connectionId)
            return true
        }
    }

    func updateFavorite(_ favorite: SQLFavorite) async -> Bool {
        await operations.run { [self] in
            let result = await storage.updateFavorite(favorite)
            guard result.succeeded else { return false }
            syncTracker.markDirty(.favorite, id: favorite.id.uuidString)
            postUpdateNotification(for: result, newConnectionId: favorite.connectionId)
            return true
        }
    }

    func deleteFavorite(id: UUID) async -> Bool {
        await operations.run { [self] in
            guard await storage.deleteFavorite(id: id) else { return false }
            syncTracker.markDeleted(.favorite, id: id.uuidString)
            postUpdateNotification(connectionId: nil)
            return true
        }
    }

    func deleteFavorites(ids: [UUID]) async {
        await operations.run { [self] in
            guard await storage.deleteFavorites(ids: ids) else { return }
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
        await operations.run { [self] in
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
    }

    /// A row that survived the delete holding a reference the delete had to clear is a local edit
    /// like any other, so it is pushed rather than tombstoned. Without this the survivor kept the
    /// deleted folder's id everywhere else and on a fresh install, while this Mac drew it correctly.
    ///
    /// Only on the path that owns the deletion. When another device deleted the connection it runs
    /// the same cleanup over the same rows and pushes the result itself, and the caller that exists
    /// for that case deliberately does not mark anything.
    @MainActor
    private func markDetachedDirty(_ detached: DetachedFavoriteRecords) {
        guard !detached.isEmpty else { return }
        syncTracker.markDirty(.favorite, ids: detached.favorites.map(\.uuidString))
        syncTracker.markDirty(.favoriteFolder, ids: detached.folders.map(\.uuidString))
    }

    /// Used when another device deleted the connection. Marking tombstones here would push its own
    /// deletion straight back at it, which is the reason `FavoriteTablesStorage` splits the same
    /// way.
    func removeFavoritesAndFoldersWithoutSync(for connectionId: UUID) async {
        await operations.run { [self] in
            let removed = await storage.deleteFavoritesAndFolders(connectionId: connectionId)
            guard !removed.isEmpty else { return }
            syncTracker.discardDirty(.favorite, ids: removed.favorites.map(\.uuidString))
            syncTracker.discardDirty(.favoriteFolder, ids: removed.folders.map(\.uuidString))
            postUpdateNotification(connectionId: nil)
        }
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

    func favoritesForSync() async -> [SQLFavorite]? {
        await storage.readAllFavorites()
    }

    func foldersForSync() async -> [SQLFavoriteFolder]? {
        await storage.readAllFolders()
    }

    // MARK: - Versions

    func fetchVersions(favoriteId: UUID) async -> [SQLFavoriteVersion] {
        await storage.fetchVersions(favoriteId: favoriteId)
    }

    func querySavedAt(favoriteId: UUID) async -> Date? {
        await storage.querySavedAt(favoriteId: favoriteId)
    }

    func restore(_ version: SQLFavoriteVersion) async -> Bool {
        await operations.run { [self] in
            let result = await storage.replaceQuery(
                favoriteId: version.favoriteId,
                query: version.query,
                updatedAt: Date()
            )
            guard result.succeeded else { return false }
            syncTracker.markDirty(.favorite, id: version.favoriteId.uuidString)
            postUpdateNotification(connectionId: result.retainedScope)
            return true
        }
    }

    // MARK: - Folders

    func addFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        await operations.run { [self] in
            guard await storage.addFolder(folder) else { return false }
            syncTracker.markDirty(.favoriteFolder, id: folder.id.uuidString)
            postUpdateNotification(connectionId: folder.connectionId)
            return true
        }
    }

    func updateFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        await operations.run { [self] in
            let result = await storage.updateFolder(folder)
            guard result.succeeded else { return false }
            syncTracker.markDirty(.favoriteFolder, id: folder.id.uuidString)
            postUpdateNotification(for: result, newConnectionId: folder.connectionId)
            return true
        }
    }

    /// The records the delete moved up a level are marked dirty alongside the folder's tombstone.
    ///
    /// Deleting a folder reparents what was inside it, and only the folder itself used to be told
    /// to sync. The moved records kept the id of the deleted folder on the wire, so a device
    /// fetching the account fresh stored a `folderId` matching no folder.
    func deleteFolder(id: UUID) async -> Bool {
        await operations.run { [self] in
            guard let deletion = await storage.deleteFolder(id: id) else { return false }
            syncTracker.markDeleted(.favoriteFolder, id: id.uuidString)
            syncTracker.markDirty(.favorite, ids: deletion.movedFavorites.map(\.uuidString))
            syncTracker.markDirty(.favoriteFolder, ids: deletion.movedFolders.map(\.uuidString))
            postUpdateNotification(connectionId: nil)
            return true
        }
    }

    func fetchFolders(connectionId: UUID? = nil) async -> [SQLFavoriteFolder] {
        await storage.fetchFolders(connectionId: connectionId)
    }

    func fetchFolder(id: UUID) async -> SQLFavoriteFolder? {
        await storage.fetchFolder(id: id)
    }

    func renameFolder(id: UUID, name: String) async -> Bool {
        await operations.run { [self] in
            let result = await storage.renameFolder(id: id, name: name)
            guard result.succeeded else { return false }
            syncTracker.markDirty(.favoriteFolder, id: id.uuidString)
            postUpdateNotification(connectionId: result.retainedScope)
            return true
        }
    }

    /// The mark runs after the write has committed, per the sync ordering rule: `markDirty` posts a
    /// change notification that can start a sync, and a sync reading the database before the write
    /// lands pushes the scope the folder is leaving.
    func setFolderScope(id: UUID, connectionId: UUID?) async -> Bool {
        await operations.run { [self] in
            let result = await storage.setFolderScope(id: id, connectionId: connectionId)
            guard result.succeeded else { return false }
            syncTracker.markDirty(.favoriteFolder, id: id.uuidString)
            postUpdateNotification(for: result, newConnectionId: connectionId)
            return true
        }
    }

    func setFavoriteFolder(id: UUID, folderId: UUID?) async -> Bool {
        await operations.run { [self] in
            let result = await storage.setFavoriteFolder(id: id, folderId: folderId)
            guard result.succeeded else { return false }
            syncTracker.markDirty(.favorite, id: id.uuidString)
            postUpdateNotification(connectionId: result.retainedScope)
            return true
        }
    }

    // MARK: - Remote Apply

    func applyRemote(
        _ batch: RemoteSQLFavoriteBatch,
        echoGuard: SyncEchoGuard? = nil
    ) async -> RemoteApplyOutcome {
        guard !batch.isEmpty else { return .skipped }
        return await operations.run { [self] in
            let admitted = admitting(batch, echoGuard: echoGuard)
            guard !admitted.isEmpty else { return .skipped }
            guard await applyRemoteFavoriteDeletions(admitted.deletedFavoriteIds),
                  await applyRemoteFolders(admitted.folders),
                  await applyRemoteFavorites(admitted.favoritesToUpsert),
                  await applyRemoteFolderDeletions(admitted.deletedFolderIds)
            else {
                return .failed
            }
            return .applied
        }
    }

    @MainActor
    private func admitting(_ batch: RemoteSQLFavoriteBatch, echoGuard: SyncEchoGuard?) -> RemoteSQLFavoriteBatch {
        let deletedFavoriteIds = syncTracker.tombstonedIds(for: .favorite)
        let deletedFolderIds = syncTracker.tombstonedIds(for: .favoriteFolder)
        var admitted = batch
        admitted.favorites = batch.favorites.filter { favorite in
            let id = favorite.id.uuidString
            guard !deletedFavoriteIds.contains(id) else { return false }
            return echoGuard?.withholds(.favorite, id: id, tracker: syncTracker) != true
        }
        admitted.folders = batch.folders.filter { folder in
            let id = folder.id.uuidString
            guard !deletedFolderIds.contains(id) else { return false }
            return echoGuard?.withholds(.favoriteFolder, id: id, tracker: syncTracker) != true
        }
        return admitted
    }

    @MainActor
    private func applyRemoteFavoriteDeletions(_ ids: Set<UUID>) async -> Bool {
        guard !ids.isEmpty else { return true }
        guard await storage.deleteFavorites(ids: Array(ids)) else { return false }
        syncTracker.discardDirty(.favorite, ids: ids.map(\.uuidString))
        postUpdateNotification(connectionId: nil)
        return true
    }

    @MainActor
    private func applyRemoteFolders(_ folders: [SQLFavoriteFolder]) async -> Bool {
        for folder in folders {
            let write = await storage.upsertFolder(folder)
            guard write.succeeded else { return false }
            postUpdateNotification(for: write, newConnectionId: folder.connectionId)
        }
        return true
    }

    @MainActor
    private func applyRemoteFavorites(_ favorites: [SQLFavorite]) async -> Bool {
        guard !favorites.isEmpty else { return true }
        guard let result = await storage.applyRemoteFavorites(favorites) else { return false }
        for write in result.writes {
            postUpdateNotification(for: write.write, newConnectionId: write.connectionId)
        }
        if !result.releasedKeywordIds.isEmpty {
            Self.logger.info("Keyword conflicts resolved: \(result.releasedKeywordIds.count)")
            syncTracker.markDirty(.favorite, ids: result.releasedKeywordIds.map(\.uuidString))
        }
        return true
    }

    @MainActor
    private func applyRemoteFolderDeletions(_ ids: Set<UUID>) async -> Bool {
        guard !ids.isEmpty else { return true }
        defer { postUpdateNotification(connectionId: nil) }
        for id in ids {
            guard await storage.deleteFolder(id: id) != nil else { return false }
            syncTracker.discardDirty(.favoriteFolder, ids: [id.uuidString])
        }
        return true
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

    /// Which file wins a keyword two of them declare is decided by where the files are, not by
    /// which disk read came back first.
    ///
    /// The reads still run together; only the fold is ordered. A task group is consumed in
    /// completion order, so folding straight out of it handed the keyword to whichever file the
    /// disk answered for first: measured by replaying the fold at fixed row order, the second file
    /// won 45 times in 300, and 90 in 300 with forty more keyword files in the group. The same
    /// keyword expanded to different SQL between launches with nothing on screen to say why.
    private func fetchLinkedKeywordMap(connectionId: UUID?) async -> [String: (name: String, query: String)] {
        let folders = LinkedSQLFolderStorage.shared.loadFolders()
            .filter { $0.isEnabled }
            .filter { $0.connectionId == nil || $0.connectionId == connectionId }
        guard !folders.isEmpty else { return [:] }

        let folderIds = Set(folders.map(\.id))
        let folderURLsById = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.expandedURL) })
        let folderRankById = Dictionary(uniqueKeysWithValues: folders.enumerated().map { ($0.element.id, $0.offset) })

        let rows = await LinkedSQLIndex.shared.fetchKeywordRows(folderIds: folderIds)
        guard !rows.isEmpty else { return [:] }

        let candidates = await Task.detached(priority: .utility) {
            await withTaskGroup(of: LinkedKeywordCandidate?.self) { group in
                for row in rows {
                    guard let folderURL = folderURLsById[row.folderId],
                          let folderRank = folderRankById[row.folderId] else { continue }
                    let fileURL = folderURL.appendingPathComponent(row.relativePath)
                    let keyword = row.keyword
                    let name = row.name
                    let relativePath = row.relativePath
                    group.addTask {
                        guard let loaded = FileTextLoader.load(fileURL) else { return nil }
                        return LinkedKeywordCandidate(
                            keyword: keyword,
                            name: name,
                            query: loaded.content,
                            folderRank: folderRank,
                            relativePath: relativePath
                        )
                    }
                }

                var collected: [LinkedKeywordCandidate] = []
                for await candidate in group {
                    if let candidate { collected.append(candidate) }
                }
                return collected
            }
        }.value

        return Self.mergeLinkedKeywords(candidates)
    }

    /// The folder the user linked first wins, and inside one folder the shallower path wins, so a
    /// user can tell which of two files a keyword will reach by looking at the sidebar.
    internal static func mergeLinkedKeywords(
        _ candidates: [LinkedKeywordCandidate]
    ) -> [String: (name: String, query: String)] {
        var map: [String: (name: String, query: String)] = [:]
        for candidate in candidates.sorted(by: LinkedKeywordCandidate.precedes) where map[candidate.keyword] == nil {
            map[candidate.keyword] = (name: candidate.name, query: candidate.query)
        }
        return map
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
