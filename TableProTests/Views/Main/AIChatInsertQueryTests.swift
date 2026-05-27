import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("AIChatInsertQuery")
struct AIChatInsertQueryTests {
    @Test("Reuses the selected query tab only when it is empty")
    @MainActor
    func reusesSelectedQueryTabWhenEmpty() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(databaseName: "db")

        #expect(coordinator.aiInsertReusesSelectedQueryTab == true)
    }

    @Test("Does not reuse a query tab that already has content")
    @MainActor
    func doesNotReuseQueryTabWithContent() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db")

        #expect(coordinator.aiInsertReusesSelectedQueryTab == false)
    }

    @Test("Does not reuse a table tab")
    @MainActor
    func doesNotReuseTableTab() throws {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        try coordinator.tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db")

        #expect(coordinator.aiInsertReusesSelectedQueryTab == false)
    }

    @Test("Insert fills an empty query tab in place")
    @MainActor
    func insertFillsEmptyQueryTabInPlace() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(databaseName: "db")

        coordinator.insertQueryFromAI("SELECT * FROM users")

        #expect(coordinator.tabManager.tabs.count == 1)
        #expect(coordinator.tabManager.selectedTab?.content.query == "SELECT * FROM users")
    }

    @Test("Insert with no open tabs creates a query tab with the SQL")
    @MainActor
    func insertWithNoTabsCreatesQueryTab() {
        let coordinator = Self.makeCoordinator()
        defer { coordinator.teardown() }

        #expect(coordinator.tabManager.tabs.isEmpty)

        coordinator.insertQueryFromAI("SELECT * FROM orders")

        #expect(coordinator.tabManager.tabs.count == 1)
        #expect(coordinator.tabManager.selectedTab?.tabType == .query)
        #expect(coordinator.tabManager.selectedTab?.content.query == "SELECT * FROM orders")
    }

    @MainActor
    private static func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "db"),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }
}
