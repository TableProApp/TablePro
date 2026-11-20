import Combine
import Foundation
import os

@MainActor
final class QueryInsightsViewModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "QueryInsights")

    /// Recording a grid full of edits broadcasts once per statement, and every panel on this screen
    /// is a full aggregate. Collapsing the burst keeps one user action to one recomputation.
    private static let refreshDebounce = Duration.milliseconds(400)

    @Published private(set) var snapshot: QueryInsightsSnapshot = .empty
    @Published private(set) var hasLoadedContent = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isStoreUnavailable = false
    @Published private(set) var lastRefreshDate: Date?

    let connectionId: UUID

    @Published var showsAllConnections: Bool { didSet { persistAndReload(oldValue != showsAllConnections) } }
    @Published var sources: Set<QueryHistorySource> { didSet { persistAndReload(oldValue != sources) } }
    @Published var dateRange: HistoryDateRange { didSet { persistAndReload(oldValue != dateRange) } }
    @Published var slowestRanking: QueryInsightsSlowestRanking { didSet { persistAndReload(oldValue != slowestRanking) } }

    private let history: QueryHistoryReading
    // The active project's connections, or nil in All Connections.
    private let projectConnectionIds: @MainActor () -> Set<UUID>?
    private var isApplyingBulkChange = false
    private var loadToken = UUID()
    private var liveRefresh: Task<Void, Never>?
    private var updateSubscription: AnyCancellable?
    private var scopeSubscription: AnyCancellable?
    private let scopeChanged: AnyPublisher<Void, Never>
    private let appEvents: AppEvents

    init(
        connectionId: UUID,
        history: QueryHistoryReading,
        projectConnectionIds: @escaping @MainActor () -> Set<UUID>? = { ConnectionScope.shared.allowedConnectionIds },
        scopeChanged: AnyPublisher<Void, Never> = ConnectionScope.shared.scopedSetChanged,
        appEvents: AppEvents = .shared
    ) {
        self.appEvents = appEvents
        self.scopeChanged = scopeChanged
        self.connectionId = connectionId
        self.history = history
        self.projectConnectionIds = projectConnectionIds

        let preferences = QueryInsightsPreferencesStorage.load(for: connectionId)
        showsAllConnections = preferences.showsAllConnections
        sources = preferences.sources
        dateRange = preferences.dateRange
        slowestRanking = preferences.slowestRanking
    }

    var scope: QueryHistoryScope {
        showsAllConnections ? .all : .connection(connectionId)
    }

    // "All connections" means the active project's. In All Connections a run whose connection is gone still counts.
    func makeRequest(referenceDate: Date = Date()) -> QueryInsightsRequest {
        QueryInsightsRequest(
            scope: scope,
            sources: sources,
            since: dateRange.since(),
            referenceDate: referenceDate,
            allowedConnectionIds: scope == .all ? projectConnectionIds() : nil
        )
    }

    /// Measured against the filter the tab opens with, so an untouched screen never reports itself
    /// as filtered in its own empty state.
    var hasNarrowingFilter: Bool {
        let defaults = QueryInsightsPreferences.default
        return dateRange != defaults.dateRange || sources != defaults.sources
    }

    /// Both settings change together, so the reload is suppressed until they have, or one click
    /// persists twice and recomputes every panel twice.
    func resetFilters() {
        let defaults = QueryInsightsPreferences.default
        isApplyingBulkChange = true
        dateRange = defaults.dateRange
        sources = defaults.sources
        isApplyingBulkChange = false
        persistAndReload(true)
    }

    // MARK: - Lifecycle

    func activate() async {
        startObserving()
        await reload()
    }

    func deactivate() {
        updateSubscription?.cancel()
        updateSubscription = nil
        scopeSubscription?.cancel()
        scopeSubscription = nil
        liveRefresh?.cancel()
        liveRefresh = nil
    }

    private func startObserving() {
        guard updateSubscription == nil else { return }
        updateSubscription = appEvents.queryHistoryDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self else { return }
                guard payload == nil || showsAllConnections || payload == connectionId else { return }
                scheduleLiveRefresh()
            }
        // "All connections" counts the active project's. The token moves now, so figures already being
        // counted for the old scope are dropped when they land.
        scopeSubscription = scopeChanged
            .sink { [weak self] _ in
                guard let self, showsAllConnections else { return }
                loadToken = UUID()
                scheduleLiveRefresh()
            }
    }

    private func scheduleLiveRefresh() {
        liveRefresh?.cancel()
        liveRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDebounce)
            guard !Task.isCancelled, let self else { return }
            await reload()
        }
    }

    // MARK: - Loading

    /// Fetches before it commits, so a refresh never blanks the panels it is refreshing. Only a
    /// screen that has never had content shows a spinner; every later load swaps values under a
    /// quiet activity indicator.
    func reload() async {
        let token = UUID()
        loadToken = token
        isRefreshing = true

        let request = makeRequest()
        let available = await history.isStoreAvailable()
        let loaded = available ? await history.insights(request, slowestRanking: slowestRanking) : .empty

        guard loadToken == token else { return }

        isStoreUnavailable = !available
        snapshot = loaded
        hasLoadedContent = true
        isRefreshing = false
        lastRefreshDate = Date()

        Self.logger.debug("Loaded insights: \(loaded.totals.totalCount, privacy: .public) queries")
    }

    private func persistAndReload(_ changed: Bool) {
        guard changed, !isApplyingBulkChange else { return }
        QueryInsightsPreferencesStorage.save(
            QueryInsightsPreferences(
                showsAllConnections: showsAllConnections,
                sources: sources,
                dateRange: dateRange,
                slowestRanking: slowestRanking
            ),
            for: connectionId
        )
        Task { await reload() }
    }
}
