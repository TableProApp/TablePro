//
//  WindowSidebarStateTests.swift
//  TableProTests
//
//  Pins per-window scoping of table selection. Regression guard for #1313 where
//  selectedTables was shared across windows of the same connection, causing
//  Cmd+T to jump focus back to a sibling window. Sidebar filter text is
//  connection-scoped and lives in SharedSidebarState; see SharedSidebarStateTests.
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
}
