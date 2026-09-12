//
//  UndoRowIdentityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
@Suite("Undo row identity")
struct UndoRowIdentityTests {
    private static let columns = ["id", "name"]

    private func makeTableRows() -> TableRows {
        TableRows.from(
            queryRows: [
                ["1", "keep"],
                ["2", "drop"],
                ["3", "keep"],
            ].map { $0.map { PluginCellValue.text($0) } },
            columns: Self.columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: 2)
        )
    }

    private func makeManager() -> RowOperationsManager {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "users",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .sqlite,
            generatedColumns: []
        )
        return RowOperationsManager(changeManager: changeManager)
    }

    private func cellEditUndo(rowID: RowID, previous: PluginCellValue) -> UndoResult {
        UndoResult(
            action: .cellEdit(
                rowID: rowID,
                columnIndex: 1,
                columnName: "name",
                previousValue: previous,
                newValue: "edited",
                originalRow: nil
            ),
            needsRowRemoval: false,
            needsRowRestore: false,
            restoreRow: nil
        )
    }

    @Test("Undoing a cell edit reverts the row that was edited")
    func undoRevertsTheEditedRow() {
        var tableRows = makeTableRows()
        tableRows.rows[2].values[1] = "edited"

        _ = makeManager().applyUndoResult(
            cellEditUndo(rowID: tableRows.rows[2].id, previous: "keep"),
            tableRows: &tableRows
        )

        #expect(tableRows.rows[2].values[1] == "keep")
        #expect(tableRows.rows[1].values[1] == "drop")
    }

    @Test("A row that is no longer loaded reverts nothing rather than the wrong row")
    func undoForAMissingRowIsANoOp() {
        var tableRows = makeTableRows()
        let before = tableRows.rows.map { $0.values }

        let result = makeManager().applyUndoResult(
            cellEditUndo(rowID: .existing(99), previous: "keep"),
            tableRows: &tableRows
        )

        #expect(result.delta == .none)
        #expect(tableRows.rows.map { $0.values } == before)
    }

    @Test("Undoing an insertion removes that row, and redoing it restores the same row")
    func insertionUndoRedoKeepsIdentity() {
        var tableRows = makeTableRows()
        let rowID = RowID.inserted(UUID())
        _ = tableRows.appendInsertedRow(id: rowID, values: ["4", "new"])
        let manager = makeManager()

        let removal = UndoResult(
            action: .rowInsertion(rowID: rowID), needsRowRemoval: true, needsRowRestore: false, restoreRow: nil
        )
        let removed = manager.applyUndoResult(removal, tableRows: &tableRows)

        #expect(tableRows.index(of: rowID) == nil)
        #expect(removed.delta == .rowsRemoved(IndexSet(integer: 3)))

        let restore = UndoResult(
            action: .rowInsertion(rowID: rowID), needsRowRemoval: false, needsRowRestore: true,
            restoreRow: ["4", "new"]
        )
        _ = manager.applyUndoResult(restore, tableRows: &tableRows)

        #expect(tableRows.index(of: rowID) == 3)
        #expect(tableRows.row(withID: rowID)?.values == ["4", "new"])
    }
}
