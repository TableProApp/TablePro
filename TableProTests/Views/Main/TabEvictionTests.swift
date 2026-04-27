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
@MainActor
struct TabEvictionTests {

    // MARK: - Helpers

    private func makeTestRows(count: Int) -> [[String?]] {
        (0..<count).map { ["value_\($0)"] }
    }

    private struct TestTab {
        let tab: QueryTab
        let buffer: RowBuffer
    }

    private func makeTestTab(
        store: RowDataStore,
        id: UUID = UUID(),
        tabType: TabType = .table,
        rowCount: Int = 0,
        lastExecutedAt: Date? = nil,
        isEvicted: Bool = false,
        hasUnsavedChanges: Bool = false
    ) -> TestTab {
        var tab = QueryTab(id: id, title: "Test", query: "SELECT 1", tabType: tabType)
        tab.execution.lastExecutedAt = lastExecutedAt

        let buffer: RowBuffer
        if rowCount > 0 {
            buffer = RowBuffer(
                rows: makeTestRows(count: rowCount),
                columns: ["col1"],
                columnTypes: [.text(rawType: "VARCHAR")]
            )
        } else {
            buffer = RowBuffer()
        }
        store.setBuffer(buffer, for: tab.id)

        if isEvicted {
            buffer.evict()
        }

        if hasUnsavedChanges {
            tab.pendingChanges.deletedRowIndices = [0]
        }

        return TestTab(tab: tab, buffer: buffer)
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
        let store = RowDataStore()
        let entry = makeTestTab(
            store: store,
            rowCount: 10,
            lastExecutedAt: Date(),
            hasUnsavedChanges: true
        )

        let isCandidate = !entry.buffer.isEvicted
            && !entry.buffer.rows.isEmpty
            && entry.tab.execution.lastExecutedAt != nil
            && !entry.tab.pendingChanges.hasChanges

        #expect(isCandidate == false)
    }

    @Test("Eviction candidate filter excludes active, evicted, empty, and unsaved tabs")
    func evictionCandidateFiltering() {
        let store = RowDataStore()
        let activeId = UUID()
        let entryA = makeTestTab(store: store, id: activeId, rowCount: 10, lastExecutedAt: Date())
        let entryB = makeTestTab(store: store, rowCount: 10, lastExecutedAt: Date(), isEvicted: true)
        let entryC = makeTestTab(store: store, rowCount: 0, lastExecutedAt: Date())
        let entryD = makeTestTab(store: store, rowCount: 10, lastExecutedAt: Date(), hasUnsavedChanges: true)
        let entryE = makeTestTab(store: store, rowCount: 10, lastExecutedAt: Date())

        let activeTabIds: Set<UUID> = [activeId]
        let allEntries = [entryA, entryB, entryC, entryD, entryE]

        let candidates = allEntries.filter {
            !activeTabIds.contains($0.tab.id)
                && !$0.buffer.isEvicted
                && !$0.buffer.rows.isEmpty
                && $0.tab.execution.lastExecutedAt != nil
                && !$0.tab.pendingChanges.hasChanges
        }

        #expect(candidates.count == 1)
        #expect(candidates.first?.tab.id == entryE.tab.id)
    }

    // MARK: - Budget-Based Eviction

    @Test("Eviction keeps the 2 most recently executed inactive tabs")
    func evictionKeepsTwoMostRecent() {
        let store = RowDataStore()
        let now = Date()
        let entries = (0..<5).map { i in
            makeTestTab(
                store: store,
                rowCount: 10,
                lastExecutedAt: now.addingTimeInterval(Double(i) * 60)
            )
        }

        let activeTabIds: Set<UUID> = []
        let candidates = entries.filter {
            !activeTabIds.contains($0.tab.id)
                && !$0.buffer.isEvicted
                && !$0.buffer.rows.isEmpty
                && $0.tab.execution.lastExecutedAt != nil
                && !$0.tab.pendingChanges.hasChanges
        }

        let sorted = candidates.sorted {
            ($0.tab.execution.lastExecutedAt ?? .distantFuture) < ($1.tab.execution.lastExecutedAt ?? .distantFuture)
        }

        let maxInactiveLoaded = 2
        let toEvict = Array(sorted.dropLast(maxInactiveLoaded))

        #expect(toEvict.count == 3)

        for entry in toEvict {
            entry.buffer.evict()
        }

        let evictedIds = Set(toEvict.map(\.tab.id))

        // The 2 newest (index 3 and 4) should NOT be evicted
        #expect(!evictedIds.contains(entries[3].tab.id))
        #expect(!evictedIds.contains(entries[4].tab.id))

        // The 3 oldest (index 0, 1, 2) should be evicted
        #expect(entries[0].buffer.isEvicted == true)
        #expect(entries[1].buffer.isEvicted == true)
        #expect(entries[2].buffer.isEvicted == true)
        #expect(entries[3].buffer.isEvicted == false)
        #expect(entries[4].buffer.isEvicted == false)
    }

    @Test("No tabs evicted when candidates are within budget")
    func noEvictionWithinBudget() {
        let store = RowDataStore()
        let now = Date()
        let entries = (0..<2).map { i in
            makeTestTab(
                store: store,
                rowCount: 10,
                lastExecutedAt: now.addingTimeInterval(Double(i) * 60)
            )
        }

        let activeTabIds: Set<UUID> = []
        let candidates = entries.filter {
            !activeTabIds.contains($0.tab.id)
                && !$0.buffer.isEvicted
                && !$0.buffer.rows.isEmpty
                && $0.tab.execution.lastExecutedAt != nil
                && !$0.tab.pendingChanges.hasChanges
        }

        let sorted = candidates.sorted {
            ($0.tab.execution.lastExecutedAt ?? .distantFuture) < ($1.tab.execution.lastExecutedAt ?? .distantFuture)
        }

        let maxInactiveLoaded = 2
        let shouldEvict = sorted.count > maxInactiveLoaded

        #expect(shouldEvict == false)

        for entry in entries {
            #expect(entry.buffer.isEvicted == false)
            #expect(entry.buffer.rows.count == 10)
        }
    }
}
