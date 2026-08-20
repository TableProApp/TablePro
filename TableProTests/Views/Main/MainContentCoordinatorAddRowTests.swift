//
//  MainContentCoordinatorAddRowTests.swift
//  TableProTests
//

import Foundation
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
