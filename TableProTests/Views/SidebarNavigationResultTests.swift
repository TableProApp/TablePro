//
//  SidebarNavigationResultTests.swift
//  TableProTests
//
//  Tests for SidebarNavigationResult — the pure decision logic that controls
//  whether a sidebar single-click replaces the focused window's active tab in
//  place or opens a new native tab.
//
//  The rule is window-local: a click reuses the active tab when it is reusable
//  (a preview tab or a blank query tab), opens the first tab in an empty window,
//  and otherwise opens a new tab. Tab count is never the deciding factor.
//

import Foundation
import TableProPluginKit
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
            hasExistingTabs: true,
            isActiveTabReusable: false
        )
        #expect(result == .skip)
    }

    @Test("Skip when clicked table matches active tab and no other tabs")
    func skipWhenTableMatchesCurrentTabNoOtherTabs() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: "orders",
            hasExistingTabs: false,
            isActiveTabReusable: false
        )
        #expect(result == .skip)
    }

    @Test("Skip is case-sensitive — different case is NOT a match")
    func skipIsCaseSensitive() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "Users",
            currentTabTableName: "users",
            hasExistingTabs: true,
            isActiveTabReusable: false
        )
        #expect(result != .skip)
    }

    // MARK: - .reuseActiveTab (empty window opens first tab in place)

    @Test("Reuse active tab when window is empty and no current tab")
    func reuseActiveTabWhenTabsEmpty() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "products",
            currentTabTableName: nil,
            hasExistingTabs: false,
            isActiveTabReusable: false
        )
        #expect(result == .reuseActiveTab)
    }

    @Test("Reuse active tab when window is empty even if a stale tab name is supplied")
    func reuseActiveTabWhenTabsEmptyWithCurrentTabName() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "products",
            currentTabTableName: "users",
            hasExistingTabs: false,
            isActiveTabReusable: false
        )
        #expect(result == .reuseActiveTab)
    }

    // MARK: - .reuseActiveTab (active tab is reusable)

    @Test("Reuse active tab when tabs exist and the active tab is reusable")
    func reuseActiveTabWhenReusable() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: "users",
            hasExistingTabs: true,
            isActiveTabReusable: true
        )
        #expect(result == .reuseActiveTab)
    }

    @Test("Reuse active tab when current tab is a reusable blank query tab (nil name)")
    func reuseActiveTabWhenReusableQueryTab() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: nil,
            hasExistingTabs: true,
            isActiveTabReusable: true
        )
        #expect(result == .reuseActiveTab)
    }

    // MARK: - .openNewTab (active tab is protected)

    @Test("Open new tab when tabs exist and the active tab is not reusable")
    func openNewTabWhenNotReusable() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "products",
            currentTabTableName: "users",
            hasExistingTabs: true,
            isActiveTabReusable: false
        )
        #expect(result == .openNewTab)
    }

    @Test("Open new tab when current tab is a non-reusable query tab")
    func openNewTabWhenQueryTabNotReusable() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: nil,
            hasExistingTabs: true,
            isActiveTabReusable: false
        )
        #expect(result == .openNewTab)
    }

    // MARK: - Invariants

    @Test("Never opens a new tab when the window is empty; always reuse in place")
    func emptyWindowNeverOpensNewTab() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: nil,
            hasExistingTabs: false,
            isActiveTabReusable: false
        )
        #expect(result != .openNewTab)
        #expect(result == .reuseActiveTab)
    }

    @Test("A protected active tab is never silently replaced")
    func protectedTabNeverReused() {
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: "users",
            hasExistingTabs: true,
            isActiveTabReusable: false
        )
        #expect(result != .reuseActiveTab)
        #expect(result == .openNewTab)
    }

    // MARK: - QueryTabManager integration

    @Test("Resolves to reuseActiveTab for a fresh QueryTabManager with no tabs")
    @MainActor
    func resolveWithFreshTabManager() {
        let manager = QueryTabManager()
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: manager.selectedTab?.tableContext.tableName,
            hasExistingTabs: !manager.tabs.isEmpty,
            isActiveTabReusable: false
        )
        #expect(result == .reuseActiveTab)
    }

    @Test("Resolves to skip when clicking the active table in QueryTabManager")
    @MainActor
    func resolveSkipWithActiveTableInTabManager() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "users",
            currentTabTableName: manager.selectedTab?.tableContext.tableName,
            hasExistingTabs: !manager.tabs.isEmpty,
            isActiveTabReusable: false
        )
        #expect(result == .skip)
    }

    @Test("Resolves to openNewTab when clicking a different table while the active tab is protected")
    @MainActor
    func resolveNewTabWhenActiveTabProtected() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: manager.selectedTab?.tableContext.tableName,
            hasExistingTabs: !manager.tabs.isEmpty,
            isActiveTabReusable: false
        )
        #expect(result == .openNewTab)
    }

    @Test("Resolves to reuseActiveTab when clicking a different table while the active tab is a preview")
    @MainActor
    func resolveReuseWhenActiveTabIsPreview() throws {
        let manager = QueryTabManager()
        try manager.addPreviewTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let result = SidebarNavigationResult.resolve(
            clickedTableName: "orders",
            currentTabTableName: manager.selectedTab?.tableContext.tableName,
            hasExistingTabs: !manager.tabs.isEmpty,
            isActiveTabReusable: true
        )
        #expect(result == .reuseActiveTab)
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

    @Test("Sync should set selection to active table name")
    @MainActor
    func syncSetsSelectionForTableTab() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "mydb")
        let currentTableName = manager.selectedTab?.tableContext.tableName
        #expect(currentTableName == "users")
    }
}
