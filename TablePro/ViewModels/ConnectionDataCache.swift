//
//  ConnectionDataCache.swift
//  TablePro
//

import Foundation
import Observation

@MainActor
@Observable
internal final class ConnectionDataCache {
    private static var instances: [UUID: ConnectionDataCache] = [:]

    static func shared(for connectionId: UUID) -> ConnectionDataCache {
        if let existing = instances[connectionId] { return existing }
        let cache = ConnectionDataCache(connectionId: connectionId)
        instances[connectionId] = cache
        return cache
    }

    let connectionId: UUID

    private(set) var folders: [SQLFavoriteFolder] = []
    private(set) var favorites: [SQLFavorite] = []
    private(set) var linkedFolders: [LinkedSQLFolder] = []
    private(set) var linkedFilesByFolderId: [UUID: [LinkedSQLFavorite]] = [:]
    private(set) var isInitialLoadComplete: Bool = false

    @ObservationIgnored private var favoritesObserver: NSObjectProtocol?
    @ObservationIgnored private var linkedObserver: NSObjectProtocol?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private init(connectionId: UUID) {
        self.connectionId = connectionId

        let reload: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }

        favoritesObserver = NotificationCenter.default.addObserver(
            forName: .sqlFavoritesDidUpdate,
            object: nil,
            queue: .main,
            using: reload
        )
        linkedObserver = NotificationCenter.default.addObserver(
            forName: .linkedSQLFoldersDidUpdate,
            object: nil,
            queue: .main,
            using: reload
        )
    }

    deinit {
        if let favoritesObserver {
            NotificationCenter.default.removeObserver(favoritesObserver)
        }
        if let linkedObserver {
            NotificationCenter.default.removeObserver(linkedObserver)
        }
        refreshTask?.cancel()
    }

    func ensureLoaded() {
        guard !isInitialLoadComplete, refreshTask == nil else { return }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await self?.runRefresh()
            self?.refreshTask = nil
        }
    }

    private func runRefresh() async {
        let connectionId = self.connectionId

        async let foldersResult = SQLFavoriteManager.shared.fetchFolders(connectionId: connectionId)
        async let favoritesResult = SQLFavoriteManager.shared.fetchFavorites(connectionId: connectionId)

        let allLinkedFolders = LinkedSQLFolderStorage.shared.loadFolders()
            .filter { $0.isEnabled }
            .filter { $0.connectionId == nil || $0.connectionId == connectionId }

        var loadedLinkedFiles: [UUID: [LinkedSQLFavorite]] = [:]
        for folder in allLinkedFolders {
            if Task.isCancelled { return }
            loadedLinkedFiles[folder.id] = await LinkedSQLIndex.shared.fetchAll(
                folderId: folder.id,
                folderURL: folder.expandedURL
            )
        }

        let resolvedFolders = await foldersResult
        let resolvedFavorites = await favoritesResult

        if Task.isCancelled { return }

        folders = resolvedFolders
        favorites = resolvedFavorites
        linkedFolders = allLinkedFolders
        linkedFilesByFolderId = loadedLinkedFiles
        isInitialLoadComplete = true
    }
}
