//
//  DataRefreshScopeTests.swift
//  TableProTests
//
//  A data-changed broadcast reaches every window of a connection. #2026 symptom 2 was
//  the whole window following a save: the refresh carried no scope, so every window
//  refetched against whatever database the save had pinned. The request now names the
//  scope the change landed in, and each receiver matches it against the scope it owns:
//  the sidebar against the browse cursor, an open tab against the tab's own scope.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Data refresh scoping", .serialized)
@MainActor
struct DataRefreshScopeTests {
    /// The window browses `driverDatabase` and the tab sits on `tabDatabase`. The cursor is
    /// seeded explicitly because a window owns its own, and never reads the driver's position.
    private static func makeCoordinator(
        connection: DatabaseConnection,
        driverDatabase: String,
        tabDatabase: String? = nil
    ) -> (MainContentCoordinator, QueryTabManager) {
        var session = ConnectionSession(connection: connection)
        session.driverDatabase = driverDatabase
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState(),
            browseState: WindowBrowseState.seeded(database: driverDatabase, schema: nil)
        )

        if let tabDatabase {
            var tab = QueryTab(title: "orders", query: "SELECT 1", tabType: .table, tableName: "orders")
            tab.tableContext.databaseName = tabDatabase
            tabManager.tabs.append(tab)
            tabManager.selectedTabId = tab.id
        }

        return (coordinator, tabManager)
    }

    @Test("A scoped refresh is ignored by a window browsing another database")
    func scopedRefreshSkipsAWindowBrowsingElsewhere() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            driverDatabase: "inventory",
            tabDatabase: "inventory"
        )

        let elsewhere = DatabaseScope(connectionId: connection.id, database: "orders", schema: nil)
        let request = DataRefreshRequest(connectionId: connection.id, scope: elsewhere)

        #expect(request.scope != coordinator.selectedTabScope)
        #expect(request.scope?.database != coordinator.browseDatabaseName)
    }

    @Test("An unscoped refresh still reaches every window")
    func unscopedRefreshReachesEveryone() {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            driverDatabase: "inventory",
            tabDatabase: "orders"
        )

        let request = DataRefreshRequest(connectionId: connection.id)

        #expect(request.scope == nil)
        #expect(coordinator.selectedTabScope != nil)
        #expect(coordinator.browseScope != nil)
    }

    @Test("A refresh scoped to a tab's own scope reaches that tab even when the sidebar moved away")
    func scopedRefreshReachesItsOwnTab() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            driverDatabase: "inventory",
            tabDatabase: "orders"
        )

        let tabScope = try #require(coordinator.selectedTabScope)
        #expect(tabScope.database == "orders")

        let request = DataRefreshRequest(connectionId: connection.id, scope: tabScope)

        #expect(request.scope == tabScope)
        #expect(
            request.scope?.database != coordinator.browseDatabaseName,
            "Matching a structure tab on the browse database would drop its own post-save reload"
        )
    }

    @Test("The browse cursor and an open tab's scope are independent")
    func browseScopeAndTabScopeAreIndependent() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            driverDatabase: "inventory",
            tabDatabase: "orders"
        )

        let browseScope = try #require(coordinator.browseScope)
        let tabScope = try #require(coordinator.selectedTabScope)

        #expect(browseScope.database == "inventory")
        #expect(tabScope.database == "orders")
        #expect(browseScope != tabScope)
    }

    @Test("A refresh for another connection never matches this window")
    func refreshForAnotherConnectionIsIgnored() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            driverDatabase: "orders",
            tabDatabase: "orders"
        )

        let otherConnectionId = UUID()
        let otherScope = DatabaseScope(connectionId: otherConnectionId, database: "orders", schema: nil)
        let request = DataRefreshRequest(connectionId: otherConnectionId, scope: otherScope)

        #expect(request.connectionId != coordinator.connectionId)
        #expect(request.scope != coordinator.selectedTabScope)
    }
}
