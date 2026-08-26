//
//  UndoRowIndexTests.swift
//  TableProTests
//
//  A cell edit is tracked by its display row, the same as the modified marks the grid draws, but
//  TableRows is indexed by storage position. Undo used to write straight through with the display
//  number, so with a value filter narrowing the grid it reverted whichever row happened to sit at
//  that storage offset.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
@Suite("Undo row indices")
struct UndoRowIndexTests {
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
            databaseType: .sqlite
        )
        return RowOperationsManager(changeManager: changeManager)
    }

    private func cellEditUndo(displayRow: Int, previous: PluginCellValue) -> UndoResult {
        UndoResult(
            action: .cellEdit(
                rowIndex: displayRow,
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

    /// Display 1 is storage 2 once the middle row is filtered out.
    @Test("Undoing a cell edit under a value filter reverts the row that was edited")
    func undoResolvesThroughTheFilter() {
        var tableRows = makeTableRows()
        let displayIDs = [tableRows.rows[0].id, tableRows.rows[2].id]
        tableRows.rows[2].values[1] = "edited"

        _ = makeManager().applyUndoResult(
            cellEditUndo(displayRow: 1, previous: "keep"),
            displayIDs: displayIDs,
            tableRows: &tableRows
        )

        #expect(tableRows.rows[2].values[1] == "keep")
        #expect(tableRows.rows[1].values[1] == "drop")
    }

    @Test("With no filter the display row is the storage row, and nothing changes")
    func undoWithoutFilterIsUnchanged() {
        var tableRows = makeTableRows()
        tableRows.rows[1].values[1] = "edited"

        _ = makeManager().applyUndoResult(
            cellEditUndo(displayRow: 1, previous: "drop"),
            displayIDs: nil,
            tableRows: &tableRows
        )

        #expect(tableRows.rows[1].values[1] == "drop")
    }

    @Test("A display row the filter no longer shows reverts nothing rather than the wrong row")
    func undoForAHiddenRowIsANoOp() {
        var tableRows = makeTableRows()
        let displayIDs = [tableRows.rows[0].id]
        let before = tableRows.rows.map { $0.values }

        let result = makeManager().applyUndoResult(
            cellEditUndo(displayRow: 5, previous: "keep"),
            displayIDs: displayIDs,
            tableRows: &tableRows
        )

        #expect(result.delta == .none)
        #expect(tableRows.rows.map { $0.values } == before)
    }
}
