//
//  ConnectionDataCache.swift
//  TablePro
//

import Combine
import Foundation
import Observation

@MainActor
@Observable
internal final class ConnectionDataCache {
    private static let instances = NSMapTable<NSUUID, ConnectionDataCache>(
        keyOptions: .strongMemory,
        valueOptions: .weakMemory
    )

    static func shared(for connectionId: UUID) -> ConnectionDataCache {
        let key = connectionId as NSUUID
        if let existing = instances.object(forKey: key) { return existing }
        let cache = ConnectionDataCache(connectionId: connectionId)
        instances.setObject(cache, forKey: key)
        return cache
    }

    let connectionId: UUID

    private(set) var folders: [SQLFavoriteFolder] = []
    private(set) var favorites: [SQLFavorite] = []
    private(set) var linkedFolders: [LinkedSQLFolder] = []
    private(set) var linkedFilesByFolderId: [UUID: [LinkedSQLFavorite]] = [:]
    private(set) var isInitialLoadComplete: Bool = false

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private init(connectionId: UUID) {
        self.connectionId = connectionId

        AppEvents.shared.sqlFavoritesDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self else { return }
                guard payload == nil || payload == self.connectionId else { return }
                self.scheduleRefresh()
            }
            .store(in: &cancellables)

        AppEvents.shared.linkedSQLFoldersDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
    }

    deinit {
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
