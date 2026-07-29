//
//  SwitchDatabaseTests.swift
//  TableProTests
//
//  Tests for the "switch database" flow: switching databases (Cmd+K) does not
//  create new macOS windows and does not close open tabs. Tabs carry their own
//  database and coexist across databases (#1776); an earlier build wiped them
//  and discarded unsaved SQL (#1669).
//

import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("SwitchDatabase")
@MainActor
struct SwitchDatabaseTests {
    private func withConnectedCoordinator(
        _ body: (MainContentCoordinator, QueryTabManager) async throws -> Void
    ) async throws {
        let connection = TestFixtures.makeConnection(database: "db_a", type: .mysql)
        let driver = MockDatabaseDriver(connection: connection)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: driver),
            for: connection.id
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try await body(coordinator, tabManager)
    }

    @Test("openTableTab skips when table is already active tab in same database")
    func openTableTabSkipsForSameTableSameDatabase() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
        let tabCountBefore = tabManager.tabs.count

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == tabCountBefore)
    }

    // MARK: - Tab state after database switch

    @Test("switchDatabase keeps table and query tabs and their contents")
    func switchDatabaseKeepsExistingTabs() async throws {
        try await withConnectedCoordinator { coordinator, tabManager in
            try tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
            tabManager.addTab(initialQuery: "SELECT NOW()", databaseName: "db_a")
            let idsBefore = tabManager.tabs.map(\.id)
            let selectedBefore = tabManager.selectedTabId

            let switched = await coordinator.switchDatabase(to: "db_b", persist: false)

            #expect(switched)
            #expect(tabManager.tabs.map(\.id) == idsBefore)
            #expect(tabManager.selectedTabId == selectedBefore)
            #expect(tabManager.tabs.contains { $0.content.query == "SELECT NOW()" })
            #expect(coordinator.toolbarState.currentDatabase == "db_b")
        }
    }

    @Test("switchDatabase leaves each tab bound to the database it was opened against")
    func switchDatabaseKeepsPerTabDatabase() async throws {
        try await withConnectedCoordinator { coordinator, tabManager in
            try tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")

            _ = await coordinator.switchDatabase(to: "db_b", persist: false)

            #expect(tabManager.tabs.allSatisfy { $0.tableContext.databaseName == "db_a" })
        }
    }
}
