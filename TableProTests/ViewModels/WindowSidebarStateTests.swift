//
//  WindowSidebarStateTests.swift
//  TableProTests
//
//  Pins per-window scoping of sidebar state. Regression guard for #1313 where
//  selectedTables was shared across windows of the same connection, causing
//  Cmd+T to jump focus back to a sibling window.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@MainActor
struct WindowSidebarStateTests {
    @Test
    func twoInstancesHoldIndependentSelection() {
        let windowA = WindowSidebarState()
        let windowB = WindowSidebarState()

        let users = TestFixtures.makeTableInfo(name: "users")
        windowA.selectedTables = [users]

        #expect(windowA.selectedTables == [users])
        #expect(windowB.selectedTables.isEmpty)
    }

    @Test
    func twoInstancesHoldIndependentSearchText() {
        let windowA = WindowSidebarState()
        let windowB = WindowSidebarState()

        windowA.searchText = "users"

        #expect(windowA.searchText == "users")
        #expect(windowB.searchText.isEmpty)
    }

    @Test
    func twoInstancesHoldIndependentFavoritesSearch() {
        let windowA = WindowSidebarState()
        let windowB = WindowSidebarState()

        windowA.favoritesSearchText = "daily"

        #expect(windowA.favoritesSearchText == "daily")
        #expect(windowB.favoritesSearchText.isEmpty)
    }
}
