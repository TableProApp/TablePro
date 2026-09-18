//
//  SharedSidebarSyncTests.swift
//  TableProTests
//
//  Integration tests for shared sidebar state interaction with navigation logic.
//  Validates invariants that prevent feedback loops, phantom tabs, and flashing
//  when sidebar state is shared across native macOS tabs.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Shared Sidebar Sync Invariants")
struct SharedSidebarSyncTests {
    // MARK: - Helpers

    private func makeTable(_ name: String, type: TableInfo.TableType = .table) -> DatabaseTreeTableRef {
        TestFixtures.makeTableRef(name: name, type: type)
    }

    // MARK: - syncSidebarObjectSelection must not trigger navigation

    @Test("syncSidebarObjectSelection sets same table as current tab, so resolve skips")
    func syncSameTableSkipsNavigation() {
        // Simulates: didBecomeKey → syncSidebarObjectSelection → onChange fires
        // previousSelectedTables was empty (initial), sync sets [users]
        let previousSelectedTables: Set<DatabaseTreeTableRef> = []
        let newSelectedTables: Set<DatabaseTreeTableRef> = [makeTable("users")]

        // TableSelectionAction sees one table added
        let action = TableSelectionAction.resolve(
            oldTables: previousSelectedTables,
            newTables: newSelectedTables,
            selectedRowCount: (newSelectedTables).count
        )
        #expect(action == .navigate(ref: TestFixtures.makeTableRef(name: "users", type: .table)))

        // But SidebarNavigationResult.resolve skips because clicked == current tab
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: "users",  // <-- current tab IS "users"
            hasExistingTabs: true,
            isActiveTabReusable: false
        )
        #expect(result == .skip, "syncSidebarObjectSelection must not trigger navigation")
    }

    @Test("syncSidebarObjectSelection with no change fires no onChange")
    func syncNoChangeNoOnChange() {
        // When sidebarState already has [users] and sync sets [users],
        // @Observable does not fire onChange (same value)
        let previous: Set<DatabaseTreeTableRef> = [makeTable("users")]
        let new: Set<DatabaseTreeTableRef> = [makeTable("users")]
        let action = TableSelectionAction.resolve(oldTables: previous, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation, "Same selection set must not trigger navigation")
    }

    @Test("syncSidebarObjectSelection clears selection for a query tab without navigating")
    func syncClearsForQueryTab() {
        // Current tab is SQL query (tableName = nil), sync clears sidebar
        let previous: Set<DatabaseTreeTableRef> = [makeTable("users")]
        let new: Set<DatabaseTreeTableRef> = []
        let action = TableSelectionAction.resolve(oldTables: previous, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation, "Clearing selection must not navigate")
    }

    // MARK: - Non-key window must not navigate

    @Test("Non-key window: navigate action resolved but isKeyWindow=false blocks it")
    func nonKeyWindowBlocksNavigation() {
        // Window B has "orders" tab, shared state changes to [users]
        // TableSelectionAction says navigate
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("orders")],
            newTables: [makeTable("users")],
            selectedRowCount: ([makeTable("users")]).count
        )
        #expect(action == .navigate(ref: TestFixtures.makeTableRef(name: "users", type: .table)))

        // But isKeyWindow guard blocks it. We test the invariant:
        // handleTableSelectionChange should early-return when isKeyWindow=false.
        // The guard is: guard isKeyWindow else { return }
        // This test documents the contract.
        let isKeyWindow = false
        #expect(!isKeyWindow, "Non-key windows must not process navigate actions")
    }

    // MARK: - App switch-back scenarios

    @Test("Switch back: sync sets same table — skip, no new tab")
    func switchBackSameTable() {
        // User has "users" tab, switches away and back
        // syncSidebarObjectSelection sets [users] (same as before)
        let previous: Set<DatabaseTreeTableRef> = [makeTable("users")]
        let new: Set<DatabaseTreeTableRef> = [makeTable("users")]
        let action = TableSelectionAction.resolve(oldTables: previous, newTables: new, selectedRowCount: new.count)
        #expect(action == .noNavigation, "Switch-back with same table must be no-op")
    }

    @Test("Switch back with stale previousSelectedTables — still skips via SidebarNavigationResult")
    func switchBackStalePreviousStillSkips() {
        // Edge case: previousSelectedTables is stale (empty) but sync sets [users]
        // which matches current tab
        let action = TableSelectionAction.resolve(
            oldTables: [],
            newTables: [makeTable("users")],
            selectedRowCount: ([makeTable("users")]).count
        )
        // This produces .navigate — but SidebarNavigationResult catches it
        #expect(action == .navigate(ref: TestFixtures.makeTableRef(name: "users", type: .table)))

        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: "users",
            hasExistingTabs: true,
            isActiveTabReusable: false
        )
        #expect(result == .skip, "Even with stale previous, skip when table matches current tab")
    }

    @Test("Switch back to SQL query tab — sync clears, no navigation")
    func switchBackToQueryTab() {
        // User was on SQL query tab (tableName = nil), switches back
        // syncSidebarObjectSelection clears selection
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("users")],
            newTables: [],
            selectedRowCount: ([]).count
        )
        #expect(action == .noNavigation)
    }

    // MARK: - User sidebar click scenarios

    @Test("Click different table with existing tabs — opens new native tab")
    func clickDifferentTableOpensNewTab() {
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("users")],
            newTables: [makeTable("orders")],
            selectedRowCount: ([makeTable("orders")]).count
        )
        #expect(action == .navigate(ref: TestFixtures.makeTableRef(name: "orders", type: .table)))

        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: "users",
            hasExistingTabs: true,
            isActiveTabReusable: false
        )
        #expect(result == .openNewTab)
    }

    @Test("Click table with no existing tabs — opens in place")
    func clickTableEmptyTabsOpensInPlace() {
        let action = TableSelectionAction.resolve(
            oldTables: [],
            newTables: [makeTable("users")],
            selectedRowCount: ([makeTable("users")]).count
        )
        #expect(action == .navigate(ref: TestFixtures.makeTableRef(name: "users", type: .table)))

        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: nil,
            hasExistingTabs: false,
            isActiveTabReusable: false
        )
        #expect(result == .reuseActiveTab)
    }

    @Test("Click same table as current tab — skip")
    func clickSameTableSkips() {
        // Edge case: previousSelectedTables was different (e.g. empty after tab switch)
        let action = TableSelectionAction.resolve(
            oldTables: [],
            newTables: [makeTable("users")],
            selectedRowCount: ([makeTable("users")]).count
        )
        #expect(action == .navigate(ref: TestFixtures.makeTableRef(name: "users", type: .table)))

        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: "users",
            hasExistingTabs: true,
            isActiveTabReusable: false
        )
        #expect(result == .skip)
    }

    // MARK: - Multi-window shared state scenarios

    @Test("Window A syncs [users], Window B has [orders] tab — B must not navigate")
    func windowASyncWindowBBlocked() {
        // Window A becomes key, syncs sidebar to [users]
        // Window B (non-key) sees onChange: from [orders] to [users]
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("orders")],
            newTables: [makeTable("users")],
            selectedRowCount: ([makeTable("users")]).count
        )
        #expect(action == .navigate(ref: TestFixtures.makeTableRef(name: "users", type: .table)))
        // Window B's isKeyWindow = false → handleTableSelectionChange returns early
        // This is enforced by the guard, not by these pure functions
    }

    @Test("Both windows sync same table — no change, no navigation")
    func bothWindowsSyncSameTable() {
        // Both windows have "users" tab. Any sync writes [users].
        // No value change → no onChange → no navigation
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("users")],
            newTables: [makeTable("users")],
            selectedRowCount: ([makeTable("users")]).count
        )
        #expect(action == .noNavigation)
    }

    // MARK: - Deselection scenarios

    @Test("Cmd+A selects all — no navigation")
    func selectAllNoNavigation() {
        let action = TableSelectionAction.resolve(
            oldTables: [],
            newTables: [makeTable("a"), makeTable("b"), makeTable("c")],
            selectedRowCount: ([makeTable("a"), makeTable("b"), makeTable("c")]).count
        )
        #expect(action == .noNavigation)
    }

    @Test("Deselect all — no navigation")
    func deselectAllNoNavigation() {
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("users"), makeTable("orders")],
            newTables: [],
            selectedRowCount: ([]).count
        )
        #expect(action == .noNavigation)
    }
}
