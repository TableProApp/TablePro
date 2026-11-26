//
//  SQLFavoriteManager.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProImport
import TableProSyncTransport
import TableProUtilities

internal final class SQLFavoriteManager: @unchecked Sendable {
    static let shared = SQLFavoriteManager(
        storage: SQLFavoriteStorage(onSetAside: { DamagedStoreNotice.savedQueriesSetAside($0) }),
        core: .shared
    )
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFavoriteManager")

    private let storage: SQLFavoriteStorage
    private let syncJournal: SyncHostJournal
    private let appEvents: @MainActor @Sendable () -> AppEvents
    private let operations = MainActorSerialQueue()
    // Nil keeps the saved queries out of the core, for a store nothing else reads.
    internal let coreMirror: CoreMirror<SavedQueryCoreAdapter>?

    init(
        storage: SQLFavoriteStorage = SQLFavoriteStorage(),
        syncJournal: SyncHostJournal = .shared,
        appEvents: @escaping @MainActor @Sendable @autoclosure () -> AppEvents = .shared,
        core: CoreHistoryDatabase? = nil,
        mirrorDefaults: UserDefaults = AppStorageEnvironment.shared.defaults
    ) {
        self.storage = storage
        self.syncJournal = syncJournal
        self.appEvents = appEvents
        coreMirror = core.map { database in
            let adapter = SavedQueryCoreAdapter(storage: storage, database: database) { queries, folders in
                await MainActor.run {
                    syncJournal.recorded(.favorite, written: queries.map(\.uuidString))
                    syncJournal.recorded(.favoriteFolder, written: folders.map(\.uuidString))
                    appEvents().sqlFavoritesDidUpdate.send(nil)
                }
            }
            return CoreMirror(adapter: adapter, defaults: mirrorDefaults)
        }
    }

    // At launch, and after a write: the core takes what the store holds.
    @discardableResult
    func pushToCore() async -> Bool {
        await coreMirror?.push() ?? true
    }

    // MARK: - Favorites

    func addFavorite(_ favorite: SQLFavorite) async -> Bool {
        await operations.run { [self] in
            guard await storage.addFavorite(favorite) else { return false }
            syncJournal.recorded(.favorite, written: [favorite.id.uuidString])
            postUpdateNotification(connectionId: favorite.connectionId)
            return true
        }
    }

    func updateFavorite(_ favorite: SQLFavorite) async -> Bool {
        await operations.run { [self] in
            let result = await storage.updateFavorite(favorite)
            guard result.succeeded else { return false }
            syncJournal.recorded(.favorite, written: [favorite.id.uuidString])
            postUpdateNotification(for: result, newConnectionId: favorite.connectionId)
            return true
        }
    }

    // A delete waits for the core's copy and reports a failure while the core still holds the SQL.
    func deleteFavorite(id: UUID) async -> Bool {
        let deleted = await operations.run { [self] in
            guard await storage.deleteFavorites(ids: [id]) != nil else { return false }
            syncJournal.recorded(.favorite, deleted: [id.uuidString])
            postUpdateNotification(connectionId: nil)
            return true
        }
        guard deleted else { return false }
        return await pushToCore()
    }

    func deleteFavorites(ids: [UUID]) async {
        await operations.run { [self] in
            guard await storage.deleteFavorites(ids: ids) != nil else { return }
            syncJournal.recorded(.favorite, deleted: ids.map(\.uuidString))
            postUpdateNotification(connectionId: nil)
        }
        await pushToCore()
    }

    /// Journals every record it removed, the same as the other delete paths, so a deleted
    /// connection's SQL favorites and folders do not outlive it in iCloud.
    func removeFavoritesAndFolders(for connectionId: UUID) async {
        await operations.run { [self] in
            guard let removed = await storage.deleteFavoritesAndFolders(connectionId: connectionId),
                  !removed.isEmpty else { return }
            syncJournal.recorded(.favorite, deleted: removed.favorites.map(\.uuidString))
            syncJournal.recorded(.favoriteFolder, deleted: removed.folders.map(\.uuidString))
            recordDetached(removed.detached)
            postUpdateNotification(connectionId: nil)
        }
        await pushToCore()
    }

    /// A row that survived the delete holding a reference the delete had to clear is a local edit
    /// like any other. Without it the survivor kept the deleted folder's id everywhere else and on
    /// a fresh install, while this Mac drew it correctly.
    @MainActor
    private func recordDetached(_ detached: DetachedFavoriteRecords) {
        guard !detached.isEmpty else { return }
        syncJournal.recorded(.favorite, written: detached.favorites.map(\.uuidString))
        syncJournal.recorded(.favoriteFolder, written: detached.folders.map(\.uuidString))
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

    func ledgerEntries() async -> [SavedQueryLedger.Entry]? {
        await storage.readAllFavorites()?.map(\.ledgerEntry)
    }

    func exportSnapshot() async -> (favorites: [SQLFavorite], folders: [SQLFavoriteFolder])? {
        await storage.readAllFavoritesAndFolders()
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
            syncJournal.recorded(.favorite, written: [version.favoriteId.uuidString])
            postUpdateNotification(connectionId: result.retainedScope)
            return true
        }
    }

    // MARK: - Folders

    func addFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        await operations.run { [self] in
            guard await storage.addFolder(folder) else { return false }
            syncJournal.recorded(.favoriteFolder, written: [folder.id.uuidString])
            postUpdateNotification(connectionId: folder.connectionId)
            return true
        }
    }

    func updateFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        await operations.run { [self] in
            let result = await storage.updateFolder(folder)
            guard result.succeeded else { return false }
            syncJournal.recorded(.favoriteFolder, written: [folder.id.uuidString])
            postUpdateNotification(for: result, newConnectionId: folder.connectionId)
            return true
        }
    }

    /// The records the delete moved up a level are journaled with the folder's deletion.
    ///
    /// Deleting a folder reparents what was inside it, and only the folder itself used to be told
    /// to sync. The moved records kept the id of the deleted folder on the wire, so a device
    /// fetching the account fresh stored a `folderId` matching no folder.
    func deleteFolder(id: UUID) async -> Bool {
        let deleted = await operations.run { [self] in
            guard let deletion = await storage.deleteFolder(id: id) else { return false }
            syncJournal.recorded(.favoriteFolder, deleted: [id.uuidString])
            syncJournal.recorded(.favorite, written: deletion.movedFavorites.map(\.uuidString))
            syncJournal.recorded(.favoriteFolder, written: deletion.movedFolders.map(\.uuidString))
            postUpdateNotification(connectionId: nil)
            return true
        }
        guard deleted else { return false }
        return await pushToCore()
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
            syncJournal.recorded(.favoriteFolder, written: [id.uuidString])
            postUpdateNotification(connectionId: result.retainedScope)
            return true
        }
    }

    func setFolderScope(id: UUID, connectionId: UUID?) async -> Bool {
        await operations.run { [self] in
            let result = await storage.setFolderScope(id: id, connectionId: connectionId)
            guard result.succeeded else { return false }
            syncJournal.recorded(.favoriteFolder, written: [id.uuidString])
            postUpdateNotification(for: result, newConnectionId: connectionId)
            return true
        }
    }

    func setFavoriteFolder(id: UUID, folderId: UUID?) async -> Bool {
        await operations.run { [self] in
            let result = await storage.setFavoriteFolder(id: id, folderId: folderId)
            guard result.succeeded else { return false }
            syncJournal.recorded(.favorite, written: [id.uuidString])
            postUpdateNotification(connectionId: result.retainedScope)
            return true
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
        coreMirror?.schedulePush()
        let appEvents = appEvents
        Task { @MainActor in
            appEvents().sqlFavoritesDidUpdate.send(connectionId)
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

extension SQLFavoriteManager: SavedQueryImportStore {
    /// Journals once per record type after the transaction commits, so an import of hundreds is
    /// two journal entries.
    func importSavedQueries(_ queries: [PlannedQuery]) async -> SavedQueryImportWrite? {
        await operations.run { [self] in
            guard let write = await storage.importSavedQueries(queries) else { return nil }
            syncJournal.recorded(.favoriteFolder, written: write.createdFolderIds.map(\.uuidString))
            syncJournal.recorded(.favorite, written: write.insertedIds.map(\.uuidString))
            if !write.insertedIds.isEmpty || !write.createdFolderIds.isEmpty {
                coreMirror?.schedulePush()
                appEvents().sqlFavoritesDidUpdate.send(nil)
            }
            return write
        }
    }
}
