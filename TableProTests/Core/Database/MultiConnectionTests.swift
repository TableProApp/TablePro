//
//  MultiConnectionTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

// MARK: - DatabaseManager Multi-Session Isolation

@Suite("DatabaseManager Multi-Session Isolation")
@MainActor
struct DatabaseManagerMultiSessionTests {
    @Test("Multiple sessions coexist independently")
    func multipleSessionsCoexist() {
        let id1 = UUID()
        let id2 = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id1, name: "Alpha")),
            for: id1
        )
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id2, name: "Beta")),
            for: id2
        )
        defer {
            DatabaseManager.shared.removeSession(for: id1)
            DatabaseManager.shared.removeSession(for: id2)
        }

        #expect(DatabaseManager.shared.activeSessions[id1] != nil)
        #expect(DatabaseManager.shared.activeSessions[id2] != nil)
    }

    @Test("driver(for:) is session-scoped and returns nil when no driver is set")
    func driverForReturnsNilWithoutDriver() {
        let id1 = UUID()
        let id2 = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id1, name: "Conn1")),
            for: id1
        )
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id2, name: "Conn2")),
            for: id2
        )
        defer {
            DatabaseManager.shared.removeSession(for: id1)
            DatabaseManager.shared.removeSession(for: id2)
        }

        #expect(DatabaseManager.shared.driver(for: id1) == nil)
        #expect(DatabaseManager.shared.driver(for: id2) == nil)
    }

    @Test("session(for:) returns the correct session per ID")
    func sessionForReturnsCorrectSession() {
        let id1 = UUID()
        let id2 = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id1, name: "First")),
            for: id1
        )
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id2, name: "Second")),
            for: id2
        )
        defer {
            DatabaseManager.shared.removeSession(for: id1)
            DatabaseManager.shared.removeSession(for: id2)
        }

        let name1 = DatabaseManager.shared.session(for: id1)?.connection.name
        let name2 = DatabaseManager.shared.session(for: id2)?.connection.name
        #expect(name1 != name2)
        #expect(name1 == "First")
        #expect(name2 == "Second")
    }

    @Test("updateSession on one session does not affect another")
    func updateSessionIsScoped() {
        let id1 = UUID()
        let id2 = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id1, name: "Conn1")),
            for: id1
        )
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id2, name: "Conn2")),
            for: id2
        )
        defer {
            DatabaseManager.shared.removeSession(for: id1)
            DatabaseManager.shared.removeSession(for: id2)
        }

        let table = TestFixtures.makeTableInfo(name: "users")
        DatabaseManager.shared.updateSession(id1) { session in
            session.tables = [table]
        }

        #expect(DatabaseManager.shared.session(for: id1)?.tables.count == 1)
        #expect(DatabaseManager.shared.session(for: id2)?.tables.isEmpty == true)
    }

    @Test("Removing one session does not affect the other")
    func removingOneSessionLeavesOtherIntact() {
        let id1 = UUID()
        let id2 = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id1, name: "Conn1")),
            for: id1
        )
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: id2, name: "Conn2")),
            for: id2
        )
        defer {
            DatabaseManager.shared.removeSession(for: id1)
            DatabaseManager.shared.removeSession(for: id2)
        }

        DatabaseManager.shared.removeSession(for: id1)

        #expect(DatabaseManager.shared.activeSessions[id1] == nil)
        #expect(DatabaseManager.shared.activeSessions[id2] != nil)
    }

    @Test("updateSession with unknown ID is a no-op and does not crash")
    func updateSessionUnknownIdIsNoOp() {
        let unknownId = UUID()
        let countBefore = DatabaseManager.shared.activeSessions.count

        DatabaseManager.shared.updateSession(unknownId) { session in
            session.tables = [TestFixtures.makeTableInfo(name: "ghost")]
        }

        #expect(DatabaseManager.shared.activeSessions.count == countBefore)
        #expect(DatabaseManager.shared.session(for: unknownId) == nil)
    }

    @Test("driver(for:) returns nil after session is removed")
    func driverReturnsNilAfterSessionRemoved() {
        let connId = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: connId)),
            for: connId
        )
        defer { DatabaseManager.shared.removeSession(for: connId) }

        DatabaseManager.shared.removeSession(for: connId)

        #expect(DatabaseManager.shared.driver(for: connId) == nil)
    }

    @Test("session(for:) returns nil after session is removed")
    func sessionReturnsNilAfterSessionRemoved() {
        let connId = UUID()
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: TestFixtures.makeConnection(id: connId)),
            for: connId
        )
        defer { DatabaseManager.shared.removeSession(for: connId) }

        DatabaseManager.shared.removeSession(for: connId)

        #expect(DatabaseManager.shared.session(for: connId) == nil)
    }
}

// MARK: - Coordinator Connection Isolation

@Suite("Coordinator Connection Isolation")
@MainActor
struct CoordinatorConnectionIsolationTests {
    @Test("connectionId matches the connection's id")
    func connectionIdMatchesConnection() {
        let connId = UUID()
        let connection = TestFixtures.makeConnection(id: connId, name: "MySQL", database: "db_a", type: .mysql)
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        #expect(coordinator.connectionId == connId)
    }

    @Test("Different coordinators have independent connectionIds")
    func differentCoordinatorsHaveIndependentConnectionIds() {
        let id1 = UUID()
        let id2 = UUID()
        let conn1 = TestFixtures.makeConnection(id: id1, name: "MySQL", database: "db_a", type: .mysql)
        let conn2 = TestFixtures.makeConnection(id: id2, name: "Postgres", database: "db_b", type: .postgresql)

        let coordinator1 = MainContentCoordinator(
            connection: conn1,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            filterStateManager: FilterStateManager(),
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator1.teardown() }

        let coordinator2 = MainContentCoordinator(
            connection: conn2,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            filterStateManager: FilterStateManager(),
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator2.teardown() }

        #expect(coordinator1.connectionId != coordinator2.connectionId)
        #expect(coordinator1.connectionId == id1)
        #expect(coordinator2.connectionId == id2)
    }

    @Test("sidebarLoadingState is per-coordinator and does not bleed across instances")
    func sidebarLoadingStateIsPerCoordinator() {
        let conn1 = TestFixtures.makeConnection(id: UUID(), name: "Conn1", database: "db_a", type: .mysql)
        let conn2 = TestFixtures.makeConnection(id: UUID(), name: "Conn2", database: "db_b", type: .mysql)

        let coordinator1 = MainContentCoordinator(
            connection: conn1,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            filterStateManager: FilterStateManager(),
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator1.teardown() }

        let coordinator2 = MainContentCoordinator(
            connection: conn2,
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            filterStateManager: FilterStateManager(),
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator2.teardown() }

        coordinator1.sidebarLoadingState = .loading

        #expect(coordinator1.sidebarLoadingState == .loading)
        #expect(coordinator2.sidebarLoadingState == .idle)
    }

    @Test("openTableTab uses coordinator's connection database for the added tab")
    func openTableTabUsesCoordinatorDatabase() {
        let connId = UUID()
        let connection = TestFixtures.makeConnection(id: connId, name: "MySQL", database: "db_a", type: .mysql)
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        coordinator.openTableTab("orders")

        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.tabs.first?.databaseName == "db_a")
    }
}
