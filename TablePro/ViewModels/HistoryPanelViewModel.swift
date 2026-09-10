import Combine
import Foundation
import Observation

@MainActor
@Observable
final class HistoryPanelViewModel {
    static let pageSize = 60
    static let maximumRefreshWindow = 600

    private(set) var sections: [QueryHistoryDaySection] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoadedOnce = false
    private(set) var hasMore = false
    private(set) var totalLoaded = 0
    /// An unreadable store returns the same empty page as a store with nothing in it, so without
    /// this the drawer stated positively that no query had ever been recorded.
    private(set) var isStoreUnavailable = false

    var selectedEntryId: UUID?

    let state: HistoryPanelState

    private let connectionId: UUID
    private let history: QueryHistoryReading
    private let connectionDirectory: HistoryConnectionDirectory
    private let pageSize: Int

    private var entries: [QueryHistoryEntry] = []
    private var nextCursor: QueryHistoryCursor?
    private var loadedPageCount = 1
    private var loadToken = UUID()
    private var searchDebounce: Task<Void, Never>?
    private var liveRefresh: Task<Void, Never>?
    private var updateSubscription: AnyCancellable?

    init(
        connectionId: UUID,
        history: QueryHistoryReading,
        connectionDirectory: HistoryConnectionDirectory = .live,
        pageSize: Int = HistoryPanelViewModel.pageSize
    ) {
        self.connectionId = connectionId
        self.history = history
        self.connectionDirectory = connectionDirectory
        self.pageSize = pageSize
        self.state = HistoryPanelState.forConnection(connectionId)
    }

    convenience init(connectionId: UUID, services: AppServices) {
        self.init(connectionId: connectionId, history: services.queryHistoryManager)
    }

    var selectedEntry: QueryHistoryEntry? {
        guard let selectedEntryId else { return nil }
        return entries.first { $0.id == selectedEntryId }
    }

    var isEmpty: Bool { entries.isEmpty }

    func connectionLabel(for entry: QueryHistoryEntry) -> HistoryConnectionLabel? {
        guard state.showsConnectionColumn else { return nil }
        return connectionDirectory.label(entry.connectionId)
    }

    // MARK: - Lifecycle

    /// The drawer is collapsed rather than removed, so the view never disappears and its lifecycle
    /// cannot say when the panel stops mattering. Visibility is the signal that actually changes,
    /// and a panel nobody can see has no reason to hold a subscription or refetch behind them.
    var isObserving: Bool { updateSubscription != nil }

    func activate() async {
        startObserving()
        await reload()
    }

    func deactivate() {
        stopObserving()
    }

    func startObserving() {
        guard updateSubscription == nil else { return }
        updateSubscription = AppEvents.shared.queryHistoryDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self else { return }
                guard payload == nil || state.scope == .all || payload == state.scope.connectionId else { return }
                scheduleLiveRefresh()
            }
    }

    func stopObserving() {
        updateSubscription?.cancel()
        updateSubscription = nil
        searchDebounce?.cancel()
        searchDebounce = nil
        liveRefresh?.cancel()
        liveRefresh = nil
    }

    /// Saving a grid full of edits or importing a file records one entry per statement, and each
    /// one broadcasts. Collapsing the burst keeps the list from refetching hundreds of times for a
    /// single user action.
    private func scheduleLiveRefresh() {
        liveRefresh?.cancel()
        liveRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            await reload(preservingLoadedWindow: true)
        }
    }

    // MARK: - Loading

    /// A live refresh keeps everything the user paged in, because replacing a scrolled list with
    /// its own first page throws away the Load More they asked for. Changing a filter starts over,
    /// because the old depth means nothing against a new question.
    func reload(preservingLoadedWindow: Bool = false) async {
        let token = UUID()
        loadToken = token

        if !hasLoadedOnce {
            isLoading = true
        }

        if !preservingLoadedWindow {
            loadedPageCount = 1
        }
        let windowLimit = min(max(pageSize, loadedPageCount * pageSize), Self.maximumRefreshWindow)
        let page = await history.fetch(state.filter(), after: nil, limit: windowLimit)
        let storeAvailable = await history.isStoreAvailable()
        guard loadToken == token else { return }

        isStoreUnavailable = !storeAvailable

        entries = page.entries
        nextCursor = page.nextCursor
        hasMore = page.nextCursor != nil
        totalLoaded = entries.count
        loadedPageCount = max(1, Int(ceil(Double(entries.count) / Double(pageSize))))
        rebuildSections()

        isLoading = false
        hasLoadedOnce = true

        if let selectedEntryId, !entries.contains(where: { $0.id == selectedEntryId }) {
            self.selectedEntryId = nil
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let token = loadToken
        let page = await history.fetch(state.filter(), after: cursor, limit: pageSize)
        guard loadToken == token else { return }

        entries.append(contentsOf: page.entries)
        nextCursor = page.nextCursor
        hasMore = page.nextCursor != nil
        totalLoaded = entries.count
        loadedPageCount += 1
        rebuildSections()
    }

    func scheduleSearchReload() {
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await reload()
        }
    }

    // MARK: - Mutating

    func delete(_ entry: QueryHistoryEntry) async {
        let removedIndex = entries.firstIndex { $0.id == entry.id }
        guard await history.delete(id: entry.id) else { return }

        entries.removeAll { $0.id == entry.id }
        totalLoaded = entries.count
        rebuildSections()

        guard selectedEntryId == entry.id else { return }
        guard let removedIndex, !entries.isEmpty else {
            selectedEntryId = nil
            return
        }
        selectedEntryId = entries[min(removedIndex, entries.count - 1)].id
    }

    func deleteSelection() async {
        guard let selectedEntry else { return }
        await delete(selectedEntry)
    }

    @discardableResult
    func clearVisibleScope() async -> Bool {
        let cleared = await history.clear(matching: state.filter())
        if cleared {
            selectedEntryId = nil
            await reload()
        }
        return cleared
    }

    // MARK: - Sections

    private func rebuildSections() {
        sections = QueryHistoryGrouping.byDay(entries)
    }
}

struct HistoryConnectionLabel: Equatable, Sendable {
    let name: String
    let color: ConnectionColor?
}

struct HistoryConnectionDirectory: Sendable {
    let label: @MainActor @Sendable (UUID) -> HistoryConnectionLabel?

    static let live = HistoryConnectionDirectory { connectionId in
        guard let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId })
        else { return nil }
        return HistoryConnectionLabel(name: connection.name, color: connection.identityColor)
    }

    static let none = HistoryConnectionDirectory { _ in nil }
}
