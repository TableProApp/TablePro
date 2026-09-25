import Foundation
@testable import TablePro
import Testing

@MainActor
struct RecentlyClosedTabReopenerTests {
    private func makeStore() -> RecentlyClosedTabStore {
        RecentlyClosedTabStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("RecentlyClosedTabReopenerTests.\(UUID().uuidString)", isDirectory: true)
        )
    }

    @Test("The entry stays in the history while the tab has not been adopted")
    func entryRemainsUntilAdopted() throws {
        let store = makeStore()
        let connection = TestFixtures.makeConnection()
        store.push(tab: QueryTab(query: "SELECT 1"), connection: connection)
        let entry = try #require(store.mostRecentEntry)
        var handedTab: QueryTab?
        var handedConnectionId: UUID?

        RecentlyClosedTabReopener.reopen(entry, from: store) { tab, connectionId, _, _ in
            handedTab = tab
            handedConnectionId = connectionId
        }

        #expect(handedTab?.content.query == "SELECT 1")
        #expect(handedConnectionId == connection.id)
        #expect(store.containsEntry(id: entry.id))
    }

    @Test("The entry leaves the history once the tab is adopted")
    func entryIsDiscardedOnAdoption() throws {
        let store = makeStore()
        store.push(tab: QueryTab(query: "SELECT 1"), connection: TestFixtures.makeConnection())
        let entry = try #require(store.mostRecentEntry)
        var wasClosedWhenAdopted = false

        RecentlyClosedTabReopener.reopen(entry, from: store) { _, _, isStillClosed, onAdopted in
            wasClosedWhenAdopted = isStillClosed()
            onAdopted()
        }

        #expect(wasClosedWhenAdopted)
        #expect(!store.containsEntry(id: entry.id))
        #expect(store.entries.isEmpty)
    }

    @Test("A tab whose entry went while it waited reports itself no longer closed")
    func isStillClosedFollowsTheHistory() throws {
        let store = makeStore()
        store.push(tab: QueryTab(query: "SELECT 1"), connection: TestFixtures.makeConnection())
        let entry = try #require(store.mostRecentEntry)
        var pendingCheck: (() -> Bool)?

        RecentlyClosedTabReopener.reopen(entry, from: store) { _, _, isStillClosed, _ in
            pendingCheck = isStillClosed
        }
        let isStillClosed = try #require(pendingCheck)

        #expect(isStillClosed())
        store.discard(id: entry.id)
        #expect(!isStillClosed())
    }
}
