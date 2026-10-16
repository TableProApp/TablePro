//
//  VisibleContainerFollowingTests.swift
//  TableProTests
//
//  The entry a window shows and the database its connection browses move together: a tab picked
//  in another entry takes the connection there, and a switch made outside the window brings that
//  entry forward.
//

import Foundation
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct VisibleContainerFollowingTests {
    private func withConnectedCoordinator(
        _ body: (MainContentCoordinator, QueryTabManager, DatabaseConnection) async throws -> Void
    ) async throws {
        let connection = TestFixtures.makeConnection(database: "db_a", type: .mysql)
        let driver = PluginDriverAdapter(connection: connection, pluginDriver: SwitchingDriverStub())
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager(containerTarget: .database, visibleContainer: "db_a")
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try await body(coordinator, tabManager, connection)
    }

    private func queryTab(database: String) -> QueryTab {
        var tab = QueryTab(title: "Query", query: "SELECT 1")
        tab.tableContext.databaseName = database
        return tab
    }

    @Test("Picking a tab of another database takes the connection there")
    func selectingAnotherEntrysTabMovesTheCursor() async throws {
        try await withConnectedCoordinator { coordinator, tabManager, connection in
            let tenantA = queryTab(database: "db_a")
            let tenantB = queryTab(database: "db_b")
            tabManager.tabs = [tenantA, tenantB]
            tabManager.selectedTabId = tenantA.id

            tabManager.selectedTabId = tenantB.id

            try await waitUntil { coordinator.browseCursorCoordinator.browsedContainer == "db_b" }
            #expect(tabManager.visibleContainer == "db_b")
            #expect(tabManager.selectedTabId == tenantB.id)
            /// Picking a tab is not choosing a database to come back to.
            #expect(AppSettingsStorage.shared.loadLastDatabase(for: connection.id) != "db_b")
        }
    }

    /// An MCP client or a script moves the cursor without going through the window.
    @Test("A switch made outside the window brings that database's entry forward")
    func outsideSwitchShowsTheEntry() async throws {
        try await withConnectedCoordinator { coordinator, tabManager, connection in
            let tenantA = queryTab(database: "db_a")
            let tenantB = queryTab(database: "db_b")
            tabManager.tabs = [tenantA, tenantB]
            tabManager.selectedTabId = tenantA.id

            try await DatabaseManager.shared.switchDatabase(to: "db_b", for: connection.id, persist: false)

            try await waitUntil { tabManager.visibleContainer == "db_b" }
            #expect(tabManager.selectedTabId == tenantB.id)
            #expect(coordinator.browseCursorCoordinator.pendingRequest == nil)
        }
    }

    /// Switches queue on the driver, so an earlier one can land after a newer one was asked for.
    @Test("Only the latest move this window asked for is applied when it lands")
    func staleLandingIsNotApplied() async throws {
        try await withConnectedCoordinator { coordinator, _, _ in
            let first = coordinator.browseCursorCoordinator.beginRequest()
            let second = coordinator.browseCursorCoordinator.beginRequest()

            #expect(!coordinator.browseCursorCoordinator.endRequest(first))
            #expect(coordinator.browseCursorCoordinator.endRequest(second))
            #expect(coordinator.browseCursorCoordinator.pendingRequest == nil)
        }
    }

    /// Picking a tab of the database being left, before the switch away lands, has to win: the
    /// earlier switch would otherwise land and take the window back to the other entry.
    @Test("A selection supersedes a switch still on its way")
    func followSupersedesAPendingSwitch() async throws {
        try await withConnectedCoordinator { coordinator, tabManager, _ in
            tabManager.tabs = [queryTab(database: "db_a")]
            let earlier = coordinator.browseCursorCoordinator.beginRequest()

            coordinator.browseCursorCoordinator.followVisibleContainer()

            try await waitUntil { coordinator.browseCursorCoordinator.pendingRequest == nil }
            #expect(!coordinator.browseCursorCoordinator.endRequest(earlier))
            #expect(coordinator.browseCursorCoordinator.browsedContainer == "db_a")
        }
    }

    /// The edits are the outgoing tab's and go with it. Left in the change manager with no tab
    /// selected, a Save would write them against the database on screen.
    @Test("Landing on an entry with no tabs keeps the outgoing edits on their tab")
    func emptyEntryTakesNoLiveEdits() async throws {
        try await withConnectedCoordinator { coordinator, tabManager, _ in
            var orders = QueryTab(title: "orders", query: "SELECT * FROM orders", tabType: .table, tableName: "orders")
            orders.tableContext.databaseName = "db_a"
            tabManager.tabs = [orders]
            tabManager.selectedTabId = orders.id
            coordinator.changeManager.configureForTable(
                tableName: "orders",
                columns: ["id", "status"],
                primaryKeyColumns: ["id"],
                databaseType: .mysql,
                generatedColumns: []
            )
            coordinator.changeManager.recordCellChange(
                rowID: .existing(0),
                columnIndex: 1,
                columnName: "status",
                oldValue: "open",
                newValue: "paid",
                originalRow: ["1", "open"]
            )

            tabManager.show(container: "db_b")
            coordinator.handleTabChange(from: orders.id, to: nil, tabs: tabManager.tabs)

            #expect(!coordinator.changeManager.hasChanges)
            #expect(tabManager.tabs.first?.pendingChanges.hasChanges == true)
        }
    }

    /// Going to an entry shows its tabs before the switch lands, and a tab opened in that moment
    /// belongs to the entry on screen, not to the database the cursor is leaving.
    @Test("A new tab opened while going to another entry lands in that entry")
    func newTabDuringASwitchTakesTheShownEntry() async throws {
        try await withConnectedCoordinator { coordinator, tabManager, _ in
            tabManager.tabs = [queryTab(database: "db_a")]

            coordinator.browseCursorCoordinator.goToEntry("db_b")

            #expect(coordinator.browseCursorCoordinator.browsedContainer == "db_a")
            #expect(coordinator.newTabDatabaseName == "db_b")
            tabManager.addTab(initialQuery: "SELECT 1", databaseName: coordinator.newTabDatabaseName)
            #expect(tabManager.visibleContainer == "db_b")
            try await waitUntil { coordinator.browseCursorCoordinator.browsedContainer == "db_b" }
        }
    }

    /// A follow scheduled but not yet started has to be in flight already, or a newer move to the
    /// database still browsed sees nothing to supersede and the older one takes the window away.
    @Test("A scheduled switch that was superseded before it started never runs")
    func supersededScheduledSwitchNeverRuns() async throws {
        try await withConnectedCoordinator { coordinator, tabManager, _ in
            tabManager.tabs = [queryTab(database: "db_a"), queryTab(database: "db_b")]
            tabManager.show(container: "db_b")
            coordinator.browseCursorCoordinator.followVisibleContainer()

            coordinator.browseCursorCoordinator.goToEntry("db_a")

            try await waitUntil { coordinator.browseCursorCoordinator.pendingRequest == nil }
            #expect(coordinator.browseCursorCoordinator.browsedContainer == "db_a")
            #expect(tabManager.visibleContainer == "db_a")
        }
    }

    /// Two windows of one connection share its cursor; the window the user comes back to decides.
    @Test("A window coming to the front takes the connection to the entry it shows")
    func activationMovesTheCursorToTheShownEntry() async throws {
        try await withConnectedCoordinator { coordinator, tabManager, _ in
            tabManager.tabs = [queryTab(database: "db_b")]
            tabManager.show(container: "db_b")

            coordinator.browseCursorCoordinator.followVisibleContainerOnActivation()

            try await waitUntil { coordinator.browseCursorCoordinator.browsedContainer == "db_b" }
        }
    }

    /// Dismissing the error makes the window key again, and asking again there raised it again.
    @Test("Coming to the front does not retry a switch that just failed")
    func activationSkipsAFailedSwitch() async throws {
        try await withConnectedCoordinator { coordinator, tabManager, _ in
            tabManager.tabs = [queryTab(database: "db_b")]
            tabManager.show(container: "db_b")
            coordinator.browseCursorCoordinator.failedFollow = "db_b"

            coordinator.browseCursorCoordinator.followVisibleContainerOnActivation()

            #expect(coordinator.browseCursorCoordinator.pendingRequest == nil)
            #expect(coordinator.browseCursorCoordinator.browsedContainer == "db_a")
        }
    }

    @Test("A switch to the database already browsed still brings its entry forward")
    func satisfiedSwitchShowsTheEntry() async throws {
        try await withConnectedCoordinator { coordinator, tabManager, _ in
            let tenantA = queryTab(database: "db_a")
            tabManager.tabs = [tenantA]
            tabManager.show(container: "db_b")
            #expect(tabManager.selectedTabId == nil)

            await coordinator.switchContainers(database: "db_a", schema: nil)

            #expect(tabManager.visibleContainer == "db_a")
            #expect(tabManager.selectedTabId == tenantA.id)
        }
    }
}
