//
//  QueryTabManagerVisibleContainerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct QueryTabManagerVisibleContainerTests {
    private func makeManager(
        target: ContainerSwitchTarget? = .database,
        visible: String? = "tenant_a"
    ) -> QueryTabManager {
        QueryTabManager(containerTarget: target, visibleContainer: visible)
    }

    private func queryTab(database: String, schema: String? = nil, title: String = "Query") -> QueryTab {
        var tab = QueryTab(title: title, query: "SELECT 1")
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    private func dashboardTab() -> QueryTab {
        QueryTab(title: "Server Dashboard", tabType: .serverDashboard)
    }

    // MARK: - Projection

    @Test("The strip lists the visible entry's tabs and the ones that belong to every entry")
    func visibleTabsAreTheEntrysAndTheConnectionWideOnes() {
        let manager = makeManager()
        let tenantA = queryTab(database: "tenant_a")
        let tenantB = queryTab(database: "tenant_b")
        let dashboard = dashboardTab()
        manager.tabs = [tenantA, tenantB, dashboard]

        #expect(manager.visibleTabs.map(\.id) == [tenantA.id, dashboard.id])
    }

    @Test("An engine that switches no container shows every tab and has nothing to show")
    func noContainerTargetShowsEverything() {
        let manager = makeManager(target: nil, visible: "tenant_a")
        let tenantA = queryTab(database: "tenant_a")
        let tenantB = queryTab(database: "tenant_b")
        manager.tabs = [tenantA, tenantB]

        manager.show(container: "tenant_b")

        #expect(manager.visibleContainer == nil)
        #expect(manager.visibleTabs.count == 2)
    }

    // MARK: - Binding

    @Test("A query tab opened without a database is bound to the visible entry's")
    func unboundQueryTabTakesTheVisibleDatabase() {
        let manager = makeManager()

        manager.addTab(initialQuery: "SELECT 1")

        #expect(manager.tabs.first?.tableContext.databaseName == "tenant_a")
    }

    /// Left unbound it ran against whatever schema was browsed next, and picking a tab of another
    /// schema moves that: a statement typed against HR would have run against SCOTT.
    @Test("A query tab on a schema engine is bound to the visible schema")
    func schemaEngineQueryTabIsBound() {
        let manager = makeManager(target: .schema, visible: "HR")

        manager.addTab(initialQuery: "SELECT 1 FROM dual", databaseName: "ORCL")
        manager.show(container: "SCOTT")

        #expect(manager.tabs.first?.tableContext.schemaName == "HR")
        #expect(manager.visibleTabs.isEmpty)
    }

    @Test("Server-wide tabs stay unbound and show in every entry")
    func serverTabsAreNotBound() {
        let manager = makeManager()

        manager.addServerDashboardTab()
        manager.show(container: "tenant_b")

        #expect(manager.tabs.first?.tableContext.databaseName == "")
        #expect(manager.visibleTabs.count == 1)
    }

    /// Restored from before tabs were bound: they ran against the container the connection was on,
    /// which is the one the restore lands in.
    @Test("A restore binds tabs saved without a container to the entry it lands in")
    func restoreBindsUnboundTabs() {
        let manager = makeManager(visible: "tenant_b")
        var legacy = QueryTab(title: "Query 1", query: "SELECT 1")
        legacy.tableContext.databaseName = ""
        manager.tabs = [legacy, dashboardTab()]

        manager.bindUnboundTabs()

        #expect(manager.tabs.map(\.tableContext.databaseName) == ["tenant_b", ""])
    }

    // MARK: - Selection carries the entry

    @Test("Selecting a tab of another entry puts that entry in front and says so once")
    func selectingAnotherEntrysTabMovesTheEntry() {
        let manager = makeManager()
        let tenantA = queryTab(database: "tenant_a")
        let tenantB = queryTab(database: "tenant_b")
        manager.tabs = [tenantA, tenantB]
        manager.selectedTabId = tenantA.id
        var reports = 0
        manager.onVisibleContainerReconciled = { reports += 1 }

        manager.selectedTabId = tenantB.id

        #expect(manager.visibleContainer == "tenant_b")
        #expect(manager.visibleTabs.map(\.id) == [tenantB.id])
        #expect(reports == 1)
    }

    /// The per-tab database picker and a rename move a tab without anyone writing the selection.
    @Test("Moving the selected tab to another database takes the window with it")
    func rebindingTheSelectedTabMovesTheEntry() {
        let manager = makeManager()
        let tab = queryTab(database: "tenant_a")
        manager.tabs = [tab]
        manager.selectedTabId = tab.id
        var reports = 0
        manager.onVisibleContainerReconciled = { reports += 1 }

        manager.mutate(tabId: tab.id) { $0.tableContext.databaseName = "tenant_b" }

        #expect(manager.visibleContainer == "tenant_b")
        #expect(manager.selectedTab?.id == tab.id)
        #expect(reports == 1)
    }

    @Test("Selecting a tab that belongs to every entry leaves the entry where it is")
    func selectingAConnectionWideTabKeepsTheEntry() {
        let manager = makeManager()
        let dashboard = dashboardTab()
        manager.tabs = [queryTab(database: "tenant_a"), dashboard]

        manager.selectedTabId = dashboard.id

        #expect(manager.visibleContainer == "tenant_a")
    }

    // MARK: - Showing an entry

    @Test("Showing an entry lands on the tab last used there")
    func showingAnEntryLandsOnItsLastTab() {
        let manager = makeManager()
        let first = queryTab(database: "tenant_a")
        let second = queryTab(database: "tenant_a")
        let other = queryTab(database: "tenant_b")
        manager.tabs = [first, second, other]
        manager.selectedTabId = first.id
        manager.selectedTabId = other.id

        manager.show(container: "tenant_a")

        #expect(manager.visibleContainer == "tenant_a")
        #expect(manager.selectedTabId == first.id)
    }

    @Test("Showing an entry with no tab of its own shows its empty state")
    func showingAnEmptyEntrySelectsNothing() {
        let manager = makeManager()
        let tab = queryTab(database: "tenant_a")
        manager.tabs = [tab]
        manager.selectedTabId = tab.id

        manager.show(container: "tenant_c")

        #expect(manager.selectedTabId == nil)
        #expect(manager.selectedTab == nil)
        #expect(manager.tabs.count == 1)
    }

    @Test("Showing the entry already in front keeps the selection")
    func showingTheSameEntryKeepsTheSelection() {
        let manager = makeManager()
        let first = queryTab(database: "tenant_a")
        let second = queryTab(database: "tenant_a")
        manager.tabs = [first, second]
        manager.selectedTabId = first.id

        manager.show(container: "tenant_a")

        #expect(manager.selectedTabId == first.id)
    }

    @Test("Showing an entry never reports a move for the connection to follow")
    func showingDoesNotReport() {
        let manager = makeManager()
        manager.tabs = [queryTab(database: "tenant_a"), queryTab(database: "tenant_b")]
        var reports = 0
        manager.onVisibleContainerReconciled = { reports += 1 }

        manager.show(container: "tenant_b")

        #expect(reports == 0)
    }

    @Test("A new window's tab puts its entry in front without reporting a move")
    func seedingDoesNotReport() {
        let manager = makeManager()
        var reports = 0
        manager.onVisibleContainerReconciled = { reports += 1 }
        let tab = queryTab(database: "tenant_b")

        manager.seed(with: tab)

        #expect(manager.visibleContainer == "tenant_b")
        #expect(manager.selectedTabId == tab.id)
        #expect(reports == 0)
    }

    // MARK: - Strip positions

    @Test("Command-number and next-tab count the strip's tabs only")
    func numberedSelectionCountsVisibleTabs() {
        let manager = makeManager()
        let a1 = queryTab(database: "tenant_a")
        let b1 = queryTab(database: "tenant_b")
        let a2 = queryTab(database: "tenant_a")
        manager.tabs = [a1, b1, a2]
        manager.selectedTabId = a1.id

        manager.selectTab(at: 1)
        #expect(manager.selectedTabId == a2.id)

        manager.selectTab(offsetBy: 1)
        #expect(manager.selectedTabId == a1.id)
        #expect(manager.visibleContainer == "tenant_a")
    }

    /// The strip reports a drop as a position among the tabs it draws, and the other entries' tabs
    /// sitting between them in the connection's list must not shift where it lands.
    @Test("A drag lands beside the strip neighbour it was dropped next to")
    func reorderUsesStripPositions() {
        let manager = makeManager()
        let a1 = queryTab(database: "tenant_a", title: "a1")
        let b1 = queryTab(database: "tenant_b", title: "b1")
        let a2 = queryTab(database: "tenant_a", title: "a2")
        let a3 = queryTab(database: "tenant_a", title: "a3")
        manager.tabs = [a1, b1, a2, a3]
        manager.selectedTabId = a1.id

        manager.moveTab(id: a1.id, to: 2)
        #expect(manager.visibleTabs.map(\.title) == ["a2", "a3", "a1"])

        manager.moveTab(id: a1.id, to: 0)
        #expect(manager.visibleTabs.map(\.title) == ["a1", "a2", "a3"])
        #expect(manager.tabs.count == 4)
    }

    @Test("A tab at the strip's edge cannot move past it, whatever sits behind it")
    func moveByStopsAtTheStripEdge() {
        let manager = makeManager()
        let b1 = queryTab(database: "tenant_b")
        let a1 = queryTab(database: "tenant_a")
        manager.tabs = [b1, a1]
        manager.selectedTabId = a1.id

        #expect(!manager.canMoveTab(id: a1.id, by: -1))
        #expect(!manager.canMoveTab(id: a1.id, by: 1))
    }

    // MARK: - Closing

    @Test("Closing a tab lands on its neighbour in the strip, never on another entry's tab")
    func closingLandsOnAStripNeighbour() {
        let manager = makeManager()
        let a1 = queryTab(database: "tenant_a")
        let b1 = queryTab(database: "tenant_b")
        let a2 = queryTab(database: "tenant_a")
        manager.tabs = [a1, b1, a2]
        manager.selectedTabId = a1.id

        manager.closeTab(id: a1.id)

        #expect(manager.selectedTabId == a2.id)
        #expect(manager.visibleContainer == "tenant_a")
    }

    @Test("Closing an entry's last tab leaves it empty and the other entries' tabs alone")
    func closingTheLastTabOfAnEntry() {
        let manager = makeManager()
        let a1 = queryTab(database: "tenant_a")
        let b1 = queryTab(database: "tenant_b")
        manager.tabs = [a1, b1]
        manager.selectedTabId = a1.id

        manager.closeTab(id: a1.id)

        #expect(manager.selectedTabId == nil)
        #expect(manager.visibleContainer == "tenant_a")
        #expect(manager.tabs.map(\.id) == [b1.id])
    }
}
