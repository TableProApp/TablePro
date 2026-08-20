//
//  MainContentCoordinatorAddRowTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
import Testing

@testable import TablePro

@Suite("MainContentCoordinator add row")
@MainActor
struct MainContentCoordinatorAddRowTests {
    private func makeCoordinator(
        viewMode: ResultsViewMode = .data,
        tableName: String? = "users",
        isEditable: Bool = true,
        isView: Bool = false
    ) -> MainContentCoordinator {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table)
        tab.tableContext.tableName = tableName
        tab.tableContext.isEditable = isEditable
        tab.tableContext.isView = isView
        tab.display.resultsViewMode = viewMode
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return coordinator
    }

    /// `addNewRow()` resolves its target through `GridSelectionOwner`, which answers `.none` in
    /// Chart mode and `.schemaGrid` in Structure mode. Offering the command outside Data mode makes
    /// it either inert or a column insert wearing a row's name.
    @Test("Only the data grid takes a row")
    func addRowFollowsTheResultMode() {
        #expect(makeCoordinator(viewMode: .data).canAddRow)
        #expect(!makeCoordinator(viewMode: .structure).canAddRow)
        #expect(!makeCoordinator(viewMode: .json).canAddRow)
        #expect(!makeCoordinator(viewMode: .chart).canAddRow)
    }

    @Test("A row needs somewhere to go and permission to get there")
    func addRowNeedsAnEditableTable() {
        #expect(!makeCoordinator(tableName: nil).canAddRow)
        #expect(!makeCoordinator(isEditable: false).canAddRow)
        #expect(!makeCoordinator(isView: true).canAddRow)
    }
}

@Suite("MainContentCommandActions result view")
@MainActor
struct MainContentCommandActionsResultViewTests {
    private func makeActions(
        tabType: TabType = .table,
        tableName: String? = "users"
    ) -> (MainContentCommandActions, MainContentCoordinator, UUID) {
        let connection = TestFixtures.makeConnection()
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        let coordinator = state.coordinator

        var selectedTables: Set<TableInfo> = []
        var pendingTruncates: Set<String> = []
        var pendingDeletes: Set<String> = []
        var tableOperationOptions: [String: TableOperationOptions] = [:]

        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectionState: coordinator.selectionState,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(
                get: { tableOperationOptions },
                set: { tableOperationOptions = $0 }
            ),
            rightPanelState: RightPanelState()
        )

        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: tabType)
        tab.tableContext.tableName = tableName
        coordinator.tabManager.tabs.append(tab)
        coordinator.tabManager.selectedTabId = tab.id
        return (actions, coordinator, tab.id)
    }

    private func mode(_ coordinator: MainContentCoordinator, _ tabId: UUID) -> ResultsViewMode? {
        coordinator.tabManager.tabs.first { $0.id == tabId }?.display.resultsViewMode
    }

    @Test("View > Result View switches the selected tab")
    func setsTheSelectedTabsMode() {
        let (actions, coordinator, tabId) = makeActions()
        actions.setResultsViewMode(.json)
        #expect(mode(coordinator, tabId) == .json)
    }

    /// The menu lists every mode, so the command has to refuse the ones this tab cannot show rather
    /// than leaving it on a mode with nothing to render.
    @Test("A mode the tab does not offer is refused")
    func refusesAnUnavailableMode() {
        let (actions, coordinator, tabId) = makeActions(tabType: .query, tableName: nil)
        #expect(!actions.availableResultsViewModes.contains(.structure))
        actions.setResultsViewMode(.structure)
        #expect(mode(coordinator, tabId) == .data)
    }

    @Test("A table tab offers structure")
    func availableModesFollowTheTab() {
        let (actions, _, _) = makeActions()
        #expect(actions.availableResultsViewModes == [.data, .structure, .json, .chart])
    }
}
