//
//  CoordinatorShowAIChatTests.swift
//  TableProTests
//
//  Tests for MainContentCoordinator.showAIChatPanel()
//

import Testing

@testable import TablePro

@Suite("showAIChatPanel")
struct CoordinatorShowAIChatTests {
    @Test("Sets rightPanelState.isPresented to true")
    @MainActor
    func setsIsPresentedTrue() {
        let connection = TestFixtures.makeConnection()
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        let panelState = RightPanelState()
        // Force initial state to false regardless of persisted UserDefaults
        panelState.isPresented = false
        coordinator.rightPanelState = panelState

        coordinator.showAIChatPanel()

        #expect(panelState.isPresented == true)
    }

    @Test("Sets rightPanelState.activeTab to aiChat")
    @MainActor
    func setsActiveTabToAiChat() {
        let connection = TestFixtures.makeConnection()
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        let panelState = RightPanelState()
        coordinator.rightPanelState = panelState

        #expect(panelState.activeTab == .details)

        coordinator.showAIChatPanel()

        #expect(panelState.activeTab == .aiChat)
    }

    @Test("Does not crash when rightPanelState is nil")
    @MainActor
    func safeWhenRightPanelStateIsNil() {
        let connection = TestFixtures.makeConnection()
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let filterStateManager = FilterStateManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            filterStateManager: filterStateManager,
            columnVisibilityManager: ColumnVisibilityManager(),
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        #expect(coordinator.rightPanelState == nil)

        coordinator.showAIChatPanel()
    }
}
