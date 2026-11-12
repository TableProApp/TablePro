import Foundation
import Testing
@testable import TableProMobile

struct QueryHistoryStorageTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("ios-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var historyURL: URL {
        directory.appendingPathComponent("query-history.json")
    }

    @Test("A recorded run returns its connection's list, so the window needs no second read")
    func recordReturnsTheConnectionsList() throws {
        let storage = QueryHistoryStorage(directory: directory)
        let mine = UUID()
        storage.save(QueryHistoryItem(query: "SELECT 1", connectionId: mine))
        storage.save(QueryHistoryItem(query: "SELECT 2", connectionId: UUID()))

        let listed = try #require(storage.record(QueryHistoryItem(query: "SELECT 3", connectionId: mine)))

        #expect(listed.items.map(\.query) == ["SELECT 1", "SELECT 3"])
        #expect(listed.generation == storage.generation)
    }

    @Test("The same run twice in a row records nothing the second time")
    func duplicateRecordsNothing() {
        let storage = QueryHistoryStorage(directory: directory)
        let connectionId = UUID()
        #expect(storage.record(QueryHistoryItem(query: "SELECT 1", connectionId: connectionId)) != nil)

        #expect(storage.record(QueryHistoryItem(query: "SELECT 1", connectionId: connectionId)) == nil)
    }

    @Test("Text past the budget drops the oldest entries whole, and the newest entry always stays")
    func byteBudgetDropsTheOldestWhole() {
        let connectionId = UUID()
        let half = String(repeating: "x", count: QueryHistoryStorage.maxTextBytes / 2)
        let items = [
            QueryHistoryItem(query: "SELECT 1", connectionId: connectionId),
            QueryHistoryItem(query: half, connectionId: connectionId),
            QueryHistoryItem(query: half, connectionId: connectionId),
        ]

        let kept = QueryHistoryStorage.withinBudget(items)
        #expect(kept.map(\.query.utf8.count) == [half.utf8.count, half.utf8.count])

        let huge = String(repeating: "y", count: QueryHistoryStorage.maxTextBytes + 1)
        let alone = QueryHistoryStorage.withinBudget(items + [QueryHistoryItem(query: huge, connectionId: connectionId)])
        #expect(alone.map(\.query) == [huge])
    }

    @Test("At most 200 entries are kept")
    func entryCapStillHolds() {
        let connectionId = UUID()
        let items = (0..<250).map { QueryHistoryItem(query: "SELECT \($0)", connectionId: connectionId) }

        let kept = QueryHistoryStorage.withinBudget(items)

        #expect(kept.count == 200)
        #expect(kept.first?.query == "SELECT 50")
        #expect(kept.last?.query == "SELECT 249")
    }

    @Test("A write that fails leaves the listed history as the file holds it")
    func failedWriteKeepsTheList() throws {
        let storage = QueryHistoryStorage(directory: directory)
        #expect(storage.save(QueryHistoryItem(query: "SELECT 1", connectionId: UUID())))
        let generation = storage.generation
        try FileManager.default.removeItem(at: historyURL)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: false)

        #expect(!storage.save(QueryHistoryItem(query: "SELECT 2", connectionId: UUID())))

        #expect(storage.loadAll().map(\.query) == ["SELECT 1"])
        #expect(storage.generation == generation)
    }

    @Test("The file follows memory, so the next launch reads what this one recorded")
    func fileFollowsMemory() {
        let first = QueryHistoryStorage(directory: directory)
        let connectionId = UUID()
        first.save(QueryHistoryItem(query: "SELECT 1", connectionId: connectionId))
        first.save(QueryHistoryItem(query: "SELECT 2", connectionId: connectionId))
        first.delete(first.loadAll()[0].id)

        let relaunched = QueryHistoryStorage(directory: directory)

        #expect(relaunched.load(for: connectionId).map(\.query) == ["SELECT 2"])
    }
}
