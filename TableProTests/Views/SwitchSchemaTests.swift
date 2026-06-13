//
//  SwitchSchemaTests.swift
//  TableProTests
//
//  Tests for the "switch schema" flow: switching the active schema changes
//  the connection's search_path but must not close or clear open tabs.
//  Regression coverage for #1669: switching schemas wiped every tab,
//  discarding unsaved SQL in query editor tabs.
//

import Foundation
import Testing

@testable import TablePro

@Suite("SwitchSchema")
@MainActor
struct SwitchSchemaTests {
    private func makeTab(title: String, query: String, tabType: TabType, tableName: String? = nil) -> QueryTab {
        QueryTab(title: title, query: query, tabType: tabType, tableName: tableName)
    }

    private func withSchemaSwitchingConnection(
        _ body: (DatabaseConnection, MockDatabaseDriver) -> Void
    ) {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let driver = MockDatabaseDriver(connection: connection)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: driver),
            for: connection.id
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        body(connection, driver)
    }

    @Test("switchSchema keeps query and table tabs and their contents")
    func switchSchemaPreservesTabs() async {
        await withSchemaSwitchingConnection { connection, driver in
            let tabManager = QueryTabManager()
            let coordinator = MainContentCoordinator(
                connection: connection,
                tabManager: tabManager,
                changeManager: DataChangeManager(),
                toolbarState: ConnectionToolbarState()
            )
            defer { coordinator.teardown() }

            let queryTab = makeTab(title: "Query 1", query: "SELECT 42", tabType: .query)
            let tableTab = makeTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
            tabManager.tabs = [queryTab, tableTab]
            tabManager.selectedTabId = queryTab.id
            let idsBefore = tabManager.tabs.map(\.id)

            await coordinator.switchSchema(to: "s2")

            #expect(tabManager.tabs.map(\.id) == idsBefore)
            #expect(tabManager.selectedTabId == queryTab.id)
            #expect(tabManager.tabs.contains { $0.content.query == "SELECT 42" })
            #expect(driver.currentSchema == "s2")
            #expect(coordinator.toolbarState.currentSchema == "s2")
        }
    }

    @Test("switchSchema leaves tabs untouched when the schema is unchanged")
    func switchSchemaToSameSchemaKeepsTabs() async {
        await withSchemaSwitchingConnection { connection, _ in
            let tabManager = QueryTabManager()
            let coordinator = MainContentCoordinator(
                connection: connection,
                tabManager: tabManager,
                changeManager: DataChangeManager(),
                toolbarState: ConnectionToolbarState()
            )
            defer { coordinator.teardown() }

            let queryTab = makeTab(title: "Query 1", query: "SELECT 1", tabType: .query)
            tabManager.tabs = [queryTab]
            tabManager.selectedTabId = queryTab.id

            await coordinator.switchSchema(to: "s1")
            await coordinator.switchSchema(to: "s1")

            #expect(tabManager.tabs.count == 1)
            #expect(tabManager.tabs.first?.content.query == "SELECT 1")
        }
    }
}
