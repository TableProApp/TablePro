//
//  ComparisonGridCopyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct ComparisonGridCopyTests {
        // Copy Rows over the first line, the way Command-C copies a selected row of either comparison.
        private func copyFirstRow(of model: DataGridModel) {
            let lastColumn = model.columns.count - 1
            model.setSelection(GridSelection(
                rectangles: [GridRect(rows: 0...0, columns: 0...lastColumn)],
                activeCell: GridCoord(row: 0, displayColumn: 0),
                anchor: GridCoord(row: 0, displayColumn: 0)
            ))
            DataGridCommands(model: model).copy(.current(model.selection))
        }

        @Test("Copying a result comparison row puts the line on the clipboard")
        func resultComparisonCopiesRows() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let side = ResultComparisonSide(
                title: "Result",
                detail: "Query",
                columns: ["id"],
                rows: [Row(id: .existing(0), values: [.text("7")])]
            )
            let pairing = ResultColumnPairing(left: side.columns, right: side.columns)
            let lines = ResultComparisonGridModel.lines(for: [ResultComparisonEntry(kind: .onlyLeft, leftRow: 0, rightRow: nil)])
            let comparison = ResultComparisonGridModel()
            comparison.grid.setRows(ResultComparisonGridModel.tableRows(for: lines, left: side, right: side, pairing: pairing))

            copyFirstRow(of: comparison.model)

            #expect(clipboard.text == "Only Left\tLeft\t7")
        }

        @Test("Copying a Compare & Sync row puts the line on the clipboard")
        func compareSyncCopiesRows() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let compare = CompareRowGridModel()
            compare.grid.setRows(TableRows.from(
                queryRows: [[.text("Insert"), .text("Source"), .text("7")]],
                columns: ["Change", "Side", "id"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil), .integer(rawType: nil)]
            ))

            copyFirstRow(of: compare.model)

            #expect(clipboard.text == "Insert\tSource\t7")
        }
    }
}
