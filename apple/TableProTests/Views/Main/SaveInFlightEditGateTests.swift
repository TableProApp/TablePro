//
//  SaveInFlightEditGateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// A landing save clears the tab's staged edits and reloads its rows, so an edit typed during the write was lost.
@MainActor
struct SaveInFlightEditGateTests {
    private func makeCoordinator() throws -> MainContentCoordinator {
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "shop", type: .postgresql),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        coordinator.openTableTab(TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public"))
        let index = try #require(coordinator.tabManager.selectedTabIndex)
        coordinator.tabManager.tabs[index].tableContext.isEditable = true
        coordinator.tabManager.tabs[index].display.resultsViewMode = .data
        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("open")]],
                columns: ["id", "status"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                hasAuthoritativeSchema: true
            ),
            for: coordinator.tabManager.tabs[index].id
        )
        coordinator.changeManager.configureForTable(
            tableName: "orders",
            columns: ["id", "status"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        return coordinator
    }

    @Test("The saving tab takes no edit until the save ends")
    func savingTabIsReadOnly() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.teardown() }
        let tabId = try #require(coordinator.tabManager.selectedTabId)
        #expect(coordinator.canEditActiveResult)

        #expect(coordinator.rowEditingCoordinator.beginSaveInFlight(tabId: tabId))
        #expect(!coordinator.canEditActiveResult)
        #expect(coordinator.isSavingSelectedTab)
        coordinator.deleteRows([.existing(0)])
        coordinator.stageInspectorFieldEdit(
            columnIndex: 1, value: .text("closed"), rowIDs: [.existing(0)], continuity: .discrete
        )
        #expect(!coordinator.changeManager.hasChanges)

        coordinator.rowEditingCoordinator.endSaveInFlight()
        #expect(coordinator.canEditActiveResult)
        #expect(!coordinator.isSavingSelectedTab)
    }

    @Test("A save running for another tab leaves this one editable")
    func otherTabStaysEditable() throws {
        let coordinator = try makeCoordinator()
        defer { coordinator.teardown() }

        #expect(coordinator.rowEditingCoordinator.beginSaveInFlight(tabId: UUID()))
        #expect(coordinator.canEditActiveResult)
        #expect(!coordinator.isSavingSelectedTab)
        coordinator.rowEditingCoordinator.endSaveInFlight()
    }
}
