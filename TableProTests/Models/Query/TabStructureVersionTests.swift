//
//  TabStructureVersionTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("QueryTabManager.tabStructureVersion")
@MainActor
struct TabStructureVersionTests {

    @Test("New manager starts at version 0")
    func initialVersionIsZero() {
        let manager = QueryTabManager()
        #expect(manager.tabStructureVersion == 0)
    }

    @Test("addTab(...) bumps the version once")
    func addTabBumpsOnce() {
        let manager = QueryTabManager()
        let before = manager.tabStructureVersion

        manager.addTab(initialQuery: "SELECT 1", title: "Q")

        #expect(manager.tabStructureVersion == before + 1)
    }

    @Test("addTableTab(...) for a new table bumps once; activating an existing table does NOT bump")
    func addTableTabBumpsOnceAndIdempotent() throws {
        let manager = QueryTabManager()

        try manager.addTableTab(tableName: "users")
        let afterFirstAdd = manager.tabStructureVersion
        #expect(afterFirstAdd == 1)

        try manager.addTableTab(tableName: "users")

        #expect(manager.tabStructureVersion == afterFirstAdd)
    }

    @Test("addTerminalTab(...) for a new tab bumps once; activating existing terminal does NOT bump")
    func addTerminalTabBumpsOnceAndIdempotent() {
        let manager = QueryTabManager()

        manager.addTerminalTab()
        let afterFirstAdd = manager.tabStructureVersion
        #expect(afterFirstAdd == 1)

        manager.addTerminalTab()

        #expect(manager.tabStructureVersion == afterFirstAdd)
    }

    @Test("addServerDashboardTab() for a new tab bumps once; activating existing does NOT bump")
    func addServerDashboardBumpsOnceAndIdempotent() {
        let manager = QueryTabManager()

        manager.addServerDashboardTab()
        let afterFirstAdd = manager.tabStructureVersion
        #expect(afterFirstAdd == 1)

        manager.addServerDashboardTab()

        #expect(manager.tabStructureVersion == afterFirstAdd)
    }

    @Test("replaceTabContent(...) bumps the version (in-place mutation, same id)")
    func replaceTabContentBumps() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        let beforeReplace = manager.tabStructureVersion

        let didReplace = try manager.replaceTabContent(tableName: "orders")

        #expect(didReplace)
        #expect(manager.tabStructureVersion == beforeReplace + 1)
    }

    @Test("markTabRenamed bumps when the tab id exists; no-op when it does not")
    func markTabRenamedBumpsOnlyForKnownIds() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        let knownId = manager.tabs[0].id
        let before = manager.tabStructureVersion

        manager.markTabRenamed(knownId)
        #expect(manager.tabStructureVersion == before + 1)

        let unknownVersion = manager.tabStructureVersion
        manager.markTabRenamed(UUID())
        #expect(manager.tabStructureVersion == unknownVersion)
    }

    @Test("updateTab(...) does NOT bump the version (content-only update)")
    func updateTabDoesNotBump() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        var tab = manager.tabs[0]
        let before = manager.tabStructureVersion

        tab.content.query = "SELECT 99"
        manager.updateTab(tab)

        #expect(manager.tabStructureVersion == before)
    }

    @Test("Mutating a tab's content directly via tabs[i] does NOT bump (id array unchanged)")
    func directContentMutationDoesNotBump() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        let before = manager.tabStructureVersion

        manager.tabs[0].content.query = "SELECT * FROM users WHERE id = 1"

        #expect(manager.tabStructureVersion == before)
    }

    @Test("Removing a tab via tabs.remove(at:) bumps via the didSet")
    func tabsRemovalBumps() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        try manager.addTableTab(tableName: "orders")
        let before = manager.tabStructureVersion

        manager.tabs.remove(at: 0)

        #expect(manager.tabStructureVersion == before + 1)
    }

    @Test("Drag-reordering tabs (id array reordered) bumps via the didSet")
    func tabsReorderBumps() throws {
        let manager = QueryTabManager()
        try manager.addTableTab(tableName: "users")
        try manager.addTableTab(tableName: "orders")
        try manager.addTableTab(tableName: "products")
        let before = manager.tabStructureVersion

        manager.tabs.swapAt(0, 2)

        #expect(manager.tabStructureVersion == before + 1)
    }
}
