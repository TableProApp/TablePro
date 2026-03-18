//
//  HistoryDataProviderTests.swift
//  TableProTests
//
//  Tests for HistoryDataProvider async data loading.
//

import Foundation
@testable import TablePro
import Testing

@Suite("HistoryDataProvider", .serialized)
struct HistoryDataProviderTests {
    private let storage = QueryHistoryStorage.shared

    private func insertEntry(query: String = "SELECT 1") async -> QueryHistoryEntry {
        let entry = QueryHistoryEntry(
            query: query,
            connectionId: UUID(),
            databaseName: "testdb",
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        _ = await storage.addHistory(entry)
        return entry
    }

    @Test("Initial state: empty entries, count=0, isEmpty=true")
    func initialStateIsEmpty() {
        let provider = HistoryDataProvider()
        #expect(provider.count == 0)
        #expect(provider.isEmpty == true)
        #expect(provider.historyEntries.isEmpty)
    }

    @Test("Default dateFilter is .all")
    func defaultDateFilterIsAll() {
        let provider = HistoryDataProvider()
        #expect(provider.dateFilter == .all)
    }

    @Test("Default searchText is empty")
    func defaultSearchTextIsEmpty() {
        let provider = HistoryDataProvider()
        #expect(provider.searchText == "")
    }

    @Test("loadData populates historyEntries")
    func loadDataPopulatesEntries() async {
        let marker = UUID().uuidString
        _ = await insertEntry(query: "SELECT load_\(marker)")

        let provider = HistoryDataProvider()
        provider.searchText = marker
        await provider.loadData()

        #expect(provider.count >= 1)
        #expect(provider.historyEntries.contains { $0.query.contains(marker) })
    }

    @Test("loadData uses searchText when set")
    func loadDataUsesSearchText() async {
        let marker = UUID().uuidString
        _ = await insertEntry(query: "SELECT \(marker) FROM unique_hdp_table")

        let provider = HistoryDataProvider()
        provider.searchText = marker
        await provider.loadData()

        #expect(provider.count >= 1)
        #expect(provider.historyEntries.allSatisfy { $0.query.contains(marker) })
    }

    @Test("loadData invokes onDataChanged callback")
    func loadDataInvokesCallback() async {
        let provider = HistoryDataProvider()
        var callbackCalled = false
        provider.onDataChanged = { callbackCalled = true }

        await provider.loadData()

        #expect(callbackCalled == true)
    }

    @Test("historyEntry(at:) returns correct entry for valid index")
    func historyEntryAtValidIndex() async {
        let marker = UUID().uuidString
        _ = await insertEntry(query: "SELECT at_\(marker)")

        let provider = HistoryDataProvider()
        provider.searchText = marker
        await provider.loadData()

        let entry = provider.historyEntry(at: 0)
        #expect(entry != nil)
        #expect(entry?.query.contains(marker) == true)
    }

    @Test("historyEntry(at:) returns nil for out-of-bounds index")
    func historyEntryAtOutOfBounds() {
        let provider = HistoryDataProvider()
        #expect(provider.historyEntry(at: 0) == nil)
        #expect(provider.historyEntry(at: -1) == nil)
        #expect(provider.historyEntry(at: 999) == nil)
    }

    @Test("query(at:) returns query string")
    func queryAtReturnsQueryString() async {
        let marker = UUID().uuidString
        _ = await insertEntry(query: "SELECT query_\(marker)")

        let provider = HistoryDataProvider()
        provider.searchText = marker
        await provider.loadData()

        let query = provider.query(at: 0)
        #expect(query?.contains(marker) == true)
    }

    @Test("deleteEntry removes by UUID")
    func deleteEntryRemovesByUUID() async {
        let entry = await insertEntry(query: "SELECT to_delete_\(UUID().uuidString)")

        let provider = HistoryDataProvider()
        let result = await provider.deleteEntry(id: entry.id)
        #expect(result == true)

        // Verify the specific entry was deleted by trying to fetch it
        let entries = await storage.fetchHistory(limit: 1000)
        #expect(!entries.contains { $0.id == entry.id })
    }

    @Test("clearAll returns true and updates provider state")
    @MainActor
    func clearAllRemovesAllHistory() async {
        let marker = UUID().uuidString
        _ = await insertEntry(query: "SELECT clear_\(marker)")

        let provider = HistoryDataProvider()
        provider.searchText = marker
        await provider.loadData()
        #expect(provider.count >= 1)

        let result = await provider.clearAll()
        #expect(result == true)
        #expect(provider.count == 0)
        #expect(provider.isEmpty == true)
    }

    @Test("scheduleSearch debounces then loads data")
    @MainActor
    func scheduleSearchDebouncesAndLoads() async {
        let marker = UUID().uuidString
        _ = await insertEntry(query: "SELECT debounce_\(marker)")

        let provider = HistoryDataProvider()
        provider.searchText = marker

        await confirmation("search completes") { confirm in
            provider.scheduleSearch {
                confirm()
            }

            try? await Task.sleep(for: .milliseconds(400))
        }

        #expect(provider.count >= 1)
    }

    @Test("scheduleSearch cancels previous on rapid calls")
    @MainActor
    func scheduleSearchCancelsPrevious() async {
        let provider = HistoryDataProvider()
        var completionCount = 0

        provider.scheduleSearch {
            completionCount += 1
        }

        try? await Task.sleep(for: .milliseconds(50))
        provider.scheduleSearch {
            completionCount += 1
        }

        try? await Task.sleep(for: .milliseconds(400))

        #expect(completionCount == 1)
    }
}
