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
    @Test("A selection identifies a query without capturing its metrics")
    func selectionIdentityIgnoresMetrics() {
        let original = makeInsight(executionCount: 3, averageExecutionTime: 0.2)
        let updated = makeInsight(executionCount: 4, averageExecutionTime: 0.3)

        let selection = QueryHistoryInsightSelection(category: .mostRun, insight: original)
        let afterReload = QueryHistoryInsightSelection(category: .mostRun, insight: updated)

        #expect(selection == afterReload)
        #expect(selection.hashValue == afterReload.hashValue)
    }

    @Test("The same query in two categories is two distinct selections")
    func selectionIsScopedToItsCategory() {
        let insight = makeInsight(executionCount: 3, averageExecutionTime: 0.2)

        let mostRun = QueryHistoryInsightSelection(category: .mostRun, insight: insight)
        let slowest = QueryHistoryInsightSelection(category: .slowest, insight: insight)

        #expect(mostRun != slowest)
    }

    @Test("Resolving a selection reads the metrics of the newest snapshot")
    func resolvingSelectionAdoptsRefreshedMetrics() throws {
        let original = makeInsight(executionCount: 3, averageExecutionTime: 0.2)
        let updated = makeInsight(executionCount: 4, averageExecutionTime: 0.3)
        let selection = QueryHistoryInsightSelection(category: .mostRun, insight: original)
        let snapshot = QueryHistoryInsightSnapshot(mostRun: [updated], slowest: [], regressions: [])

        let resolved = try #require(snapshot.insight(for: selection))

        #expect(resolved.executionCount == 4)
        #expect(resolved.averageExecutionTime == 0.3)
    }

    @Test("A selection missing from its original category no longer resolves")
    func selectionMissingFromCategoryDoesNotResolve() {
        let insight = makeInsight(executionCount: 3, averageExecutionTime: 0.2)
        let selection = QueryHistoryInsightSelection(category: .mostRun, insight: insight)
        let snapshot = QueryHistoryInsightSnapshot(mostRun: [], slowest: [insight], regressions: [])

        #expect(snapshot.insight(for: selection) == nil)
    }

    @Test("Each category resolves against its own list")
    func categoriesResolveAgainstTheirOwnList() throws {
        let frequent = makeInsight(executionCount: 9, averageExecutionTime: 0.1, query: "SELECT frequent")
        let slow = makeInsight(executionCount: 2, averageExecutionTime: 4.5, query: "SELECT slow")
        let regressed = makeInsight(executionCount: 6, averageExecutionTime: 1.0, query: "SELECT regressed")
        let snapshot = QueryHistoryInsightSnapshot(
            mostRun: [frequent],
            slowest: [slow],
            regressions: [regressed]
        )

        #expect(snapshot.insights(in: .mostRun) == [frequent])
        #expect(snapshot.insights(in: .slowest) == [slow])
        #expect(snapshot.insights(in: .regression) == [regressed])

        let slowestSelection = QueryHistoryInsightSelection(category: .slowest, insight: slow)
        let resolvedSlowest = try #require(snapshot.insight(for: slowestSelection))
        #expect(resolvedSlowest.query == "SELECT slow")
    }

    private func makeInsight(
        executionCount: Int,
        averageExecutionTime: TimeInterval,
        query: String = "SELECT 1"
    ) -> QueryHistoryInsight {
        QueryHistoryInsight(
            connectionId: connectionId,
            databaseName: "analytics",
            query: query,
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
