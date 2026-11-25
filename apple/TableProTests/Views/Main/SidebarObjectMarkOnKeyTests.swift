//
//  SidebarObjectMarkOnKeyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Becoming key re-marked the open tab's table every time, so switching apps and back replaced a batch the user had
// picked in the sidebar. Key now re-marks only when the open tab shows something other than the last mark.
@MainActor
struct SidebarObjectMarkOnKeyTests {
    private let tableNames = ["users", "orders", "items"]

    private func makeFixture() async -> CoordinatorFixture {
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        let driver = SideObjectsMockDriver(connection: connection)
        driver.tablesToReturn = tableNames.map { TableInfo(name: $0, type: .table, rowCount: nil) }
        let fixture = CoordinatorFixture(connection: connection, driver: driver)
        await SchemaService.shared.load(connectionId: connection.id, driver: driver, connection: connection)
        return fixture
    }

    private func openTable(_ name: String, in fixture: CoordinatorFixture) {
        fixture.addTab(QueryTab(title: name, query: "SELECT * FROM \(name)", tabType: .table, tableName: name))
    }

    private func markedNames(_ coordinator: MainContentCoordinator) -> Set<String> {
        Set(coordinator.windowSidebarState.selectedTables.map { $0.table.name })
    }

    private func refs(_ names: [String], in coordinator: MainContentCoordinator) -> Set<DatabaseTreeTableRef> {
        let tables = coordinator.services.databaseManager.session(for: coordinator.connectionId)?.tables ?? []
        return Set(tables.filter { names.contains($0.name) }.map {
            DatabaseTreeTableRef(database: "shop", schema: nil, table: $0)
        })
    }

    @Test("The window's first key marks the open tab's table")
    func firstKeyMarksTheOpenTable() async {
        let fixture = await makeFixture()
        openTable("users", in: fixture)

        fixture.coordinator.handleWindowDidBecomeKey()

        #expect(markedNames(fixture.coordinator) == ["users"])
    }

    @Test("A batch picked in the sidebar survives the window losing and regaining key")
    func pickSurvivesKeyChange() async {
        let fixture = await makeFixture()
        let coordinator = fixture.coordinator
        openTable("users", in: fixture)
        coordinator.handleWindowDidBecomeKey()
        let batch = refs(["orders", "items"], in: coordinator)
        coordinator.windowSidebarState.select(tables: batch, rowCount: batch.count)

        coordinator.handleWindowDidResignKey()
        coordinator.handleWindowDidBecomeKey()

        #expect(markedNames(coordinator) == ["orders", "items"])
    }

    // A window opened from Welcome is key before its coordinator exists, so the first mark comes from the catalog.
    @Test("A batch picked before the window's first key change survives it")
    func pickSurvivesTheFirstKeyChange() async {
        let fixture = await makeFixture()
        let coordinator = fixture.coordinator
        openTable("users", in: fixture)
        coordinator.syncSidebarObjectSelection()
        let batch = refs(["orders", "items"], in: coordinator)
        coordinator.windowSidebarState.select(tables: batch, rowCount: batch.count)

        coordinator.handleWindowDidBecomeKey()

        #expect(markedNames(coordinator) == ["orders", "items"])
    }

    @Test("A tab change made while the window is in the background marks once it is key")
    func backgroundTabChangeMarksOnKey() async {
        let fixture = await makeFixture()
        let coordinator = fixture.coordinator
        openTable("users", in: fixture)
        coordinator.handleWindowDidBecomeKey()
        coordinator.handleWindowDidResignKey()

        openTable("orders", in: fixture)
        #expect(markedNames(coordinator) == ["users"])

        coordinator.handleWindowDidBecomeKey()
        #expect(markedNames(coordinator) == ["orders"])
    }

    @Test("Going back in the open tab moves the mark to the table it now shows")
    func retargetMovesTheMark() async throws {
        let fixture = await makeFixture()
        let coordinator = fixture.coordinator
        openTable("orders", in: fixture)
        coordinator.handleWindowDidBecomeKey()
        let tabId = try #require(fixture.tabManager.selectedTabId)

        #expect(fixture.tabManager.mutate(tabId: tabId) { $0.tableContext.tableName = "users" })
        coordinator.selectedTabDidRetarget()

        #expect(markedNames(coordinator) == ["users"])
    }

    // Open Quickly reuses the preview tab while its panel holds key.
    @Test("A retarget while another window holds key marks once this one is key again")
    func backgroundRetargetMarksOnKey() async throws {
        let fixture = await makeFixture()
        let coordinator = fixture.coordinator
        openTable("orders", in: fixture)
        coordinator.handleWindowDidBecomeKey()
        let tabId = try #require(fixture.tabManager.selectedTabId)
        coordinator.handleWindowDidResignKey()

        #expect(fixture.tabManager.mutate(tabId: tabId) { $0.tableContext.tableName = "users" })
        coordinator.selectedTabDidRetarget()
        #expect(markedNames(coordinator) == ["orders"])

        coordinator.handleWindowDidBecomeKey()
        #expect(markedNames(coordinator) == ["users"])
    }

    @Test("A query finishing on a table leaves a sidebar pick alone, then and at the next key change")
    func queryResultLeavesThePickAlone() async throws {
        let fixture = await makeFixture()
        let coordinator = fixture.coordinator
        let tab = fixture.addTab(QueryTab(title: "Query 1", query: "SELECT * FROM users", tabType: .query))
        coordinator.handleWindowDidBecomeKey()
        let batch = refs(["orders", "items"], in: coordinator)
        coordinator.windowSidebarState.select(tables: batch, rowCount: batch.count)

        #expect(fixture.tabManager.mutate(tabId: tab.id) { $0.tableContext.tableName = "users" })
        coordinator.selectedTabDidRetarget()
        #expect(markedNames(coordinator) == ["orders", "items"])

        coordinator.handleWindowDidResignKey()
        coordinator.handleWindowDidBecomeKey()
        #expect(markedNames(coordinator) == ["orders", "items"])
    }

    @Test("A temporary table and the table it hides are different things to mark")
    func temporaryTableIsAnotherSubject() {
        let permanent = QueryTab(title: "t", query: "SELECT * FROM t", tabType: .table, tableName: "t")
        var temporary = permanent
        temporary.tableContext.isTemporary = true

        #expect(SidebarMarkSubject(tab: permanent) != SidebarMarkSubject(tab: temporary))
    }
}
