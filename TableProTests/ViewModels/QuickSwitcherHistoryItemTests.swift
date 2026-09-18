//
//  QuickSwitcherHistoryItemTests.swift
//  TableProTests
//
//  The switcher is a recall list, so it must not be flooded by one statement run many times,
//  and a long favourites list must not push recent queries out of it entirely.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Quick Switcher history items")
struct QuickSwitcherHistoryItemTests {
    private func makeEntry(query: String, connectionId: UUID = UUID(), at date: Date = Date()) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "db",
            databaseType: .postgresql,
            source: .editor,
            executedAt: date,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
    }

    private func makeItem(_ id: String, kind: QuickSwitcherItemKind) -> QuickSwitcherItem {
        QuickSwitcherItem(id: id, name: id, kind: kind, subtitle: "")
    }

    @Test("repeated executions collapse to one entry")
    func repeatedExecutionsCollapse() {
        let connectionId = UUID()
        let base = Date()
        let entries = (0 ..< 20).map { index in
            makeEntry(
                query: "SELECT * FROM users",
                connectionId: connectionId,
                at: base.addingTimeInterval(-Double(index))
            )
        }

        let distinct = QuickSwitcherViewModel.distinctByQuery(entries)
        #expect(distinct.count == 1)
    }

    @Test("the most recent execution is the one kept")
    func mostRecentExecutionSurvives() {
        let connectionId = UUID()
        let now = Date()
        let newest = makeEntry(query: "SELECT a", connectionId: connectionId, at: now)
        let older = makeEntry(query: "SELECT a", connectionId: connectionId, at: now.addingTimeInterval(-600))

        let distinct = QuickSwitcherViewModel.distinctByQuery([newest, older])
        #expect(distinct.count == 1)
        #expect(distinct.first?.id == newest.id)
    }

    @Test("statements differing only in whitespace still count as distinct text")
    func trimOnlyCollapsesOuterWhitespace() {
        let connectionId = UUID()
        let plain = makeEntry(query: "SELECT a", connectionId: connectionId)
        let padded = makeEntry(query: "  SELECT a\n", connectionId: connectionId)
        let different = makeEntry(query: "SELECT  a", connectionId: connectionId)

        #expect(QuickSwitcherViewModel.distinctByQuery([plain, padded]).count == 1)
        #expect(QuickSwitcherViewModel.distinctByQuery([plain, different]).count == 2)
    }

    @Test("blank statements are dropped rather than shown as an empty row")
    func blankStatementsAreDropped() {
        #expect(QuickSwitcherViewModel.distinctByQuery([makeEntry(query: "   ")]).isEmpty)
    }

    @Test("a long favourites list cannot push every recent query out")
    func favoritesDoNotCrowdOutHistory() {
        let favorites = (0 ..< 300).map { makeItem("favorite_\($0)", kind: .savedQuery) }
        let history = (0 ..< 300).map { makeItem("history_\($0)", kind: .queryHistory) }

        let merged = QuickSwitcherViewModel.interleaveToCap(favorites, history, cap: 200)

        #expect(merged.count == 200)
        #expect(merged.contains { $0.kind == .queryHistory })
        #expect(merged.filter { $0.kind == .queryHistory }.count == 100)
    }

    @Test("a source lends its unused slots to the other")
    func unusedSlotsAreLent() {
        let favorites = (0 ..< 5).map { makeItem("favorite_\($0)", kind: .savedQuery) }
        let history = (0 ..< 300).map { makeItem("history_\($0)", kind: .queryHistory) }

        let merged = QuickSwitcherViewModel.interleaveToCap(favorites, history, cap: 200)

        #expect(merged.count == 200)
        #expect(merged.filter { $0.kind == .savedQuery }.count == 5)
        #expect(merged.filter { $0.kind == .queryHistory }.count == 195)
    }

    @Test("nothing is dropped when both fit")
    func nothingDroppedWhenUnderCap() {
        let favorites = (0 ..< 10).map { makeItem("favorite_\($0)", kind: .savedQuery) }
        let history = (0 ..< 10).map { makeItem("history_\($0)", kind: .queryHistory) }

        let merged = QuickSwitcherViewModel.interleaveToCap(favorites, history, cap: 200)
        #expect(merged.count == 20)
    }
}
