// Redis lists its databases as db0...dbN and a click retargets the selected tab in place. That
// retarget used to take over a tab holding typed commands or staged edits, with no prompt and no undo.

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct InPlaceNavigationKeepsWorkTests {
    private func makeRedisCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "0", type: .redis),
            tabManager: QueryTabManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    @Test("A database click opens its own tab instead of replacing typed, unrun commands")
    func keepsTypedCommands() throws {
        let coordinator = makeRedisCoordinator()
        defer { coordinator.teardown() }
        let tabManager = coordinator.tabManager
        tabManager.addTab(initialQuery: "GET session:42")
        let queryTab = try #require(tabManager.selectedTabId)

        coordinator.openTableTab("db3")

        #expect(tabManager.tabs.count == 2)
        let kept = try #require(tabManager.tabs.first { $0.id == queryTab })
        #expect(kept.tabType == .query)
        #expect(kept.content.query == "GET session:42")
        #expect(tabManager.selectedTab?.tableContext.tableName == "db3")
    }

    @Test("A database click keeps a database tab that holds staged edits")
    func keepsStagedEdits() throws {
        let coordinator = makeRedisCoordinator()
        defer { coordinator.teardown() }
        let tabManager = coordinator.tabManager
        coordinator.openTableTab("db0")
        let edited = try #require(tabManager.selectedTabId)
        coordinator.changeManager(forTab: edited).recordRowDeletion(rowID: .existing(0), originalRow: ["1"])

        coordinator.openTableTab("db3")

        #expect(tabManager.tabs.count == 2)
        #expect(tabManager.tabs.first { $0.id == edited }?.tableContext.tableName == "db0")
        #expect(coordinator.hasStagedRowEdits(inTab: edited))
        #expect(tabManager.selectedTab?.tableContext.tableName == "db3")
    }

    @Test("A database click keeps a database tab the user sorted")
    func keepsASortedTab() throws {
        let coordinator = makeRedisCoordinator()
        defer { coordinator.teardown() }
        let tabManager = coordinator.tabManager
        coordinator.openTableTab("db0")
        let sorted = try #require(tabManager.selectedTabId)
        tabManager.mutate(tabId: sorted) { tab in
            tab.sortState = SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user)
        }

        coordinator.openTableTab("db3")

        #expect(tabManager.tabs.count == 2)
        #expect(tabManager.tabs.first { $0.id == sorted }?.tableContext.tableName == "db0")
        #expect(tabManager.selectedTab?.tableContext.tableName == "db3")
    }

    @Test("A database click still retargets a database tab that holds nothing")
    func retargetsAnUntouchedDatabaseTab() throws {
        let coordinator = makeRedisCoordinator()
        defer { coordinator.teardown() }
        let tabManager = coordinator.tabManager
        coordinator.openTableTab("db0")
        let browsing = try #require(tabManager.selectedTabId)

        coordinator.openTableTab("db3")

        #expect(tabManager.tabs.map { $0.id } == [browsing])
        #expect(tabManager.selectedTab?.tableContext.tableName == "db3")
    }
}
