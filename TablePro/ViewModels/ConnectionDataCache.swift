//
//  ConnectionDataCache.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
internal final class ConnectionDataCache: ObservableObject {
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

    @Published private(set) var folders: [SQLFavoriteFolder] = []
    @Published private(set) var favorites: [SQLFavorite] = []
    @Published private(set) var linkedFolders: [LinkedSQLFolder] = []
    @Published private(set) var linkedFilesByFolderId: [UUID: [LinkedSQLFavorite]] = [:]
    @Published private(set) var isInitialLoadComplete: Bool = false

    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?

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
            .sink { [weak self] payload in
                guard let self else { return }
                guard payload == nil || payload == self.connectionId else { return }
                self.scheduleRefresh()
            }
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
            .filter { $0.connectionId == nil || $0.connectionId == connectionId }

        var loadedLinkedFiles: [UUID: [LinkedSQLFavorite]] = [:]
        for folder in allLinkedFolders where folder.isEnabled {
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
