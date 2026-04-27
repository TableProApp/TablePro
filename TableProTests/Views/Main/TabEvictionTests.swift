//
//  TabEvictionTests.swift
//  TableProTests
//
//  Tests for tab data eviction logic: RowBuffer eviction/restore behavior
//  and the candidate filtering + budget logic used by evictInactiveTabs.
//

import Foundation
import Testing
@testable import TablePro

@Suite("Tab Eviction")
struct TabEvictionTests {

    // MARK: - Helpers

    private func makeTestRows(count: Int) -> [[String?]] {
        (0..<count).map { ["value_\($0)"] }
    }

    private func makeTestTab(
        id: UUID = UUID(),
        tabType: TabType = .table,
        rowCount: Int = 0,
        lastExecutedAt: Date? = nil,
        isEvicted: Bool = false,
        hasUnsavedChanges: Bool = false
    ) -> QueryTab {
        var tab = QueryTab(id: id, title: "Test", query: "SELECT 1", tabType: tabType)
        tab.execution.lastExecutedAt = lastExecutedAt

        if rowCount > 0 {
            let rows = makeTestRows(count: rowCount)
            tab.rowBuffer = RowBuffer(
                rows: rows,
                columns: ["col1"],
                columnTypes: [.text(rawType: "VARCHAR")]
            )
        }

        if isEvicted {
            tab.rowBuffer.evict()
        }

        if hasUnsavedChanges {
            tab.pendingChanges.deletedRowIndices = [0]
        }

        return tab
    }

    // MARK: - RowBuffer Eviction

    @Test("RowBuffer evict clears rows and sets isEvicted flag")
    func rowBufferEvictClearsRows() {
        let buffer = RowBuffer(
            rows: makeTestRows(count: 5),
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR")]
        )

        #expect(buffer.rows.count == 5)
        #expect(buffer.isEvicted == false)

        buffer.evict()

        #expect(buffer.rows.isEmpty)
        #expect(buffer.isEvicted == true)
        #expect(buffer.columns == ["id", "name"])
        #expect(buffer.columnTypes.count == 2)
    }

    @Test("RowBuffer evict is idempotent")
    func rowBufferEvictIdempotent() {
        let buffer = RowBuffer(
            rows: makeTestRows(count: 3),
            columns: ["col1"],
            columnTypes: [.text(rawType: nil)]
        )

        buffer.evict()
        buffer.evict()

        #expect(buffer.rows.isEmpty)
        #expect(buffer.isEvicted == true)
    }

    @Test("RowBuffer restore repopulates rows and clears evicted flag")
    func rowBufferRestoreAfterEviction() {
        let buffer = RowBuffer(
            rows: makeTestRows(count: 5),
            columns: ["col1"],
            columnTypes: [.text(rawType: nil)]
        )

        buffer.evict()
        #expect(buffer.rows.isEmpty)
        #expect(buffer.isEvicted == true)

        let newRows = makeTestRows(count: 3)
        buffer.restore(rows: newRows)

        #expect(buffer.isEvicted == false)
        #expect(buffer.rows.count == 3)
    }

    // MARK: - Eviction Candidate Filtering

    @Test("Tabs with pending changes are excluded from eviction candidates")
    func tabsWithPendingChangesExcluded() {
        let tab = makeTestTab(
            rowCount: 10,
            lastExecutedAt: Date(),
            hasUnsavedChanges: true
        )

        let isCandidate = !tab.rowBuffer.isEvicted
            && !tab.resultRows.isEmpty
            && tab.execution.lastExecutedAt != nil
            && !tab.pendingChanges.hasChanges

        #expect(isCandidate == false)
    }

    @Test("Eviction candidate filter excludes active, evicted, empty, and unsaved tabs")
    func evictionCandidateFiltering() {
        let activeId = UUID()
        let tabA = makeTestTab(id: activeId, rowCount: 10, lastExecutedAt: Date())
        let tabB = makeTestTab(rowCount: 10, lastExecutedAt: Date(), isEvicted: true)
        let tabC = makeTestTab(rowCount: 0, lastExecutedAt: Date())
        let tabD = makeTestTab(rowCount: 10, lastExecutedAt: Date(), hasUnsavedChanges: true)
        let tabE = makeTestTab(rowCount: 10, lastExecutedAt: Date())

        let activeTabIds: Set<UUID> = [activeId]
        let allTabs = [tabA, tabB, tabC, tabD, tabE]

        let candidates = allTabs.filter {
            !activeTabIds.contains($0.id)
                && !$0.rowBuffer.isEvicted
                && !$0.resultRows.isEmpty
                && $0.execution.lastExecutedAt != nil
                && !$0.pendingChanges.hasChanges
        }

        #expect(candidates.count == 1)
        #expect(candidates.first?.id == tabE.id)
    }

    // MARK: - Budget-Based Eviction

    @Test("Eviction keeps the 2 most recently executed inactive tabs")
    func evictionKeepsTwoMostRecent() {
        let now = Date()
        let tabs = (0..<5).map { i in
            makeTestTab(
                rowCount: 10,
                lastExecutedAt: now.addingTimeInterval(Double(i) * 60)
            )
        }

        let activeTabIds: Set<UUID> = []
        let candidates = tabs.filter {
            !activeTabIds.contains($0.id)
                && !$0.rowBuffer.isEvicted
                && !$0.resultRows.isEmpty
                && $0.execution.lastExecutedAt != nil
                && !$0.pendingChanges.hasChanges
        }

        let sorted = candidates.sorted {
            ($0.execution.lastExecutedAt ?? .distantFuture) < ($1.execution.lastExecutedAt ?? .distantFuture)
        }

        let maxInactiveLoaded = 2
        let toEvict = Array(sorted.dropLast(maxInactiveLoaded))

        #expect(toEvict.count == 3)

        for tab in toEvict {
            tab.rowBuffer.evict()
        }

        let evictedIds = Set(toEvict.map(\.id))

        // The 2 newest (index 3 and 4) should NOT be evicted
        #expect(!evictedIds.contains(tabs[3].id))
        #expect(!evictedIds.contains(tabs[4].id))

        // The 3 oldest (index 0, 1, 2) should be evicted
        #expect(tabs[0].rowBuffer.isEvicted == true)
        #expect(tabs[1].rowBuffer.isEvicted == true)
        #expect(tabs[2].rowBuffer.isEvicted == true)
        #expect(tabs[3].rowBuffer.isEvicted == false)
        #expect(tabs[4].rowBuffer.isEvicted == false)
    }

    @Test("No tabs evicted when candidates are within budget")
    func noEvictionWithinBudget() {
        let now = Date()
        let tabs = (0..<2).map { i in
            makeTestTab(
                rowCount: 10,
                lastExecutedAt: now.addingTimeInterval(Double(i) * 60)
            )
        }

        let activeTabIds: Set<UUID> = []
        let candidates = tabs.filter {
            !activeTabIds.contains($0.id)
                && !$0.rowBuffer.isEvicted
                && !$0.resultRows.isEmpty
                && $0.execution.lastExecutedAt != nil
                && !$0.pendingChanges.hasChanges
        }

        let sorted = candidates.sorted {
            ($0.execution.lastExecutedAt ?? .distantFuture) < ($1.execution.lastExecutedAt ?? .distantFuture)
        }

        let maxInactiveLoaded = 2
        let shouldEvict = sorted.count > maxInactiveLoaded

        #expect(shouldEvict == false)

        // Verify no tabs were evicted
        for tab in tabs {
            #expect(tab.rowBuffer.isEvicted == false)
            #expect(tab.resultRows.count == 10)
        }
    }
}
