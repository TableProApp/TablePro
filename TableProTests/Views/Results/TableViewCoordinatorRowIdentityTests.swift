//
//  TableViewCoordinatorRowIdentityTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class NoopRowIdentityLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class RowStore {
    var tableRows: TableRows

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }
}

@Suite("TableViewCoordinator row identity")
@MainActor
struct TableViewCoordinatorRowIdentityTests {
    private func makeManager() -> DataChangeManager {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "status"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        return manager
    }

    private func makeCoordinator(manager: DataChangeManager) -> (TableViewCoordinator, RowStore) {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(manager),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopRowIdentityLayoutPersister()
        )
        let store = RowStore(TableRows.from(
            queryRows: [
                [.text("1"), .text("active")],
                [.text("2"), .text("inactive")],
                [.text("3"), .text("active")],
                [.text("4"), .text("inactive")]
            ],
            columns: ["id", "status"],
            columnTypes: [.text(rawType: nil), .text(rawType: nil)]
        ))
        coordinator.tableRowsProvider = { store.tableRows }
        coordinator.tableRowsMutator = { mutation in mutation(&store.tableRows) }
        coordinator.updateCache()
        return (coordinator, store)
    }

    private func filterToInactive(_ coordinator: TableViewCoordinator) {
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["inactive"], includesNull: false),
            columnName: "status",
            forColumn: 1
        )
    }

    @Test("An edit under a value filter is recorded on the row shown, and only that row changes")
    func editUnderFilterLandsOnTheShownRow() throws {
        let manager = makeManager()
        let (coordinator, store) = makeCoordinator(manager: manager)
        filterToInactive(coordinator)
        #expect(coordinator.displayIDs == [.existing(1), .existing(3)])

        coordinator.recordCellEdit(row: 1, columnIndex: 1, newValue: .text("archived"))

        #expect(manager.isCellModified(rowID: .existing(3), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(1), columnIndex: 1))
        #expect(store.tableRows.rows[3].values[1] == "archived")
        #expect(store.tableRows.rows[1].values[1] == "inactive")

        let statements = try manager.generateSQL()
        let parameters = statements.first?.parameters ?? []
        #expect(statements.count == 1)
        #expect(parameters.count == 2)
        #expect(parameters.last.flatMap { $0 as? String } == "4")
    }

    @Test("An edit keeps its row when the filter is cleared and positions move")
    func editFollowsItsRowAcrossADisplayOrderChange() {
        let manager = makeManager()
        let (coordinator, _) = makeCoordinator(manager: manager)
        filterToInactive(coordinator)

        coordinator.recordCellEdit(row: 0, columnIndex: 1, newValue: .text("archived"))
        coordinator.clearAllValueFilters()

        #expect(coordinator.displayIDs == nil)
        #expect(coordinator.visualState(for: 1).modifiedColumns == [1])
        #expect(coordinator.visualState(for: 0).modifiedColumns.isEmpty)
    }

    @Test("Undoing an edit made under a value filter reverts the row that was edited")
    func undoUnderFilterRevertsTheEditedRow() {
        let manager = makeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        let (coordinator, store) = makeCoordinator(manager: manager)
        filterToInactive(coordinator)

        coordinator.recordCellEdit(row: 1, columnIndex: 0, newValue: .text("9"))
        #expect(store.tableRows.rows[3].values[0] == "9")

        undoManager.undo()
        guard let captured else {
            Issue.record("The undo produced no result")
            return
        }
        _ = RowOperationsManager(changeManager: manager).applyUndoResult(captured, tableRows: &store.tableRows)

        #expect(store.tableRows.rows[3].values[0] == "4")
        #expect(store.tableRows.rows[1].values[0] == "2")
        #expect(!manager.isCellModified(rowID: .existing(3), columnIndex: 0))
    }

    @Test("A deleted row is recognised at whatever position the filter shows it")
    func deletedRowIsFoundByIdentity() {
        let manager = makeManager()
        let (coordinator, _) = makeCoordinator(manager: manager)
        manager.recordRowDeletion(rowID: .existing(3), originalRow: ["4", "inactive"])
        filterToInactive(coordinator)

        #expect(coordinator.isRowDeleted(displayRow: 1))
        #expect(!coordinator.isRowDeleted(displayRow: 0))
        #expect(coordinator.visualState(for: 1).isDeleted)
    }

    @Test("Fill Column under a filter writes the shown rows and skips a deleted one")
    func fillColumnUnderFilterTargetsShownRows() {
        let manager = makeManager()
        let (coordinator, _) = makeCoordinator(manager: manager)
        filterToInactive(coordinator)
        manager.recordRowDeletion(rowID: .existing(3), originalRow: ["4", "inactive"])

        coordinator.applyFillColumn(columnIndex: 1, value: .text("gone"))

        #expect(manager.isCellModified(rowID: .existing(1), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(3), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(2), columnIndex: 1))
    }

    @Test("Undo Delete from the row menu clears the row shown at that position")
    func undoDeleteUnderFilterClearsTheShownRow() {
        let manager = makeManager()
        let (coordinator, _) = makeCoordinator(manager: manager)
        manager.recordRowDeletion(rowID: .existing(1), originalRow: ["2", "inactive"])
        manager.recordRowDeletion(rowID: .existing(3), originalRow: ["4", "inactive"])
        filterToInactive(coordinator)

        coordinator.undoDeleteRow(at: 1)

        #expect(!manager.isRowDeleted(.existing(3)))
        #expect(manager.isRowDeleted(.existing(1)))
    }
}
