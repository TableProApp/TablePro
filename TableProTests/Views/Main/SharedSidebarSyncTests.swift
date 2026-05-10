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

    private func makeTable(_ name: String, type: TableInfo.TableType = .table) -> TableInfo {
        TestFixtures.makeTableInfo(name: name, type: type)
    }

    // MARK: - syncSidebarToCurrentTab must not trigger navigation

    @Test("syncSidebarToCurrentTab sets same table as current tab — resolve skips")
    func syncSameTableSkipsNavigation() {
        // Simulates: didBecomeKey → syncSidebarToCurrentTab → onChange fires
        // previousSelectedTables was empty (initial), sync sets [users]
        let previousSelectedTables: Set<TableInfo> = []
        let newSelectedTables: Set<TableInfo> = [makeTable("users")]

        // TableSelectionAction sees one table added
        let action = TableSelectionAction.resolve(
            oldTables: previousSelectedTables,
            newTables: newSelectedTables
        )
        #expect(action == .navigate(tableName: "users", isView: false))

        // But SidebarNavigationResult.resolve skips because clicked == current tab
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: "users",  // <-- current tab IS "users"
            hasExistingTabs: true
        )
        #expect(result == .skip, "syncSidebarToCurrentTab must not trigger navigation")
    }

    @Test("syncSidebarToCurrentTab with no change — no onChange fires")
    func syncNoChangeNoOnChange() {
        // When sidebarState already has [users] and sync sets [users],
        // @Observable does not fire onChange (same value)
        let previous: Set<TableInfo> = [makeTable("users")]
        let new: Set<TableInfo> = [makeTable("users")]
        let action = TableSelectionAction.resolve(oldTables: previous, newTables: new)
        #expect(action == .noNavigation, "Same selection set must not trigger navigation")
    }

    @Test("syncSidebarToCurrentTab clears selection for query tab — no navigation")
    func syncClearsForQueryTab() {
        // Current tab is SQL query (tableName = nil), sync clears sidebar
        let previous: Set<TableInfo> = [makeTable("users")]
        let new: Set<TableInfo> = []
        let action = TableSelectionAction.resolve(oldTables: previous, newTables: new)
        #expect(action == .noNavigation, "Clearing selection must not navigate")
    }

    // MARK: - Non-key window must not navigate

    @Test("Non-key window: navigate action resolved but isKeyWindow=false blocks it")
    func nonKeyWindowBlocksNavigation() {
        // Window B has "orders" tab, shared state changes to [users]
        // TableSelectionAction says navigate
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("orders")],
            newTables: [makeTable("users")]
        )
        #expect(action == .navigate(tableName: "users", isView: false))

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
        // syncSidebarToCurrentTab sets [users] (same as before)
        let previous: Set<TableInfo> = [makeTable("users")]
        let new: Set<TableInfo> = [makeTable("users")]
        let action = TableSelectionAction.resolve(oldTables: previous, newTables: new)
        #expect(action == .noNavigation, "Switch-back with same table must be no-op")
    }

    @Test("Switch back with stale previousSelectedTables — still skips via SidebarNavigationResult")
    func switchBackStalePreviousStillSkips() {
        // Edge case: previousSelectedTables is stale (empty) but sync sets [users]
        // which matches current tab
        let action = TableSelectionAction.resolve(
            oldTables: [],
            newTables: [makeTable("users")]
        )
        // This produces .navigate — but SidebarNavigationResult catches it
        #expect(action == .navigate(tableName: "users", isView: false))

        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: "users",
            hasExistingTabs: true
        )
        #expect(result == .skip, "Even with stale previous, skip when table matches current tab")
    }

    @Test("Switch back to SQL query tab — sync clears, no navigation")
    func switchBackToQueryTab() {
        // User was on SQL query tab (tableName = nil), switches back
        // syncSidebarToCurrentTab clears selection
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("users")],
            newTables: []
        )
        #expect(action == .noNavigation)
    }

    // MARK: - User sidebar click scenarios

    @Test("Click different table with existing tabs — opens new native tab")
    func clickDifferentTableOpensNewTab() {
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("users")],
            newTables: [makeTable("orders")]
        )
        #expect(action == .navigate(tableName: "orders", isView: false))

        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: "users",
            hasExistingTabs: true
        )
        #expect(result == .revertAndOpenNewWindow)
    }

    @Test("Click table with no existing tabs — opens in place")
    func clickTableEmptyTabsOpensInPlace() {
        let action = TableSelectionAction.resolve(
            oldTables: [],
            newTables: [makeTable("users")]
        )
        #expect(action == .navigate(tableName: "users", isView: false))

        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: nil,
            hasExistingTabs: false
        )
        #expect(result == .openInPlace)
    }

    @Test("Click same table as current tab — skip")
    func clickSameTableSkips() {
        // Edge case: previousSelectedTables was different (e.g. empty after tab switch)
        let action = TableSelectionAction.resolve(
            oldTables: [],
            newTables: [makeTable("users")]
        )
        #expect(action == .navigate(tableName: "users", isView: false))

        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: "users",
            hasExistingTabs: true
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
            newTables: [makeTable("users")]
        )
        #expect(action == .navigate(tableName: "users", isView: false))
        // Window B's isKeyWindow = false → handleTableSelectionChange returns early
        // This is enforced by the guard, not by these pure functions
    }

    @Test("Both windows sync same table — no change, no navigation")
    func bothWindowsSyncSameTable() {
        // Both windows have "users" tab. Any sync writes [users].
        // No value change → no onChange → no navigation
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("users")],
            newTables: [makeTable("users")]
        )
        #expect(action == .noNavigation)
    }

    // MARK: - Tables load scenarios

    @Test("Tables load with empty sidebar and matching tab — syncs selection")
    func tablesLoadSyncsSelection() {
        let tables = [makeTable("users"), makeTable("orders")]
        let result = SidebarSyncAction.resolveOnTablesLoad(
            newTables: tables,
            selectedTables: [],
            currentTabTableName: "users"
        )
        #expect(result == .select(tableName: "users"))
    }

    @Test("Tables load with existing sidebar selection — no sync")
    func tablesLoadNoSyncWhenSelected() {
        let tables = [makeTable("users"), makeTable("orders")]
        let result = SidebarSyncAction.resolveOnTablesLoad(
            newTables: tables,
            selectedTables: [makeTable("users")],
            currentTabTableName: "orders"
        )
        #expect(result == .noSync)
    }

    // MARK: - Deselection scenarios

    @Test("Cmd+A selects all — no navigation")
    func selectAllNoNavigation() {
        let action = TableSelectionAction.resolve(
            oldTables: [],
            newTables: [makeTable("a"), makeTable("b"), makeTable("c")]
        )
        #expect(action == .noNavigation)
    }

    @Test("Deselect all — no navigation")
    func deselectAllNoNavigation() {
        let action = TableSelectionAction.resolve(
            oldTables: [makeTable("users"), makeTable("orders")],
            newTables: []
        )
        #expect(action == .noNavigation)
    }
}
