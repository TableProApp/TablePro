import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("RecentlyClosedTabStore")
struct RecentlyClosedTabStoreTests {
    private func makeStore() throws -> (store: RecentlyClosedTabStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentlyClosedTabStoreTests.\(UUID().uuidString)", isDirectory: true)
        return (RecentlyClosedTabStore(directory: directory), directory)
    }

    @Test("A closed scratch tab can be reopened with its query intact")
    func closedScratchTabRoundTrips() throws {
        let (store, _) = try makeStore()
        let connection = TestFixtures.makeConnection()
        store.push(tab: QueryTab(query: "SELECT 1"), connection: connection)

        let entry = try #require(store.mostRecentEntry)
        let consumed = try #require(store.consume(id: entry.id))
        #expect(consumed.tab.query == "SELECT 1")
        #expect(consumed.connectionId == connection.id)
        #expect(store.entries.isEmpty)
    }

    @Test("Closing several tabs keeps every one of them, most recent first")
    func multipleClosedTabsAllSurvive() throws {
        let (store, _) = try makeStore()
        let connection = TestFixtures.makeConnection()
        store.push(tab: QueryTab(query: "SELECT 1"), connection: connection)
        store.push(tab: QueryTab(query: "SELECT 2"), connection: connection)
        store.push(tab: QueryTab(query: "SELECT 3"), connection: connection)

        #expect(store.entries.count == 3)
        #expect(store.entries.map(\.tab.query) == ["SELECT 3", "SELECT 2", "SELECT 1"])
    }

    @Test("A consumed entry is not handed out twice")
    func consumeIsOneShot() throws {
        let (store, _) = try makeStore()
        store.push(tab: QueryTab(query: "SELECT 1"), connection: TestFixtures.makeConnection())

        let entry = try #require(store.mostRecentEntry)
        #expect(store.consume(id: entry.id) != nil)
        #expect(store.consume(id: entry.id) == nil)
    }

    @Test("A blank scratch tab is never stored")
    func blankTabIsNotStored() throws {
        let (store, _) = try makeStore()
        store.push(tab: QueryTab(query: "   \n "), connection: TestFixtures.makeConnection())
        #expect(store.entries.isEmpty)
    }

    @Test("A table tab is stored with its browse context")
    func tableTabIsStored() throws {
        let (store, _) = try makeStore()
        store.push(
            tab: QueryTab(query: "SELECT * FROM users", tabType: .table, tableName: "users"),
            connection: TestFixtures.makeConnection()
        )
        let entry = try #require(store.mostRecentEntry)
        #expect(entry.tab.tableName == "users")
        #expect(entry.tab.tabType == .table)
    }

    @Test("History is capped at the entry limit, dropping the oldest")
    func historyIsCapped() throws {
        let (store, _) = try makeStore()
        let connection = TestFixtures.makeConnection()
        for index in 0..<(RecentlyClosedTabStore.maxEntries + 5) {
            store.push(tab: QueryTab(query: "SELECT \(index)"), connection: connection)
        }

        #expect(store.entries.count == RecentlyClosedTabStore.maxEntries)
        #expect(store.entries.first?.tab.query == "SELECT \(RecentlyClosedTabStore.maxEntries + 4)")
        #expect(store.entries.last?.tab.query == "SELECT 5")
    }

    @Test("An oversized query survives in full instead of being truncated")
    func oversizedQuerySurvivesInFull() throws {
        let (store, _) = try makeStore()
        let oversized = String(repeating: "a", count: TabQueryContent.maxPersistableQuerySize + 100)
        store.push(tab: QueryTab(query: oversized), connection: TestFixtures.makeConnection())

        let entry = try #require(store.mostRecentEntry)
        #expect(entry.overflowFileName != nil)
        #expect(entry.tab.query.isEmpty)

        let consumed = try #require(store.consume(id: entry.id))
        #expect((consumed.tab.query as NSString).length == (oversized as NSString).length)
        #expect(consumed.tab.query == oversized)
    }

    @Test("Entries survive a restart of the store")
    func entriesPersistAcrossStoreInstances() throws {
        let (store, directory) = try makeStore()
        store.push(tab: QueryTab(query: "SELECT persisted"), connection: TestFixtures.makeConnection())

        let reloaded = RecentlyClosedTabStore(directory: directory)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.first?.tab.query == "SELECT persisted")
    }

    @Test("An oversized query survives a restart of the store")
    func oversizedQueryPersistsAcrossStoreInstances() throws {
        let (store, directory) = try makeStore()
        let oversized = String(repeating: "b", count: TabQueryContent.maxPersistableQuerySize + 100)
        store.push(tab: QueryTab(query: oversized), connection: TestFixtures.makeConnection())

        let reloaded = RecentlyClosedTabStore(directory: directory)
        let entry = try #require(reloaded.mostRecentEntry)
        let consumed = try #require(reloaded.consume(id: entry.id))
        #expect(consumed.tab.query == oversized)
    }

    @Test("Deleting a connection drops its entries")
    func removingAConnectionDropsItsEntries() throws {
        let (store, _) = try makeStore()
        let kept = TestFixtures.makeConnection(name: "Kept")
        let deleted = TestFixtures.makeConnection(name: "Deleted")
        store.push(tab: QueryTab(query: "SELECT kept"), connection: kept)
        store.push(tab: QueryTab(query: "SELECT deleted"), connection: deleted)

        store.removeEntries(for: deleted.id)

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.connectionId == kept.id)
    }

    @Test("Reclosing the same tab bumps it instead of duplicating it")
    func reclosingSameTabBumpsIt() throws {
        let (store, _) = try makeStore()
        let connection = TestFixtures.makeConnection()
        let tabId = UUID()
        store.push(tab: QueryTab(id: tabId, query: "SELECT first"), connection: connection)
        store.push(tab: QueryTab(query: "SELECT other"), connection: connection)
        store.push(tab: QueryTab(id: tabId, query: "SELECT second"), connection: connection)

        #expect(store.entries.count == 2)
        #expect(store.entries.first?.tab.query == "SELECT second")
    }
}
