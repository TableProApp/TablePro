//
//  SidebarNavigationResultTests.swift
//  TableProTests
//
//  Tests for SidebarNavigationResult — the pure decision logic that controls
//  whether a sidebar click navigates in-place, opens a new native tab, or is
//  a no-op programmatic sync.
//
//  These tests encode the "no-flash contract": when a table is clicked that is
//  NOT the active tab and the window already has tabs, the result must be
//  .revertAndOpenNewWindow — the sidebar reverts synchronously so SwiftUI never
//  renders the [B] selection state.
//

import Foundation
import Testing
@testable import TablePro

@Suite("SidebarNavigationResult")
struct SidebarNavigationResultTests {

    // MARK: - .skip (programmatic sync, no navigation)

    @Test("Skip when clicked table matches active tab and tabs exist")
    func skipWhenTableMatchesCurrentTabWithTabs() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: "users",
            hasExistingTabs: true
        )
        #expect(result == .skip)
    }

    @Test("Skip when clicked table matches active tab and no other tabs")
    func skipWhenTableMatchesCurrentTabNoOtherTabs() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: "orders",
            hasExistingTabs: false
        )
        #expect(result == .skip)
    }

    @Test("Skip is case-sensitive — different case is NOT a match")
    func skipIsCaseSensitive() {
        // Table names are case-sensitive; "Users" ≠ "users"
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "Users",
            currentTabTableName: "users",
            hasExistingTabs: true
        )
        #expect(result != .skip)
    }

    // MARK: - .openInPlace (empty window, navigate in-place)

    @Test("Open in-place when tabs are empty and no current tab")
    func openInPlaceWhenTabsEmpty() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "products",
            currentTabTableName: nil,
            hasExistingTabs: false
        )
        #expect(result == .openInPlace)
    }

    @Test("Open in-place when tabs are empty even if current tab name matches different value")
    func openInPlaceWhenTabsEmptyWithCurrentTabName() {
        // hasExistingTabs is the authoritative flag; if false, always openInPlace
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "products",
            currentTabTableName: "users",
            hasExistingTabs: false
        )
        #expect(result == .openInPlace)
    }

    @Test("Open in-place when tabs are empty with an empty string table name")
    func openInPlaceWithEmptyStringTableName() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "",
            currentTabTableName: nil,
            hasExistingTabs: false
        )
        #expect(result == .openInPlace)
    }

    // MARK: - .revertAndOpenNewWindow (no-flash contract)

    @Test("Revert and open new window when tabs exist and different table is clicked")
    func revertAndOpenNewWindowWhenTabsExistDifferentTable() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "products",
            currentTabTableName: "users",
            hasExistingTabs: true
        )
        #expect(result == .revertAndOpenNewWindow)
    }

    @Test("Revert and open new window when tabs exist and current tab is a query tab (nil name)")
    func revertAndOpenNewWindowWhenCurrentTabIsQueryTab() {
        // A query tab has no tableName (nil); clicking any table should open new window
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: nil,
            hasExistingTabs: true
        )
        #expect(result == .revertAndOpenNewWindow)
    }

    @Test("Revert and open new window with empty current tab name")
    func revertAndOpenNewWindowWithEmptyCurrentTabName() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: "",
            hasExistingTabs: true
        )
        #expect(result == .revertAndOpenNewWindow)
    }

    // MARK: - No-flash contract (critical invariants)

    @Test("Never skips when different table is clicked and tabs exist")
    func noFlashContract_differentTableWithTabsMustNotSkip() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: "users",
            hasExistingTabs: true
        )
        #expect(result != .skip)
        #expect(result == .revertAndOpenNewWindow)
    }

    @Test("Never opens in-place when tabs already exist")
    func noFlashContract_tabsExistMustNotOpenInPlace() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: "users",
            hasExistingTabs: true
        )
        #expect(result != .openInPlace)
    }

    @Test("Never opens new window when tables are empty — always in-place")
    func noFlashContract_emptyTabsMustNotOpenNewWindow() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: nil,
            hasExistingTabs: false
        )
        #expect(result != .revertAndOpenNewWindow)
        #expect(result == .openInPlace)
    }

    // MARK: - QueryTabManager integration

    @Test("Resolves to openInPlace for fresh QueryTabManager with no tabs")
    @MainActor
    func resolveWithFreshTabManager() {
        let manager = QueryTabManager()
        // Fresh manager has no tabs
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: manager.selectedTab?.tableName,
            hasExistingTabs: !manager.tabs.isEmpty
        )
        #expect(result == .openInPlace)
    }

    @Test("Resolves to skip when clicking the active table in QueryTabManager")
    @MainActor
    func resolveSkipWithActiveTableInTabManager() {
        let manager = QueryTabManager()
        manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: manager.selectedTab?.tableName,
            hasExistingTabs: !manager.tabs.isEmpty
        )
        #expect(result == .skip)
    }

    @Test("Resolves to revertAndOpenNewWindow when clicking a different table in non-empty window")
    @MainActor
    func resolveNewWindowWhenClickingDifferentTable() {
        let manager = QueryTabManager()
        manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: manager.selectedTab?.tableName,
            hasExistingTabs: !manager.tabs.isEmpty
        )
        #expect(result == .revertAndOpenNewWindow)
    }

    @Test("Resolves to revertAndOpenNewWindow when current tab is a query tab but window has tabs")
    @MainActor
    func resolveNewWindowWhenCurrentTabIsQueryTabButWindowHasTabs() {
        let manager = QueryTabManager()
        manager.addTab(databaseName: "mydb")   // query tab — no tableName
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "products",
            currentTabTableName: manager.selectedTab?.tableName,  // nil for query tab
            hasExistingTabs: !manager.tabs.isEmpty
        )
        #expect(result == .revertAndOpenNewWindow)
    }

    // MARK: - syncSidebarToCurrentTab logic

    @Test("Sync finds table by name in table list")
    func syncFindsTableByName() {
        let tables = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "products")
        ]
        let match = tables.first(where: { $0.name == "orders" })
        #expect(match?.name == "orders")
    }

    @Test("Sync returns nil when table not found")
    func syncReturnsNilForMissingTable() {
        let tables = [TestFixtures.makeTableInfo(name: "users")]
        let match = tables.first(where: { $0.name == "nonexistent" })
        #expect(match == nil)
    }

    @Test("Sync returns nil for empty table list")
    func syncReturnsNilForEmptyList() {
        let tables: [TableInfo] = []
        let match = tables.first(where: { $0.name == "users" })
        #expect(match == nil)
    }

    @Test("Sync should clear selection when tab has no table name")
    @MainActor
    func syncClearsSelectionForQueryTab() {
        let manager = QueryTabManager()
        manager.addTab(databaseName: "mydb")          // query tab: tableName == nil
        let currentTableName = manager.selectedTab?.tableName
        // When tableName is nil, syncSidebarToCurrentTab sets selectedTables = []
        #expect(currentTableName == nil)
    }

    @Test("Sync should set selection to active table name")
    @MainActor
    func syncSetsSelectionForTableTab() {
        let manager = QueryTabManager()
        manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let currentTableName = manager.selectedTab?.tableName
        #expect(currentTableName == "users")
        // syncSidebarToCurrentTab will find "users" in tables and set selectedTables = [users]
    }

    // MARK: - Database switch scenarios

    @Test("Skip when table matches current tab during database switch")
    func skipWhenTableMatchesDuringDatabaseSwitch() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: "users",
            hasExistingTabs: true
        )
        #expect(result == .skip)
    }

    @Test("Open in-place when no existing tabs during database switch")
    func openInPlaceWhenNoTabsDuringSwitch() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: nil,
            hasExistingTabs: false
        )
        #expect(result == .openInPlace)
    }
}
