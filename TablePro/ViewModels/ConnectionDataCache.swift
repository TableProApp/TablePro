//
//  ConnectionDataCache.swift
//  TablePro
//

import Combine
import Foundation

/// What one refresh read, before any of it is published.
///
/// Fetching and committing are separate so a refresh that has been overtaken can be thrown away
/// whole. Committing field by field as each one arrived is what let an older read leave part of
/// itself behind.
internal struct ConnectionFavoritesSnapshot: Equatable {
    internal var folders: [SQLFavoriteFolder] = []
    internal var favorites: [SQLFavorite] = []
    internal var linkedFolders: [LinkedSQLFolder] = []
    internal var linkedFilesByFolderId: [UUID: [LinkedSQLFavorite]] = [:]
}

@MainActor
internal final class ConnectionDataCache: ObservableObject {
    /// Held strongly and released by `removeConnection`, the shape `SharedSidebarState`,
    /// `SidebarViewModel`, `HistoryPanelState` and `QuickSwitcherCatalogStore` all use.
    ///
    /// A weakly held instance had no owner at all: the connection-open warm-up dropped its only
    /// reference inside the statement that made it, so `deinit` cancelled the load it had just
    /// started, and the Favorites tab then paid for the whole load again on every visit.
    private static var registry: [UUID: ConnectionDataCache] = [:]

    static func shared(for connectionId: UUID) -> ConnectionDataCache {
        if let existing = registry[connectionId] { return existing }
        let cache = ConnectionDataCache(connectionId: connectionId)
        registry[connectionId] = cache
        return cache
    }

    /// Dropping the entry is not enough on its own. A mounted Favorites tab holds its cache through
    /// a `@StateObject` and outlives this call, so an instance left armed would go on reading the
    /// disk for a connection that has closed, and the next `shared(for:)` would build a second one
    /// beside it. Under the old weakly held table the instance simply went; now it has to be told.
    static func removeConnection(_ connectionId: UUID) {
        registry.removeValue(forKey: connectionId)?.retire()
    }

    private func retire() {
        refreshTask?.cancel()
        refreshTask = nil
        cancellables.removeAll()
    }

    let connectionId: UUID

    @Published private(set) var folders: [SQLFavoriteFolder] = []
    @Published private(set) var favorites: [SQLFavorite] = []
    @Published private(set) var linkedFolders: [LinkedSQLFolder] = []
    @Published private(set) var linkedFilesByFolderId: [UUID: [LinkedSQLFavorite]] = [:]
    @Published private(set) var isInitialLoadComplete: Bool = false

    /// Bumped once per committed snapshot, after the content lands. A reader that derives something
    /// from this cache can hold the derived value against this number rather than rebuilding it on
    /// every read. `objectWillChange` cannot serve as that key, because it fires before each value
    /// lands and would date the derivation to the content on its way out.
    private(set) var contentRevision: Int = 0

    private var cancellables: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var currentGeneration: Int = 0

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

    /// Cancelling is cooperative, so the task being replaced still runs its body to the end. It has
    /// to be able to tell that it was overtaken, or it clears the handle of the refresh that
    /// replaced it: the next event then finds no task to cancel and starts a second one beside the
    /// first, and whichever finishes last wins. A burst of iCloud favorite updates arrives as one
    /// event per record, so two reads in flight is ordinary rather than rare.
    private func scheduleRefresh() {
        let generation = nextRefreshGeneration()
        refreshTask = Task { @MainActor [weak self] in
            await self?.runRefresh(generation: generation)
            guard let self, self.currentGeneration == generation else { return }
            self.refreshTask = nil
        }
    }

    /// Opening a generation retires the read it supersedes, so the handle can never be left
    /// pointing at a task nothing will clear. `ensureLoaded` reads that handle to decide whether a
    /// load is already running, and a stale one would make it a no-op for good.
    internal func nextRefreshGeneration() -> Int {
        refreshTask?.cancel()
        refreshTask = nil
        currentGeneration += 1
        return currentGeneration
    }

    private func runRefresh(generation: Int) async {
        guard let snapshot = await loadSnapshot() else { return }
        commit(snapshot, generation: generation)
    }

    /// Returns nil when the read was cancelled part way, so a half-read snapshot never reaches
    /// `commit`.
    private func loadSnapshot() async -> ConnectionFavoritesSnapshot? {
        let connectionId = self.connectionId

        async let foldersResult = SQLFavoriteManager.shared.fetchFolders(connectionId: connectionId)
        async let favoritesResult = SQLFavoriteManager.shared.fetchFavorites(connectionId: connectionId)

        let allLinkedFolders = LinkedSQLFolderStorage.shared.loadFolders()
            .filter { $0.connectionId == nil || $0.connectionId == connectionId }

        var loadedLinkedFiles: [UUID: [LinkedSQLFavorite]] = [:]
        for folder in allLinkedFolders where folder.isEnabled {
            if Task.isCancelled { return nil }
            loadedLinkedFiles[folder.id] = await LinkedSQLIndex.shared.fetchAll(
                folderId: folder.id,
                folderURL: folder.expandedURL
            )
        }

        let resolvedFolders = await foldersResult
        let resolvedFavorites = await favoritesResult

        if Task.isCancelled { return nil }

        return ConnectionFavoritesSnapshot(
            folders: resolvedFolders,
            favorites: resolvedFavorites,
            linkedFolders: allLinkedFolders,
            linkedFilesByFolderId: loadedLinkedFiles
        )
    }

    /// A read that a later one overtook is dropped rather than published, however long it took to
    /// come back.
    internal func commit(_ snapshot: ConnectionFavoritesSnapshot, generation: Int) {
        guard generation == currentGeneration else { return }

        folders = snapshot.folders
        favorites = snapshot.favorites
        linkedFolders = snapshot.linkedFolders
        linkedFilesByFolderId = snapshot.linkedFilesByFolderId
        contentRevision += 1
        isInitialLoadComplete = true
    }
}
