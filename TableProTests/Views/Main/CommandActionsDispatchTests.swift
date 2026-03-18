//
//  CommandActionsDispatchTests.swift
//  TableProTests
//
//  Tests that MainContentCommandActions correctly forwards calls
//  to MainContentCoordinator and its sub-handlers.
//

import Foundation
import SwiftUI
import Testing
@testable import TablePro

@MainActor @Suite("CommandActions Dispatch")
struct CommandActionsDispatchTests {
    // MARK: - Helpers

    private func makeSUT() -> (MainContentCommandActions, MainContentCoordinator) {
        let connection = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        let coordinator = state.coordinator

        var selectedRowIndices: Set<Int> = []
        var selectedTables: Set<TableInfo> = []
        var pendingTruncates: Set<String> = []
        var pendingDeletes: Set<String> = []
        var tableOperationOptions: [String: TableOperationOptions] = [:]
        var editingCell: CellPosition? = nil
        let rightPanelState = RightPanelState()

        let actions = MainContentCommandActions(
            coordinator: coordinator,
            filterStateManager: state.filterStateManager,
            connection: connection,
            selectedRowIndices: Binding(get: { selectedRowIndices }, set: { selectedRowIndices = $0 }),
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(
                get: { tableOperationOptions },
                set: { tableOperationOptions = $0 }
            ),
            rightPanelState: rightPanelState,
            editingCell: Binding(get: { editingCell }, set: { editingCell = $0 })
        )

        return (actions, coordinator)
    }

    // MARK: - loadQueryIntoEditor

    @Test("loadQueryIntoEditor forwards query to coordinator and updates tab")
    func loadQueryIntoEditor_forwardsToCoordinator() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")

        actions.loadQueryIntoEditor("SELECT 1")

        let tab = coordinator.tabManager.selectedTab
        #expect(tab?.query == "SELECT 1")
    }

    // MARK: - insertQueryFromAI

    @Test("insertQueryFromAI forwards query to coordinator and updates tab")
    func insertQueryFromAI_forwardsToCoordinator() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")

        actions.insertQueryFromAI("SELECT 2")

        let tab = coordinator.tabManager.selectedTab
        #expect(tab?.query == "SELECT 2")
    }

    @Test("insertQueryFromAI appends to existing query")
    func insertQueryFromAI_appendsToExisting() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")

        // Set an initial query on the tab
        if let idx = coordinator.tabManager.selectedTabIndex {
            coordinator.tabManager.tabs[idx].query = "SELECT 1"
        }

        actions.insertQueryFromAI("SELECT 2")

        let tab = coordinator.tabManager.selectedTab
        #expect(tab?.query == "SELECT 1\n\nSELECT 2")
    }

    // MARK: - copySelectedRows (structure mode)

    @Test("copySelectedRows in structure mode calls structureActions.copyRows")
    func copySelectedRows_structureMode_callsStructureActions() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")

        // Enable structure mode on the selected tab
        if let idx = coordinator.tabManager.selectedTabIndex {
            coordinator.tabManager.tabs[idx].showStructure = true
        }

        // Install a spy handler
        let handler = StructureViewActionHandler()
        var copyRowsCalled = false
        handler.copyRows = { copyRowsCalled = true }
        coordinator.structureActions = handler

        actions.copySelectedRows()

        #expect(copyRowsCalled)
    }

    // MARK: - pasteRows (structure mode)

    @Test("pasteRows in structure mode calls structureActions.pasteRows")
    func pasteRows_structureMode_callsStructureActions() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")

        // Enable structure mode on the selected tab
        if let idx = coordinator.tabManager.selectedTabIndex {
            coordinator.tabManager.tabs[idx].showStructure = true
        }

        // Install a spy handler
        let handler = StructureViewActionHandler()
        var pasteRowsCalled = false
        handler.pasteRows = { pasteRowsCalled = true }
        coordinator.structureActions = handler

        actions.pasteRows()

        #expect(pasteRowsCalled)
    }
}
