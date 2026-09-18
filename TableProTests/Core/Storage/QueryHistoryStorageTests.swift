//
//  QueryHistoryStorageTests.swift
//  TableProTests
//
//  Tests for the query history SQLite actor.
//  Uses unique connectionIds per test for process-level isolation.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("QueryHistoryStorage")
struct QueryHistoryStorageTests {
    private let storage: QueryHistoryStorage

    init() {
        self.storage = Self.makeIsolatedStorage()
    }

    static func makeIsolatedStorage() -> QueryHistoryStorage {
        QueryHistoryStorage(databaseURL: makeIsolatedURL(), removeDatabaseOnDeinit: true)
    }

    static func makeIsolatedURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("query_history_\(UUID().uuidString).db")
    }

    private func makeEntry(
        id: UUID = UUID(),
        query: String = "SELECT * FROM users",
        connectionId: UUID = UUID(),
        databaseName: String = "testdb",
        databaseType: DatabaseType = .postgresql,
        schemaName: String? = nil,
        source: QueryHistorySource = .editor,
        executedAt: Date = Date(),
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
            databaseType: databaseType,
            schemaName: schemaName,
            source: source,
            executedAt: executedAt,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage
        )
    }

    private func fetchAll(
        _ storage: QueryHistoryStorage,
        connectionId: UUID? = nil,
        searchText: String? = nil,
        sources: Set<QueryHistorySource> = Set(QueryHistorySource.allCases),
        outcome: QueryHistoryOutcome = .any,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 200
    ) async -> [QueryHistoryEntry] {
        await storage.fetch(
            QueryHistoryFilter(
                scope: connectionId.map { .connection($0) } ?? .all,
                sources: sources,
                outcome: outcome,
                searchText: searchText,
                since: since,
                until: until
            ),
            after: nil,
            limit: limit
        ).entries
    }

    // MARK: - Basics

    @Test("Isolated instance initializes without deadlock")
    func isolatedInitDoesNotDeadlock() async {
        let isolated = Self.makeIsolatedStorage()
        let entries = await fetchAll(isolated)
        #expect(entries.isEmpty)
    }

    @Test("record returns true for a valid entry")
    func recordReturnsTrue() async {
        let entry = makeEntry()
        #expect(await storage.record(entry))
    }

    @Test("record persists every field")
    func recordPersistsAllFields() async {
        let connId = UUID()
        let entry = makeEntry(
            query: "SELECT id FROM accounts",
            connectionId: connId,
            databaseName: "shop",
            databaseType: .clickhouse,
            schemaName: "analytics",
            source: .rowEdit,
            executionTime: 0.25,
            rowCount: 42,
            wasSuccessful: false,
            errorMessage: "boom"
        )
        #expect(await storage.record(entry))

        let fetched = await fetchAll(storage, connectionId: connId)
        let stored = fetched.first
        #expect(fetched.count == 1)
        #expect(stored?.query == "SELECT id FROM accounts")
        #expect(stored?.databaseName == "shop")
        #expect(stored?.databaseType == .clickhouse)
        #expect(stored?.schemaName == "analytics")
        #expect(stored?.source == .rowEdit)
        #expect(stored?.statementType == .select)
        #expect(stored?.rowCount == 42)
        #expect(stored?.wasSuccessful == false)
        #expect(stored?.errorMessage == "boom")
    }

    @Test("fetch returns empty for an unused connectionId")
    func fetchReturnsEmptyForUnusedConnection() async {
        let entries = await fetchAll(storage, connectionId: UUID())
        #expect(entries.isEmpty)
    }

    @Test("fetch respects the limit")
    func fetchRespectsLimit() async {
        let connId = UUID()
        for index in 0 ..< 5 {
            _ = await storage.record(makeEntry(query: "SELECT limit_\(index)", connectionId: connId))
        }
        let entries = await fetchAll(storage, connectionId: connId, limit: 3)
        #expect(entries.count == 3)
    }

    @Test("fetch orders by executedAt descending")
    func fetchOrdersByDateDescending() async {
        let connId = UUID()
        let older = makeEntry(
            query: "SELECT older",
            connectionId: connId,
            executedAt: Date().addingTimeInterval(-3_600)
        )
        let newer = makeEntry(query: "SELECT newer", connectionId: connId, executedAt: Date())

        _ = await storage.record(older)
        _ = await storage.record(newer)

        let entries = await fetchAll(storage, connectionId: connId)
        #expect(entries.first?.query == "SELECT newer")
        #expect(entries.last?.query == "SELECT older")
    }

    @Test("fetch filters by connectionId")
    func fetchFiltersByConnectionId() async {
        let connA = UUID()
        let connB = UUID()
        _ = await storage.record(makeEntry(query: "SELECT A", connectionId: connA))
        _ = await storage.record(makeEntry(query: "SELECT B", connectionId: connB))

        let entriesA = await fetchAll(storage, connectionId: connA)
        #expect(entriesA.count == 1)
        #expect(entriesA.first?.query == "SELECT A")

        let entriesB = await fetchAll(storage, connectionId: connB)
        #expect(entriesB.count == 1)
        #expect(entriesB.first?.query == "SELECT B")
    }

    // MARK: - Search

    @Test("fetch performs full-text search")
    func fetchPerformsFullTextSearch() async {
        let connId = UUID()
        _ = await storage.record(makeEntry(query: "SELECT a FROM fts_users", connectionId: connId))
        _ = await storage.record(makeEntry(query: "INSERT INTO fts_orders VALUES (1)", connectionId: connId))

        let entries = await fetchAll(storage, connectionId: connId, searchText: "fts_users")
        #expect(entries.count == 1)
        #expect(entries.first?.query.contains("fts_users") == true)
    }

    @Test("search matches a partial word so results appear while typing")
    func searchMatchesPrefix() async {
        let connId = UUID()
        _ = await storage.record(makeEntry(query: "SELECT * FROM customers", connectionId: connId))

        for typed in ["cust", "custom", "customer", "customers"] {
            let entries = await fetchAll(storage, connectionId: connId, searchText: typed)
            #expect(entries.count == 1, "typing \(typed) should match")
        }
    }

    @Test("search matches words that are not next to each other")
    func searchMatchesNonAdjacentWords() async {
        let connId = UUID()
        _ = await storage.record(makeEntry(query: "SELECT * FROM customers WHERE active = 1", connectionId: connId))

        for typed in ["select customers", "customers select", "sel cust", "from active"] {
            let entries = await fetchAll(storage, connectionId: connId, searchText: typed)
            #expect(entries.count == 1, "typing \(typed) should match")
        }
    }

    @Test("every word in the search has to match")
    func searchRequiresEveryWord() async {
        let connId = UUID()
        _ = await storage.record(makeEntry(query: "SELECT * FROM customers", connectionId: connId))

        let entries = await fetchAll(storage, connectionId: connId, searchText: "customers zzz")
        #expect(entries.isEmpty)
    }

    @Test("search survives quotes and FTS operators without erroring")
    func searchIsInjectionSafe() async {
        let connId = UUID()
        _ = await storage.record(makeEntry(query: "SELECT * FROM safe_table", connectionId: connId))

        for hostile in ["\"", "a\"b", "AND OR NOT", "***", "safe_table\" OR \""] {
            let entries = await fetchAll(storage, connectionId: connId, searchText: hostile)
            #expect(entries.count <= 1)
        }
    }

    // MARK: - Filters

    @Test("fetch filters by source")
    func fetchFiltersBySource() async {
        let connId = UUID()
        _ = await storage.record(makeEntry(query: "SELECT typed", connectionId: connId, source: .editor))
        _ = await storage.record(makeEntry(query: "SELECT browsed", connectionId: connId, source: .tableBrowse))

        let authored = await fetchAll(storage, connectionId: connId, sources: QueryHistorySource.userAuthored)
        #expect(authored.count == 1)
        #expect(authored.first?.query == "SELECT typed")

        let everything = await fetchAll(storage, connectionId: connId)
        #expect(everything.count == 2)
    }

    @Test("fetch filters by outcome")
    func fetchFiltersByOutcome() async {
        let connId = UUID()
        _ = await storage.record(makeEntry(query: "SELECT good", connectionId: connId, wasSuccessful: true))
        _ = await storage.record(makeEntry(query: "SELECT bad", connectionId: connId, wasSuccessful: false))

        let failed = await fetchAll(storage, connectionId: connId, outcome: .failed)
        #expect(failed.count == 1)
        #expect(failed.first?.query == "SELECT bad")

        let succeeded = await fetchAll(storage, connectionId: connId, outcome: .succeeded)
        #expect(succeeded.count == 1)
        #expect(succeeded.first?.query == "SELECT good")
    }

    @Test("fetch with an empty source set returns nothing rather than everything")
    func fetchWithNoSourcesReturnsNothing() async {
        let connId = UUID()
        _ = await storage.record(makeEntry(connectionId: connId))
        let entries = await fetchAll(storage, connectionId: connId, sources: [])
        #expect(entries.isEmpty)
    }

    @Test("fetch honours a since and until window")
    func fetchHonoursDateWindow() async {
        let connId = UUID()
        let now = Date()
        let outside = makeEntry(
            query: "SELECT outside",
            connectionId: connId,
            executedAt: now.addingTimeInterval(-7_200)
        )
        let inside = makeEntry(
            query: "SELECT inside",
            connectionId: connId,
            executedAt: now.addingTimeInterval(-60)
        )
        _ = await storage.record(outside)
        _ = await storage.record(inside)

        let windowed = await fetchAll(
            storage,
            connectionId: connId,
            since: now.addingTimeInterval(-600),
            until: now
        )
        #expect(windowed.count == 1)
        #expect(windowed.first?.query == "SELECT inside")
    }

    // MARK: - Pagination

    @Test("keyset pagination walks every entry exactly once")
    func keysetPaginationCoversEveryEntry() async {
        let connId = UUID()
        let total = 25
        let base = Date()
        for index in 0 ..< total {
            _ = await storage.record(
                makeEntry(
                    query: "SELECT page_\(index)",
                    connectionId: connId,
                    executedAt: base.addingTimeInterval(-Double(index))
                )
            )
        }

        var seen: [String] = []
        var cursor: QueryHistoryCursor?
        var pages = 0
        repeat {
            let page = await storage.fetch(
                QueryHistoryFilter(scope: .connection(connId)),
                after: cursor,
                limit: 10
            )
            seen.append(contentsOf: page.entries.map(\.query))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10

        #expect(seen.count == total)
        #expect(Set(seen).count == total)
    }

    @Test("a page shorter than the limit reports no further cursor")
    func lastPageHasNoCursor() async {
        let connId = UUID()
        _ = await storage.record(makeEntry(connectionId: connId))
        let page = await storage.fetch(QueryHistoryFilter(scope: .connection(connId)), after: nil, limit: 10)
        #expect(page.entries.count == 1)
        #expect(page.nextCursor == nil)
    }

    @Test("entries sharing a timestamp still paginate without repeating")
    func paginationBreaksTimestampTies() async {
        let connId = UUID()
        let sameInstant = Date()
        for index in 0 ..< 6 {
            _ = await storage.record(
                makeEntry(query: "SELECT tie_\(index)", connectionId: connId, executedAt: sameInstant)
            )
        }

        var seen: [String] = []
        var cursor: QueryHistoryCursor?
        var pages = 0
        repeat {
            let page = await storage.fetch(
                QueryHistoryFilter(scope: .connection(connId)),
                after: cursor,
                limit: 2
            )
            seen.append(contentsOf: page.entries.map(\.query))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10

        #expect(seen.count == 6)
        #expect(Set(seen).count == 6)
    }

    // MARK: - Deleting

    @Test("delete removes a specific entry")
    func deleteRemovesEntry() async {
        let connId = UUID()
        let entry = makeEntry(connectionId: connId)
        _ = await storage.record(entry)

        #expect(await storage.delete(id: entry.id))
        let remaining = await fetchAll(storage, connectionId: connId)
        #expect(remaining.isEmpty)
    }

    @Test("delete reports success for an unknown id")
    func deleteUnknownIdSucceeds() async {
        #expect(await storage.delete(id: UUID()))
    }

    @Test("clear scoped to one connection leaves the others intact")
    func clearScopedToConnection() async {
        let isolated = Self.makeIsolatedStorage()
        let keep = UUID()
        let drop = UUID()
        _ = await isolated.record(makeEntry(query: "SELECT keep", connectionId: keep))
        _ = await isolated.record(makeEntry(query: "SELECT drop", connectionId: drop))

        #expect(await isolated.clear(matching: QueryHistoryFilter(scope: .connection(drop))))

        let remaining = await fetchAll(isolated)
        #expect(remaining.count == 1)
        #expect(remaining.first?.query == "SELECT keep")
    }

    @Test("clear all removes every entry")
    func clearAllRemovesEverything() async {
        let isolated = Self.makeIsolatedStorage()
        _ = await isolated.record(makeEntry(query: "SELECT clear_test"))
        #expect(await isolated.clear(matching: QueryHistoryFilter(scope: .all)))
        #expect(await fetchAll(isolated).isEmpty)
    }

    @Test("clear with a since date keeps older entries")
    func clearSinceKeepsOlderEntries() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        let now = Date()
        _ = await isolated.record(
            makeEntry(query: "SELECT old", connectionId: connId, executedAt: now.addingTimeInterval(-86_400))
        )
        _ = await isolated.record(makeEntry(query: "SELECT recent", connectionId: connId, executedAt: now))

        #expect(
            await isolated.clear(
                matching: QueryHistoryFilter(scope: .connection(connId), since: now.addingTimeInterval(-3_600))
            )
        )

        let remaining = await fetchAll(isolated, connectionId: connId)
        #expect(remaining.count == 1)
        #expect(remaining.first?.query == "SELECT old")
    }

    @Test("clear only removes the outcome it was filtered to")
    func clearRespectsOutcome() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        _ = await isolated.record(makeEntry(query: "SELECT good", connectionId: connId, wasSuccessful: true))
        _ = await isolated.record(makeEntry(query: "SELECT bad", connectionId: connId, wasSuccessful: false))

        #expect(
            await isolated.clear(matching: QueryHistoryFilter(scope: .connection(connId), outcome: .failed))
        )

        let remaining = await fetchAll(isolated, connectionId: connId)
        #expect(remaining.count == 1)
        #expect(remaining.first?.query == "SELECT good")
    }

    @Test("clear only removes the sources it was filtered to")
    func clearRespectsSources() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        _ = await isolated.record(makeEntry(query: "SELECT typed", connectionId: connId, source: .editor))
        _ = await isolated.record(makeEntry(query: "SELECT browsed", connectionId: connId, source: .tableBrowse))

        #expect(
            await isolated.clear(
                matching: QueryHistoryFilter(scope: .connection(connId), sources: QueryHistorySource.userAuthored)
            )
        )

        let remaining = await fetchAll(isolated, connectionId: connId)
        #expect(remaining.count == 1)
        #expect(remaining.first?.query == "SELECT browsed")
    }

    @Test("clear only removes what the search matched")
    func clearRespectsSearchText() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        _ = await isolated.record(makeEntry(query: "SELECT alpha_rows FROM t", connectionId: connId))
        _ = await isolated.record(makeEntry(query: "SELECT beta_rows FROM t", connectionId: connId))

        #expect(
            await isolated.clear(
                matching: QueryHistoryFilter(scope: .connection(connId), searchText: "alpha_rows")
            )
        )

        let remaining = await fetchAll(isolated, connectionId: connId)
        #expect(remaining.count == 1)
        #expect(remaining.first?.query == "SELECT beta_rows FROM t")
    }

    @Test("clear with a filter that matches nothing deletes nothing")
    func clearWithImpossibleFilterDeletesNothing() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        _ = await isolated.record(makeEntry(connectionId: connId))

        #expect(await isolated.clear(matching: QueryHistoryFilter(scope: .connection(connId), sources: [])))
        #expect(await isolated.count(scope: .connection(connId)) == 1)
    }

    @Test("count is scoped")
    func countIsScoped() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        for index in 0 ..< 3 {
            _ = await isolated.record(makeEntry(query: "SELECT count_\(index)", connectionId: connId))
        }
        _ = await isolated.record(makeEntry(query: "SELECT other", connectionId: UUID()))

        #expect(await isolated.count(scope: .connection(connId)) == 3)
        #expect(await isolated.count(scope: .all) == 4)
    }

    // MARK: - Retention

    @Test("auto cleanup off leaves entries past the cap in place")
    func autoCleanupOffKeepsEntries() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        await isolated.updateSettingsCache(maxEntries: 10, maxDays: 0, autoCleanup: false)

        for index in 0 ..< 120 {
            _ = await isolated.record(makeEntry(query: "SELECT keep_\(index)", connectionId: connId))
        }

        #expect(await isolated.count(scope: .all) == 120)
    }

    @Test("cleanup trims to the entry cap, newest kept")
    func cleanupTrimsToEntryCap() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        let base = Date()
        await isolated.updateSettingsCache(maxEntries: 5, maxDays: 0, autoCleanup: true)

        for index in 0 ..< 12 {
            _ = await isolated.record(
                makeEntry(
                    query: "SELECT trim_\(index)",
                    connectionId: connId,
                    executedAt: base.addingTimeInterval(Double(index))
                )
            )
        }
        await isolated.cleanup()

        let remaining = await fetchAll(isolated, connectionId: connId)
        #expect(remaining.count == 5)
        #expect(remaining.first?.query == "SELECT trim_11")
    }

    @Test("cleanup reports whether it removed anything")
    func cleanupReportsWhetherItRemovedAnything() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        await isolated.updateSettingsCache(maxEntries: 2, maxDays: 0, autoCleanup: true)

        for index in 0 ..< 5 {
            _ = await isolated.record(makeEntry(query: "SELECT trim_\(index)", connectionId: connId))
        }

        #expect(await isolated.cleanup(), "pruning rows must report that the list changed")
        #expect(await isolated.cleanup() == false, "a second pass removes nothing and must say so")
    }

    @Test("cleanup drops entries older than the day cap")
    func cleanupDropsOldEntries() async {
        let isolated = Self.makeIsolatedStorage()
        let connId = UUID()
        await isolated.updateSettingsCache(maxEntries: 0, maxDays: 1, autoCleanup: true)

        _ = await isolated.record(
            makeEntry(query: "SELECT ancient", connectionId: connId, executedAt: Date().addingTimeInterval(-172_800))
        )
        _ = await isolated.record(makeEntry(query: "SELECT fresh", connectionId: connId))
        await isolated.cleanup()

        let remaining = await fetchAll(isolated, connectionId: connId)
        #expect(remaining.count == 1)
        #expect(remaining.first?.query == "SELECT fresh")
    }

    // MARK: - Concurrency

    @Test("concurrent records do not corrupt data")
    func concurrentRecordsDoNotCorrupt() async {
        let connId = UUID()
        await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    await self.storage.record(
                        self.makeEntry(query: "SELECT concurrent_\(index)", connectionId: connId)
                    )
                }
            }
            for await success in group {
                #expect(success)
            }
        }

        let entries = await fetchAll(storage, connectionId: connId, limit: 1_000)
        #expect(entries.count == 20)
    }
}
