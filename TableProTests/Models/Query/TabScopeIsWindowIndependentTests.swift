// A macOS window tab is a full NSWindow the user can drag out at any time, so
// "Move Tab to New Window" has to be semantically a no-op. That holds only while a
// tab's target is a pure function of the tab and its connection. When it was not,
// the tab read the window's sidebar selection instead.

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct TabScopeIsWindowIndependentTests {
    private static func makeWindow(connection: DatabaseConnection, tab: QueryTab) -> CoordinatorFixture {
        let window = CoordinatorFixture(connection: connection)
        window.addTab(tab)
        return window
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
        browsingOrders.browseDatabase = "orders"
        DatabaseManager.shared.injectSession(browsingOrders, for: connection.id)
        let windowOnOrders = Self.makeWindow(connection: connection, tab: tab)
        let scopeFromOrders = try #require(windowOnOrders.coordinator.scope(for: tab))

        var browsingInventory = ConnectionSession(connection: connection)
        browsingInventory.browseDatabase = "inventory"
        DatabaseManager.shared.injectSession(browsingInventory, for: connection.id)
        let windowOnInventory = Self.makeWindow(connection: connection, tab: tab)
        let scopeFromInventory = try #require(windowOnInventory.coordinator.scope(for: tab))

        #expect(scopeFromOrders == scopeFromInventory)
        #expect(scopeFromOrders.database == "orders")
    }

    @Test("A bound tab keeps its schema when the browse schema moves")
    func schemaDoesNotFollowTheBrowseCursor() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tab = Self.makeTab(database: "orders", schema: "sales")

        var session = ConnectionSession(connection: connection)
        session.browseDatabase = "inventory"
        session.browseSchema = "dbo"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let window = Self.makeWindow(connection: connection, tab: tab)
        let scope = try #require(window.coordinator.scope(for: tab))

        #expect(scope.database == "orders")
        #expect(scope.schema == "sales")
    }

    @Test("An unbound tab is seeded from the browse cursor, then stays put")
    func anUnboundTabIsSeededOnceFromTheCursor() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tab = Self.makeTab(database: "", schema: nil)

        var session = ConnectionSession(connection: connection)
        session.browseDatabase = "inventory"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let window = Self.makeWindow(connection: connection, tab: tab)
        let seeded = try #require(window.coordinator.scope(for: tab))

        #expect(seeded.database == "inventory")
    }
}
