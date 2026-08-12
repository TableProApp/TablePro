//
//  TabScopeIsWindowIndependentTests.swift
//  TableProTests
//
//  A macOS window tab is a full NSWindow the user can drag out at any time, so
//  "Move Tab to New Window" has to be semantically a no-op. That holds only while a
//  tab's target is a pure function of the tab and its connection. #2026 was what
//  happened when it was not: the tab read the window's sidebar selection instead.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("A tab's scope is independent of the window showing it", .serialized)
@MainActor
struct TabScopeIsWindowIndependentTests {
    private static func makeCoordinator(
        connection: DatabaseConnection,
        tab: QueryTab
    ) -> MainContentCoordinator {
        let tabManager = QueryTabManager()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    private static func makeTab(database: String, schema: String?) -> QueryTab {
        var tab = QueryTab(title: "orders", query: "SELECT 1", tabType: .table, tableName: "orders")
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    @Test("The same tab resolves the same scope under two windows browsing different databases")
    func scopeDoesNotFollowTheWindow() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tab = Self.makeTab(database: "orders", schema: nil)

        var browsingOrders = ConnectionSession(connection: connection)
        browsingOrders.driverDatabase = "orders"
        DatabaseManager.shared.injectSession(browsingOrders, for: connection.id)
        let windowOnOrders = Self.makeCoordinator(connection: connection, tab: tab)
        let scopeFromOrders = try #require(windowOnOrders.scope(for: tab))

        var browsingInventory = ConnectionSession(connection: connection)
        browsingInventory.driverDatabase = "inventory"
        DatabaseManager.shared.injectSession(browsingInventory, for: connection.id)
        let windowOnInventory = Self.makeCoordinator(connection: connection, tab: tab)
        let scopeFromInventory = try #require(windowOnInventory.scope(for: tab))

        #expect(scopeFromOrders == scopeFromInventory)
        #expect(scopeFromOrders.database == "orders")
    }

    @Test("A bound tab keeps its schema when the browse schema moves")
    func schemaDoesNotFollowTheBrowseCursor() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tab = Self.makeTab(database: "orders", schema: "sales")

        var session = ConnectionSession(connection: connection)
        session.driverDatabase = "inventory"
        session.driverSchema = "dbo"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let coordinator = Self.makeCoordinator(connection: connection, tab: tab)
        let scope = try #require(coordinator.scope(for: tab))

        #expect(scope.database == "orders")
        #expect(scope.schema == "sales")
    }

    @Test("An unbound tab is seeded from the browse cursor, then stays put")
    func anUnboundTabIsSeededOnceFromTheCursor() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tab = Self.makeTab(database: "", schema: nil)

        var session = ConnectionSession(connection: connection)
        session.driverDatabase = "inventory"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let coordinator = Self.makeCoordinator(connection: connection, tab: tab)
        let seeded = try #require(coordinator.scope(for: tab))

        #expect(seeded.database == "inventory")
    }
}
