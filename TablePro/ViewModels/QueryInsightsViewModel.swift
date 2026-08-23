import Combine
import Foundation
import Observation
import os

@MainActor
@Observable
final class QueryInsightsViewModel {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "QueryInsights")

    /// Recording a grid full of edits broadcasts once per statement, and every panel on this screen
    /// is a full aggregate. Collapsing the burst keeps one user action to one recomputation.
    private static let refreshDebounce = Duration.milliseconds(400)

    private(set) var snapshot: QueryInsightsSnapshot = .empty
    private(set) var hasLoadedContent = false
    private(set) var isRefreshing = false
    private(set) var isStoreUnavailable = false
    private(set) var lastRefreshDate: Date?

    let connectionId: UUID

    var showsAllConnections: Bool { didSet { persistAndReload(oldValue != showsAllConnections) } }
    var sources: Set<QueryHistorySource> { didSet { persistAndReload(oldValue != sources) } }
    var dateRange: HistoryDateRange { didSet { persistAndReload(oldValue != dateRange) } }
    var slowestRanking: QueryInsightsSlowestRanking { didSet { persistAndReload(oldValue != slowestRanking) } }

    private let history: QueryHistoryReading
    private var isApplyingBulkChange = false
    private var loadToken = UUID()
    private var liveRefresh: Task<Void, Never>?
    private var updateSubscription: AnyCancellable?

    init(connectionId: UUID, history: QueryHistoryReading) {
        self.connectionId = connectionId
        self.history = history

        let preferences = QueryInsightsPreferencesStorage.load(for: connectionId)
        showsAllConnections = preferences.showsAllConnections
        sources = preferences.sources
        dateRange = preferences.dateRange
        slowestRanking = preferences.slowestRanking
    }

    var scope: QueryHistoryScope {
        showsAllConnections ? .all : .connection(connectionId)
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
        liveRefresh?.cancel()
        liveRefresh = nil
    }

    private func startObserving() {
        guard updateSubscription == nil else { return }
        updateSubscription = AppEvents.shared.queryHistoryDidUpdate
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self else { return }
                guard payload == nil || showsAllConnections || payload == connectionId else { return }
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

        let request = QueryInsightsRequest(
            scope: scope,
            sources: sources,
            since: dateRange.since(),
            referenceDate: Date()
        )
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
