//
//  HistoryPanelSelectionTests.swift
//  TableProTests
//
//  Tests for the selection that survives deleting a history entry.
//

import Foundation
@testable import TablePro
import Testing

@Suite("HistoryPanel selection after deletion")
struct HistoryPanelSelectionTests {
    @Test("Deleting a middle entry selects the entry that took its place")
    func middleDeletionKeepsPosition() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: 1, remainingCount: 3) == 1)
    }

    @Test("Deleting the last entry selects the new last entry")
    func lastDeletionMovesUp() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: 3, remainingCount: 3) == 2)
    }

    @Test("Deleting the first entry selects the new first entry")
    func firstDeletionSelectsFirst() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: 0, remainingCount: 5) == 0)
    }

    @Test("Deleting the only entry clears the selection")
    func emptyListClearsSelection() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: 0, remainingCount: 0) == nil)
    }

    @Test("A negative index clears the selection")
    func negativeIndexClearsSelection() {
        #expect(HistoryPanelView.selectionIndex(afterDeleting: -1, remainingCount: 4) == nil)
    }
}

@Suite("Query History Insights selection refresh")
struct QueryHistoryInsightsSelectionTests {
    @Test("Reload keeps the selected query and adopts its refreshed metrics")
    func reloadKeepsStableSelection() throws {
        let original = makeInsight(executionCount: 3, averageExecutionTime: 0.2)
        let updated = makeInsight(executionCount: 4, averageExecutionTime: 0.3)
        let selection = QueryHistoryInsightSelection(category: .mostRun, insight: original)
        let snapshot = QueryHistoryInsightSnapshot(mostRun: [updated], slowest: [], regressions: [])

        let refreshed = try #require(QueryHistoryInsightSelection.refreshed(selection, in: snapshot))

        #expect(refreshed == selection)
        #expect(refreshed.insight.executionCount == 4)
        #expect(refreshed.insight.averageExecutionTime == 0.3)
    }

    @Test("Reload clears a selection missing from its original category")
    func reloadClearsMissingSelection() {
        let insight = makeInsight(executionCount: 3, averageExecutionTime: 0.2)
        let selection = QueryHistoryInsightSelection(category: .mostRun, insight: insight)
        let snapshot = QueryHistoryInsightSnapshot(mostRun: [], slowest: [insight], regressions: [])

        #expect(QueryHistoryInsightSelection.refreshed(selection, in: snapshot) == nil)
    }

    private func makeInsight(executionCount: Int, averageExecutionTime: TimeInterval) -> QueryHistoryInsight {
        QueryHistoryInsight(
            connectionId: connectionId,
            databaseName: "analytics",
            query: "SELECT 1",
            executionCount: executionCount,
            successfulExecutionCount: executionCount,
            averageExecutionTime: averageExecutionTime,
            maximumExecutionTime: averageExecutionTime,
            lastExecutedAt: Date(timeIntervalSince1970: Double(executionCount)),
            recentExecutionCount: 0,
            recentAverageExecutionTime: 0,
            previousExecutionCount: 0,
            previousAverageExecutionTime: 0
        )
    }

    private let connectionId = UUID()
}
