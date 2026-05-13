//
//  MultiConnectionNavigationTests.swift
//  TableProTests
//
//  Tests for multi-connection navigation — openTableTab paths not covered
//  by OpenTableTabTests, SidebarNavigationResult in multi-database-type
//  context, and coordinator connection scoping isolation.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Multi-Connection Navigation")
struct MultiConnectionNavigationTests {

    // MARK: - Helpers

    @MainActor
    private func makeCoordinator(
        id: UUID = UUID(),
        name: String = "Test",
        database: String = "testdb",
        type: DatabaseType = .mysql
    ) -> (coordinator: MainContentCoordinator, tabManager: QueryTabManager) {
        let connection = TestFixtures.makeConnection(id: id, name: name, database: database, type: type)
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
        return (coordinator, tabManager)
    }

    // MARK: - openTableTab: Fast path sets showStructure

    @Test("Fast path sets showStructure on the existing active tab")
    @MainActor
    func fastPathSetsShowStructure() throws {
        let (coordinator, tabManager) = makeCoordinator(database: "db_a")
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
        guard let idx = tabManager.selectedTabIndex else {
            Issue.record("Expected selected tab index")
            return
        }
        #expect(tabManager.tabs[idx].display.resultsViewMode != .structure)

        coordinator.openTableTab("users", showStructure: true)

        #expect(tabManager.tabs[idx].display.resultsViewMode == .structure)
    }

    // MARK: - openTableTab: isView marks tab correctly

    @Test("openTableTab with isView marks tab as view and non-editable")
    @MainActor
    func openTableTabWithIsViewMarksTabCorrectly() {
        let (coordinator, tabManager) = makeCoordinator(database: "db_a")
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        coordinator.openTableTab("my_view", isView: true)

        guard let tab = tabManager.tabs.first else {
            Issue.record("Expected a tab to be added")
            return
        }
        #expect(tab.tableContext.isView == true)
        #expect(tab.tableContext.isEditable == false)
    }

    // MARK: - openTableTab: databaseName from connection

    @Test("openTableTab adds tab with databaseName sourced from connection")
    @MainActor
    func openTableTabUsesConnectionDatabase() {
        let (coordinator, tabManager) = makeCoordinator(database: "primary_db")
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        coordinator.openTableTab("users")

        guard let tab = tabManager.tabs.first else {
            Issue.record("Expected a tab to be added")
            return
        }
        #expect(tab.tableContext.databaseName == "primary_db")
    }

    // MARK: - openTableTab: different database types create correct tab

    @Test("openTableTab with postgresql connection adds tab")
    @MainActor
    func openTableTabPostgreSQLAddsTab() {
        let (coordinator, tabManager) = makeCoordinator(database: "pg_db", type: .postgresql)
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        coordinator.openTableTab("accounts")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.tableContext.tableName == "accounts")
        #expect(tabManager.tabs.first?.tableContext.databaseName == "pg_db")
    }

    @Test("openTableTab with sqlite connection adds tab")
    @MainActor
    func openTableTabSQLiteAddsTab() {
        let (coordinator, tabManager) = makeCoordinator(database: "local.db", type: .sqlite)
        defer { coordinator.teardown() }

        #expect(tabManager.tabs.isEmpty)

        coordinator.openTableTab("items")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.tableContext.tableName == "items")
        #expect(tabManager.tabs.first?.tableContext.databaseName == "local.db")
    }

    // MARK: - SidebarNavigationResult: skip for all database types

    @Test("resolve returns skip for mysql when same table is active")
    @MainActor
    func resolveSkipForMysql() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: manager.selectedTab?.tableContext.tableName,
            hasExistingTabs: !manager.tabs.isEmpty
        )
        #expect(result == .skip)
    }

    @Test("resolve returns skip for postgresql when same table is active")
    @MainActor
    func resolveSkipForPostgresql() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "accounts", databaseType: .postgresql, databaseName: "pgdb")
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "accounts",
            currentTabTableName: manager.selectedTab?.tableContext.tableName,
            hasExistingTabs: !manager.tabs.isEmpty
        )
        #expect(result == .skip)
    }

    @Test("resolve returns skip for sqlite when same table is active")
    @MainActor
    func resolveSkipForSqlite() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "items", databaseType: .sqlite, databaseName: "local.db")
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "items",
            currentTabTableName: manager.selectedTab?.tableContext.tableName,
            hasExistingTabs: !manager.tabs.isEmpty
        )
        #expect(result == .skip)
    }

    // MARK: - SidebarNavigationResult: openInPlace for all database types with no tabs

    @Test("resolve returns openInPlace for mysql with no existing tabs")
    func resolveOpenInPlaceForMysqlNoTabs() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: nil,
            hasExistingTabs: false
        )
        #expect(result == .openInPlace)
    }

    @Test("resolve returns openInPlace for postgresql with no existing tabs")
    func resolveOpenInPlaceForPostgresqlNoTabs() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "accounts",
            currentTabTableName: nil,
            hasExistingTabs: false
        )
        #expect(result == .openInPlace)
    }

    @Test("resolve returns openInPlace for sqlite with no existing tabs")
    func resolveOpenInPlaceForSqliteNoTabs() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "items",
            currentTabTableName: nil,
            hasExistingTabs: false
        )
        #expect(result == .openInPlace)
    }

    // MARK: - Coordinator connection scoping

    @Test("Two coordinators with different connections have independent tab managers")
    @MainActor
    func twoCoordinatorsHaveIndependentTabManagers() throws {
        let (coordinatorA, tabManagerA) = makeCoordinator(name: "ConnA", database: "db_a")
        let (coordinatorB, tabManagerB) = makeCoordinator(name: "ConnB", database: "db_b")
        defer {
            coordinatorA.teardown()
            coordinatorB.teardown()
        }

        try tabManagerA.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
        try tabManagerB.addTableTab(tableName: "orders", databaseType: .mysql, databaseName: "db_b")
        try tabManagerB.addTableTab(tableName: "products", databaseType: .mysql, databaseName: "db_b")

        #expect(tabManagerA.tabs.count == 1)
        #expect(tabManagerB.tabs.count == 2)
        #expect(tabManagerA.tabs.first?.tableContext.tableName == "users")
        #expect(tabManagerB.tabs.first?.tableContext.tableName == "orders")
    }

    @Test("openTableTab on coordinator A does not affect coordinator B's tabs")
    @MainActor
    func openTableTabOnADoesNotAffectB() throws {
        let (coordinatorA, tabManagerA) = makeCoordinator(name: "ConnA", database: "db_a")
        let (coordinatorB, tabManagerB) = makeCoordinator(name: "ConnB", database: "db_b")
        defer {
            coordinatorA.teardown()
            coordinatorB.teardown()
        }

        try tabManagerB.addTableTab(tableName: "orders", databaseType: .mysql, databaseName: "db_b")
        let tabCountBefore = tabManagerB.tabs.count

        coordinatorA.openTableTab("users")

        #expect(tabManagerA.tabs.count == 1)
        #expect(tabManagerB.tabs.count == tabCountBefore)
        #expect(tabManagerB.tabs.first?.tableContext.tableName == "orders")
    }
}
