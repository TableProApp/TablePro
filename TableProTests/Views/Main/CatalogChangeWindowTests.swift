//
//  CatalogChangeWindowTests.swift
//  TableProTests
//
//  What each window does with its connection's catalog changes: close the tabs on an object or a
//  container that went, and follow a rename, matching by the object rather than a bare name.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Catalog changes in a window", .serialized)
@MainActor
struct CatalogChangeWindowTests {
    private static func makeCoordinator(
        connection: DatabaseConnection
    ) -> (MainContentCoordinator, QueryTabManager) {
        var session = ConnectionSession(connection: connection)
        session.browseDatabase = "shop"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    private static func tableTab(_ name: String, database: String, schema: String?) -> QueryTab {
        var tab = QueryTab(title: name, query: "SELECT 1", tabType: .table, tableName: name)
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    private static func change(
        _ connection: DatabaseConnection,
        name: String,
        database: String,
        schema: String?,
        kind: DatabaseObjectChange.Kind
    ) -> DatabaseObjectChange {
        DatabaseObjectChange(
            connectionId: connection.id,
            scope: DatabaseScope(connectionId: connection.id, database: database, schema: schema),
            name: name,
            kind: kind
        )
    }

    @Test("a dropped table closes its tabs and no tab on a same-named table in another schema")
    func droppedTableClosesOnlyItsOwnTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let dropped = Self.tableTab("users", database: "shop", schema: "analytics")
        let survivor = Self.tableTab("users", database: "shop", schema: "public")
        let query = QueryTab(title: "Query", query: "DROP TABLE analytics.users", tabType: .query)
        tabManager.tabs = [dropped, survivor, query]
        tabManager.selectedTabId = dropped.id

        coordinator.applyObjectChange(
            Self.change(connection, name: "users", database: "shop", schema: "analytics", kind: .dropped),
            hasPendingTableOps: false,
            onDiscard: {}
        )

        #expect(tabManager.tabs.map(\.id) == [survivor.id, query.id])
        #expect(tabManager.selectedTabId == survivor.id)
    }

    @Test("a renamed table retitles its tabs and leaves others alone")
    func renamedTableRetitlesItsTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let renamed = Self.tableTab("orders", database: "shop", schema: nil)
        let other = Self.tableTab("orders", database: "warehouse", schema: nil)
        tabManager.tabs = [renamed, other]

        coordinator.applyObjectChange(
            Self.change(connection, name: "orders", database: "shop", schema: nil, kind: .renamed(to: "orders_2026")),
            hasPendingTableOps: false,
            onDiscard: {}
        )

        #expect(tabManager.tabs[0].tableContext.tableName == "orders_2026")
        #expect(tabManager.tabs[0].title == "orders_2026")
        #expect(tabManager.tabs[1].tableContext.tableName == "orders")
    }

    @Test("a dropped database closes the table tabs inside it")
    func droppedDatabaseClosesItsTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let inside = Self.tableTab("events", database: "staging", schema: nil)
        let outside = Self.tableTab("orders", database: "shop", schema: nil)
        tabManager.tabs = [inside, outside]

        coordinator.applyContainerChange(
            DatabaseContainerChange(connectionId: connection.id, container: .database("staging"), kind: .dropped)
        )

        #expect(tabManager.tabs.map(\.id) == [outside.id])
    }

    @Test("a renamed schema moves its tabs onto the new name")
    func renamedSchemaRetargetsItsTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let moved = Self.tableTab("invoices", database: "shop", schema: "billing")
        let untouched = Self.tableTab("orders", database: "shop", schema: "public")
        tabManager.tabs = [moved, untouched]

        coordinator.applyContainerChange(
            DatabaseContainerChange(
                connectionId: connection.id,
                container: .schema(database: "shop", schema: "billing"),
                kind: .renamed(to: "finance")
            )
        )

        #expect(tabManager.tabs[0].tableContext.schemaName == "finance")
        #expect(tabManager.tabs[1].tableContext.schemaName == "public")
    }

    @Test("a change for another connection is ignored")
    func otherConnectionIsIgnored() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let tab = Self.tableTab("orders", database: "shop", schema: nil)
        tabManager.tabs = [tab]

        coordinator.applyContainerChange(
            DatabaseContainerChange(connectionId: UUID(), container: .database("shop"), kind: .dropped)
        )

        #expect(tabManager.tabs.map(\.id) == [tab.id])
    }
}
