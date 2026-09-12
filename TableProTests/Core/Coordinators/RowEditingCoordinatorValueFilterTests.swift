//
//  RowEditingCoordinatorValueFilterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("RowEditingCoordinator under a value filter")
@MainActor
struct RowEditingCoordinatorValueFilterTests {
    private func makeCoordinator() -> MainContentCoordinator {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        tab.execution.lastExecutedAt = Date()
        tab.display.resultsViewMode = .data
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [
                    [.text("1"), .text("Alice")],
                    [.text("2"), .text("Bob")],
                    [.text("3"), .text("Cleo")],
                    [.text("4"), .text("Bob")]
                ],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                hasAuthoritativeSchema: true
            ),
            for: tab.id
        )
        coordinator.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )

        var filter = GridValueFilterState()
        filter.set(
            ColumnValueFilter(selectedValues: ["Bob"], includesNull: false),
            columnName: "name",
            forColumn: 1
        )
        coordinator.setValueFilter(filter, forTab: tab.id)
        return coordinator
    }

    private func tableRows(of coordinator: MainContentCoordinator) -> TableRows {
        guard let tabId = coordinator.tabManager.selectedTab?.id else { return TableRows() }
        return coordinator.tabSessionRegistry.tableRows(for: tabId)
    }

    @Test("The filter shows the two Bobs, so display positions are not storage indices")
    func filterNarrowsTheDisplay() {
        let coordinator = makeCoordinator()

        #expect(coordinator.activeGridDisplayIDs == [.existing(1), .existing(3)])
    }

    @Test("Deleting the second shown row marks id 4, and the DELETE names id 4")
    func deleteMarksTheShownRow() throws {
        let coordinator = makeCoordinator()

        coordinator.deleteSelectedRows(indices: [1])

        #expect(coordinator.changeManager.isRowDeleted(.existing(3)))
        #expect(!coordinator.changeManager.isRowDeleted(.existing(1)))
        let statements = try coordinator.changeManager.generateSQL()
        #expect(statements.count == 1)
        #expect(statements.first?.parameters.first.flatMap { $0 as? String } == "4")
    }

    @Test("A new row is selected at the position the filter shows it")
    func addRowSelectsItsDisplayPosition() {
        let coordinator = makeCoordinator()

        coordinator.addNewRow()

        let displayIDs = coordinator.activeGridDisplayIDs ?? []
        #expect(displayIDs.count == 3)
        #expect(displayIDs.last?.isInserted == true)
        #expect(coordinator.selectionState.indices == [2])
    }

    @Test("A duplicated row is selected at the position the filter shows it")
    func duplicateSelectsItsDisplayPosition() {
        let coordinator = makeCoordinator()

        coordinator.duplicateSelectedRow(index: 1)

        let rows = tableRows(of: coordinator)
        #expect(rows.count == 5)
        #expect(rows.rows.last?.values[1] == "Bob")
        #expect(coordinator.selectionState.indices == [2])
    }

    @Test("Discard puts back the row that was edited, not the one at the same storage offset")
    func discardRestoresTheEditedRow() {
        let coordinator = makeCoordinator()
        guard let tabId = coordinator.tabManager.selectedTab?.id else {
            Issue.record("No selected tab")
            return
        }
        coordinator.changeManager.recordCellChange(
            rowID: .existing(3),
            columnIndex: 1,
            columnName: "name",
            oldValue: "Bob",
            newValue: "Robert",
            originalRow: ["4", "Bob"]
        )
        coordinator.mutateActiveTableRows(for: tabId) { rows in
            rows.edit(row: 3, column: 1, value: "Robert")
        }

        coordinator.rowEditingCoordinator.restoreRowBufferToOriginals()

        let rows = tableRows(of: coordinator)
        #expect(rows.rows[3].values[1] == "Bob")
        #expect(rows.rows[1].values[1] == "Bob")
        #expect(rows.rows[2].values[1] == "Cleo")
    }

    @Test("Discard removes rows added under the filter")
    func discardRemovesInsertedRows() {
        let coordinator = makeCoordinator()
        coordinator.addNewRow()
        #expect(tableRows(of: coordinator).count == 5)

        coordinator.rowEditingCoordinator.restoreRowBufferToOriginals()

        let rows = tableRows(of: coordinator)
        #expect(rows.count == 4)
        #expect(!rows.rows.contains { $0.id.isInserted })
    }
}
