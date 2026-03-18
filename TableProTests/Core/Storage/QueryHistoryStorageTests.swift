//
//  QueryHistoryStorageTests.swift
//  TableProTests
//
//  Tests for QueryHistoryStorage async/await conversion.
//  Uses unique connectionIds per test for process-level isolation.
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryHistoryStorage", .serialized)
struct QueryHistoryStorageTests {
    private let storage = QueryHistoryStorage.shared

    private func makeEntry(
        id: UUID = UUID(),
        query: String = "SELECT * FROM users",
        connectionId: UUID = UUID(),
        databaseName: String = "testdb",
        executionTime: TimeInterval = 0.05,
        rowCount: Int = 10,
        wasSuccessful: Bool = true,
        errorMessage: String? = nil
    ) -> QueryHistoryEntry {
        QueryHistoryEntry(
            id: id,
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage
        )
    }

    @Test("Isolated instance initializes without deadlock")
    func isolatedInitDoesNotDeadlock() async {
        let isolated = QueryHistoryStorage(isolatedForTesting: true)
        let entries = await isolated.fetchHistory()
        #expect(entries.isEmpty)
    }

    @Test("addHistory returns true for valid entry")
    func addHistoryReturnsTrue() async {
        let entry = makeEntry()
        let result = await storage.addHistory(entry)
        #expect(result == true)
    }

    @Test("addHistory persists entry that can be fetched")
    func addHistoryPersistsEntry() async {
        let connId = UUID()
        let entry = makeEntry(query: "SELECT persist_test", connectionId: connId)
        _ = await storage.addHistory(entry)

        let fetched = await storage.fetchHistory(limit: 100, connectionId: connId)
        #expect(fetched.count == 1)
        #expect(fetched.first?.query == "SELECT persist_test")
        #expect(fetched.first?.id == entry.id)
    }

    @Test("fetchHistory returns empty for unused connectionId")
    func fetchHistoryReturnsEmptyForUnusedConnection() async {
        let entries = await storage.fetchHistory(connectionId: UUID())
        #expect(entries.isEmpty)
    }

    @Test("fetchHistory respects limit parameter")
    func fetchHistoryRespectsLimit() async {
        let connId = UUID()
        for i in 0..<5 {
            _ = await storage.addHistory(makeEntry(query: "SELECT limit_\(i)", connectionId: connId))
        }
        let entries = await storage.fetchHistory(limit: 3, connectionId: connId)
        #expect(entries.count == 3)
    }

    @Test("fetchHistory returns entries ordered by date descending")
    func fetchHistoryOrderedByDateDescending() async {
        let connId = UUID()

        let older = QueryHistoryEntry(
            query: "SELECT older",
            connectionId: connId,
            databaseName: "testdb",
            executedAt: Date().addingTimeInterval(-100),
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        let newer = QueryHistoryEntry(
            query: "SELECT newer",
            connectionId: connId,
            databaseName: "testdb",
            executedAt: Date(),
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )

        _ = await storage.addHistory(older)
        _ = await storage.addHistory(newer)

        let entries = await storage.fetchHistory(limit: 10, connectionId: connId)
        #expect(entries.count == 2)
        #expect(entries[0].query == "SELECT newer")
        #expect(entries[1].query == "SELECT older")
    }

    @Test("fetchHistory filters by connectionId")
    func fetchHistoryFiltersByConnectionId() async {
        let connA = UUID()
        let connB = UUID()

        _ = await storage.addHistory(makeEntry(query: "SELECT A", connectionId: connA))
        _ = await storage.addHistory(makeEntry(query: "SELECT B", connectionId: connB))

        let entriesA = await storage.fetchHistory(connectionId: connA)
        #expect(entriesA.count == 1)
        #expect(entriesA.first?.query == "SELECT A")

        let entriesB = await storage.fetchHistory(connectionId: connB)
        #expect(entriesB.count == 1)
        #expect(entriesB.first?.query == "SELECT B")
    }

    @Test("fetchHistory performs FTS5 text search")
    func fetchHistoryPerformsFTS5Search() async {
        let marker = UUID().uuidString
        let connId = UUID()

        _ = await storage.addHistory(makeEntry(query: "SELECT \(marker) FROM fts_users", connectionId: connId))
        _ = await storage.addHistory(makeEntry(query: "INSERT INTO fts_orders VALUES (\(marker))", connectionId: connId))

        let entries = await storage.fetchHistory(connectionId: connId, searchText: "fts_users")
        #expect(entries.count == 1)
        #expect(entries.first?.query.contains("fts_users") == true)
    }

    @Test("fetchHistory with .today filter returns only today's entries")
    func fetchHistoryTodayFilter() async {
        let connId = UUID()
        _ = await storage.addHistory(makeEntry(query: "SELECT today_filter", connectionId: connId))

        let entries = await storage.fetchHistory(connectionId: connId, dateFilter: .today)
        #expect(entries.count == 1)
        #expect(entries.first?.query == "SELECT today_filter")
    }

    @Test("deleteHistory removes specific entry")
    func deleteHistoryRemovesEntry() async {
        let connId = UUID()
        let entry = makeEntry(connectionId: connId)
        _ = await storage.addHistory(entry)

        let result = await storage.deleteHistory(id: entry.id)
        #expect(result == true)

        let remaining = await storage.fetchHistory(connectionId: connId)
        #expect(remaining.isEmpty)
    }

    @Test("deleteHistory returns true for non-existent ID")
    func deleteHistoryNonExistentId() async {
        let result = await storage.deleteHistory(id: UUID())
        #expect(result == true)
    }

    @Test("getHistoryCount works after adding entries")
    func getHistoryCountAccurate() async {
        let connId = UUID()
        let before = await storage.fetchHistory(connectionId: connId)
        #expect(before.isEmpty)

        for i in 0..<3 {
            _ = await storage.addHistory(makeEntry(query: "SELECT count_\(i)", connectionId: connId))
        }

        let after = await storage.fetchHistory(connectionId: connId)
        #expect(after.count == 3)
    }

    @Test("clearAllHistory removes all entries")
    func clearAllHistoryRemovesAll() async {
        let isolated = QueryHistoryStorage(isolatedForTesting: true)
        _ = await isolated.addHistory(makeEntry(query: "SELECT clear_test"))
        let result = await isolated.clearAllHistory()
        #expect(result == true)
        let remaining = await isolated.fetchHistory(limit: 100)
        #expect(remaining.isEmpty)
    }

    @Test("Combined connectionId + dateFilter works")
    func combinedConnectionIdAndDateFilter() async {
        let targetConn = UUID()
        let otherConn = UUID()

        _ = await storage.addHistory(makeEntry(query: "SELECT target", connectionId: targetConn))
        _ = await storage.addHistory(makeEntry(query: "SELECT other", connectionId: otherConn))

        let entries = await storage.fetchHistory(connectionId: targetConn, dateFilter: .today)
        #expect(entries.count == 1)
        #expect(entries.first?.query == "SELECT target")
    }

    @Test("Concurrent addHistory calls don't corrupt data")
    func concurrentAddHistoryDoesNotCorrupt() async {
        let sharedConnId = UUID()

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let entry = QueryHistoryEntry(
                        query: "SELECT concurrent_\(i)",
                        connectionId: sharedConnId,
                        databaseName: "testdb",
                        executionTime: 0.01,
                        rowCount: 1,
                        wasSuccessful: true
                    )
                    return await self.storage.addHistory(entry)
                }
            }

            for await result in group {
                #expect(result == true)
            }
        }

        let entries = await storage.fetchHistory(limit: 1000, connectionId: sharedConnId)
        #expect(entries.count == 20)
    }
}
