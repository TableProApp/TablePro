import Combine
import Foundation
import Observation

@MainActor
@Observable
final class HistoryPanelViewModel {
    static let pageSize = 60

    private(set) var sections: [QueryHistoryDaySection] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoadedOnce = false
    private(set) var hasMore = false
    private(set) var totalLoaded = 0

    var selectedEntryId: UUID?

    let state: HistoryPanelState

    private let connectionId: UUID
    private let history: QueryHistoryReading
    private let connectionDirectory: HistoryConnectionDirectory
    private let pageSize: Int

    private var entries: [QueryHistoryEntry] = []
    private var nextCursor: QueryHistoryCursor?
    private var loadToken = UUID()
    private var searchDebounce: Task<Void, Never>?
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

    func startObserving() {
        guard updateSubscription == nil else { return }
        updateSubscription = AppEvents.shared.queryHistoryDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self else { return }
                guard payload == nil || state.scope == .all || payload == state.scope.connectionId else { return }
                Task { await self.reload() }
            }
    }

    func stopObserving() {
        updateSubscription?.cancel()
        updateSubscription = nil
        searchDebounce?.cancel()
        searchDebounce = nil
    }

    // MARK: - Loading

    func reload() async {
        let token = UUID()
        loadToken = token

        if !hasLoadedOnce {
            isLoading = true
        }

        let page = await history.fetch(state.filter(), after: nil, limit: pageSize)
        guard loadToken == token else { return }

        entries = page.entries
        nextCursor = page.nextCursor
        hasMore = page.nextCursor != nil
        totalLoaded = entries.count
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
        let cleared = await history.clear(scope: state.scope, since: state.dateRange.since())
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
        return HistoryConnectionLabel(name: connection.name, color: connection.color)
    }

    static let none = HistoryConnectionDirectory { _ in nil }
}
