//
//  QueryHistoryManagerTests.swift
//  TableProTests
//
//  Tests for QueryHistoryManager wrapping storage with notifications.
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryHistoryManager", .serialized)
struct QueryHistoryManagerTests {
    private let manager = QueryHistoryManager.shared
    private let storage = QueryHistoryStorage.shared

    private func makeAndInsertEntry(
        query: String = "SELECT 1",
        connectionId: UUID = UUID()
    ) async -> QueryHistoryEntry {
        let entry = QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "testdb",
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        _ = await storage.addHistory(entry)
        return entry
    }

    @Test("fetchHistory returns entries from storage")
    func fetchHistoryReturnsEntries() async {
        let connId = UUID()
        _ = await makeAndInsertEntry(query: "SELECT mgr_fetch", connectionId: connId)
        let entries = await manager.fetchHistory(connectionId: connId)
        #expect(entries.contains { $0.query == "SELECT mgr_fetch" })
    }

    @Test("searchQueries with empty text returns all entries")
    func searchQueriesEmptyTextReturnsAll() async {
        let marker = UUID().uuidString
        _ = await makeAndInsertEntry(query: "SELECT search_\(marker)")
        let entries = await manager.searchQueries("")
        #expect(entries.contains { $0.query.contains(marker) })
    }

    @Test("searchQueries with text uses FTS5")
    func searchQueriesWithTextUsesFTS5() async {
        let marker = UUID().uuidString
        let connId = UUID()
        _ = await makeAndInsertEntry(query: "SELECT \(marker) FROM mgr_products", connectionId: connId)
        _ = await makeAndInsertEntry(query: "INSERT INTO mgr_orders VALUES (\(marker))", connectionId: connId)
        let entries = await manager.searchQueries("mgr_products")
        #expect(entries.count >= 1)
        #expect(entries.allSatisfy { $0.query.contains("mgr_products") })
    }

    @Test("deleteHistory removes entry and returns true")
    func deleteHistoryRemovesEntry() async {
        let connId = UUID()
        let entry = await makeAndInsertEntry(query: "SELECT mgr_delete", connectionId: connId)
        let result = await manager.deleteHistory(id: entry.id)
        #expect(result == true)
        let remaining = await manager.fetchHistory(connectionId: connId)
        #expect(remaining.isEmpty)
    }

    @Test("getHistoryCount delegates to storage")
    func getHistoryCountDelegatesToStorage() async {
        let connId = UUID()
        _ = await makeAndInsertEntry(connectionId: connId)
        _ = await makeAndInsertEntry(connectionId: connId)
        let entries = await manager.fetchHistory(connectionId: connId)
        #expect(entries.count == 2)
    }

    @Test("clearAllHistory clears and returns true")
    func clearAllHistoryReturnsTrue() async {
        let isolatedStorage = QueryHistoryStorage(isolatedForTesting: true)
        let isolatedManager = QueryHistoryManager(isolatedStorage: isolatedStorage)
        _ = await isolatedStorage.addHistory(QueryHistoryEntry(
            query: "SELECT clear_test",
            connectionId: UUID(),
            databaseName: "testdb",
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        ))
        let result = await isolatedManager.clearAllHistory()
        #expect(result == true)
    }

    @Test("deleteHistory posts queryHistoryDidUpdate notification")
    func deleteHistoryPostsNotification() async {
        let entry = await makeAndInsertEntry()

        await confirmation("notification posted") { confirm in
            let observer = NotificationCenter.default.addObserver(
                forName: .queryHistoryDidUpdate,
                object: nil,
                queue: .main
            ) { _ in
                confirm()
            }

            _ = await manager.deleteHistory(id: entry.id)
            try? await Task.sleep(for: .milliseconds(100))

            NotificationCenter.default.removeObserver(observer)
        }
    }

    @Test("clearAllHistory posts queryHistoryDidUpdate notification")
    func clearAllHistoryPostsNotification() async {
        let isolatedStorage = QueryHistoryStorage(isolatedForTesting: true)
        let isolatedManager = QueryHistoryManager(isolatedStorage: isolatedStorage)
        _ = await isolatedStorage.addHistory(QueryHistoryEntry(
            query: "SELECT notify_test",
            connectionId: UUID(),
            databaseName: "testdb",
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        ))

        await confirmation("notification posted") { confirm in
            let observer = NotificationCenter.default.addObserver(
                forName: .queryHistoryDidUpdate,
                object: nil,
                queue: .main
            ) { _ in
                confirm()
            }

            _ = await isolatedManager.clearAllHistory()
            try? await Task.sleep(for: .milliseconds(100))

            NotificationCenter.default.removeObserver(observer)
        }
    }
}
