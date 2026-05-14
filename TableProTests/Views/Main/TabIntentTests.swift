//
//  TabIntentTests.swift
//  TableProTests
//
//  Covers MainContentCoordinator+TabIntent: addNewQueryTab and closeCurrentTab.
//  handleNewTabIntent payload routing is covered in SessionStateFactoryTests.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MainContentCoordinator addNewQueryTab")
@MainActor
struct AddNewQueryTabTests {
    @Test("adds a query tab and selects it")
    func addsAndSelects() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)
        defer { state.coordinator.teardown() }

        state.coordinator.addNewQueryTab()

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.tabType == .query)
        #expect(state.tabManager.selectedTabId == state.tabManager.tabs.first?.id)
    }

    @Test("carries the initial query into the new tab")
    func carriesInitialQuery() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)
        defer { state.coordinator.teardown() }

        state.coordinator.addNewQueryTab(initialQuery: "SELECT 1")

        #expect(state.tabManager.tabs.first?.content.query == "SELECT 1")
    }

    @Test("adding multiple tabs produces distinct Query N titles")
    func multipleTabsDistinctTitles() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)
        defer { state.coordinator.teardown() }

        state.coordinator.addNewQueryTab()
        state.coordinator.addNewQueryTab()

        #expect(state.tabManager.tabs.count == 2)
        let titles = Set(state.tabManager.tabs.map(\.title))
        #expect(titles.count == 2)
    }
}

@Suite("MainContentCoordinator closeCurrentTab")
@MainActor
struct CloseCurrentTabTests {
    @Test("removes the selected tab when more than one is open")
    func removesSelectedTab() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)
        defer { state.coordinator.teardown() }
        state.coordinator.addNewQueryTab()
        state.coordinator.addNewQueryTab()
        let firstId = state.tabManager.tabs[0].id
        let secondId = state.tabManager.tabs[1].id
        state.tabManager.selectedTabId = secondId

        state.coordinator.closeCurrentTab()

        #expect(state.tabManager.tabs.count == 1)
        #expect(state.tabManager.tabs.first?.id == firstId)
        #expect(state.tabManager.selectedTabId == firstId)
    }

    @Test("closing the only tab leaves the tab in place (window-close path)")
    func closingOnlyTabKeepsTab() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)
        defer { state.coordinator.teardown() }
        state.coordinator.addNewQueryTab()

        // contentWindow is nil in tests, so the last-tab branch is a safe no-op.
        state.coordinator.closeCurrentTab()

        #expect(state.tabManager.tabs.count == 1)
    }

    @Test("closing with no selection is a safe no-op")
    func closingWithNoSelectionIsNoOp() {
        let conn = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: conn)
        defer { state.coordinator.teardown() }

        state.coordinator.closeCurrentTab()

        #expect(state.tabManager.tabs.isEmpty)
    }
}
