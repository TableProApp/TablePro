import Foundation
import Observation

@MainActor
@Observable
final class HistoryPanelState {
    let connectionId: UUID

    var isVisible: Bool { didSet { persistIfChanged(oldValue != isVisible) } }
    var showsAllConnections: Bool { didSet { persistIfChanged(oldValue != showsAllConnections) } }
    var pinnedConnectionId: UUID? { didSet { persistIfChanged(oldValue != pinnedConnectionId) } }
    var sources: Set<QueryHistorySource> { didSet { persistIfChanged(oldValue != sources) } }
    var dateRange: HistoryDateRange { didSet { persistIfChanged(oldValue != dateRange) } }
    var outcome: QueryHistoryOutcome { didSet { persistIfChanged(oldValue != outcome) } }

    /// Search text is deliberately not persisted: a stale query on relaunch reads as an empty
    /// history rather than as a filter the user forgot they left behind.
    var searchText: String = ""

    /// Device-local and shared by every connection, because pausing is a decision about this Mac
    /// rather than about one database.
    var isCapturePaused: Bool {
        get { QueryHistoryCaptureState.shared.isPaused }
        set { QueryHistoryCaptureState.shared.isPaused = newValue }
    }

    private init(connectionId: UUID) {
        self.connectionId = connectionId
        let preferences = HistoryPanelPreferencesStorage.load(for: connectionId)
        isVisible = preferences.isVisible
        showsAllConnections = preferences.showsAllConnections
        pinnedConnectionId = preferences.pinnedConnectionId
        sources = preferences.sources
        dateRange = preferences.dateRange
        outcome = preferences.outcome
    }

    var scope: QueryHistoryScope {
        if let pinnedConnectionId {
            return .connection(pinnedConnectionId)
        }
        return showsAllConnections ? .all : .connection(connectionId)
    }

    var showsConnectionColumn: Bool {
        scope.connectionId != connectionId
    }

    func filter(referenceDate: Date = Date()) -> QueryHistoryFilter {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return QueryHistoryFilter(
            scope: scope,
            sources: sources,
            outcome: outcome,
            searchText: trimmed.isEmpty ? nil : trimmed,
            since: dateRange.since(from: referenceDate)
        )
    }

    /// Measured against the filter the panel opens with, not against "everything selected".
    /// The source filter starts narrowed to the user's own queries, so comparing it to the full
    /// set would report an untouched panel as filtered and show the wrong empty state.
    var hasNarrowingFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || dateRange != HistoryPanelPreferences.default.dateRange
            || outcome != HistoryPanelPreferences.default.outcome
            || sources != HistoryPanelPreferences.default.sources
    }

    func resetFilters() {
        let defaults = HistoryPanelPreferences.default
        searchText = ""
        dateRange = defaults.dateRange
        outcome = defaults.outcome
        sources = defaults.sources
    }

    private func persistIfChanged(_ changed: Bool) {
        guard changed else { return }
        HistoryPanelPreferencesStorage.save(
            HistoryPanelPreferences(
                isVisible: isVisible,
                showsAllConnections: showsAllConnections,
                pinnedConnectionId: pinnedConnectionId,
                sources: sources,
                dateRange: dateRange,
                outcome: outcome
            ),
            for: connectionId
        )
    }

    private static var registry: [UUID: HistoryPanelState] = [:]

    static func forConnection(_ id: UUID) -> HistoryPanelState {
        if let existing = registry[id] { return existing }
        let state = HistoryPanelState(connectionId: id)
        registry[id] = state
        return state
    }

    static func removeConnection(_ id: UUID) {
        registry.removeValue(forKey: id)
    }
}
