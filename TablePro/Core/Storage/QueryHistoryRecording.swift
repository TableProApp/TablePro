import Foundation

protocol QueryHistoryRecording: Sendable {
    @discardableResult
    func record(_ request: QueryHistoryRecordRequest) async -> Bool
}

protocol QueryHistoryReading: Sendable {
    func fetch(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) async -> QueryHistoryPage
    func delete(id: UUID) async -> Bool
    func clear(matching filter: QueryHistoryFilter) async -> Bool
    func count(scope: QueryHistoryScope) async -> Int
    /// False when the store could not be opened, which `fetch` cannot say for itself: it returns
    /// the same empty page for "no rows" and for "could not read", and the drawer rendered that as
    /// a positive statement that nothing had ever been recorded.
    func isStoreAvailable() async -> Bool

    func insights(
        _ request: QueryInsightsRequest,
        slowestRanking: QueryInsightsSlowestRanking
    ) async -> QueryInsightsSnapshot
}

/// Saved EXPLAIN plans. Separate from `QueryHistoryReading` because a plan is a different artifact
/// with a different lifetime, and because the comparison pane needs only these four calls.
protocol QueryPlanSnapshotReading: Sendable {
    func planSnapshots(
        matching identity: QueryPlanIdentity,
        excluding excludedId: UUID?,
        limit: Int
    ) async -> [QueryPlanSnapshotSummary]

    func planSnapshotRawText(id: UUID) async -> String?

    @discardableResult
    func setPlanSnapshotPinned(id: UUID, isPinned: Bool) async -> Bool

    func isStoreAvailable() async -> Bool
}

extension QueryHistoryReading {
    func isStoreAvailable() async -> Bool { true }

    func insights(
        _ request: QueryInsightsRequest,
        slowestRanking: QueryInsightsSlowestRanking
    ) async -> QueryInsightsSnapshot {
        .empty
    }
}

extension QueryHistoryReading {
    func fetch(_ filter: QueryHistoryFilter, limit: Int) async -> QueryHistoryPage {
        await fetch(filter, after: nil, limit: limit)
    }

    func clearEverything() async -> Bool {
        await clear(matching: QueryHistoryFilter(scope: .all))
    }
}
