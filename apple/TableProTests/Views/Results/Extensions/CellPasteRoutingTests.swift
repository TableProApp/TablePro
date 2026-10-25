// Paste leaves a clipboard holding whole rows to row paste: with the grid's row tag, or TSV as wide as the result.
// Without that, Command-V on a cell after copying a row would overwrite the row's tail columns.

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct CellPasteRoutingTests {
        private static let gridRowsTag = GridRowsClipboardPayload(columns: ["a"], rows: [[.text("anything")]])

        private func makeGrid(columns: [String], rowCount: Int, isEditable: Bool = true) -> CommandGrid {
            let rows = (0..<rowCount).map { row in (0..<columns.count).map { PluginCellValue.text("r\(row)c\($0)") } }
            let grid = CommandGrid(
                TableRows.from(
                    queryRows: rows,
                    columns: columns,
                    columnTypes: Array(repeating: .text(rawType: nil), count: columns.count)
                ),
                configuration: isEditable ? CommandGrid.editable() : CommandGrid.readOnly()
            )
            grid.owner.pastesRows = true
            return grid
        }

        private func paste(into grid: CommandGrid, row: Int, column: Int) {
            grid.selectCell(row, column)
            grid.controller.paste(nil)
        }

        @Test("Defers to row paste when the clipboard carries the grid's row tag")
        func defersOnGridRowsTag() throws {
            let clipboard = try #require(RecordingClipboard.current)
            clipboard.text = "anything\twith\ttabs"
            clipboard.gridRows = Self.gridRowsTag
            let grid = makeGrid(columns: ["a", "b", "c"], rowCount: 5)

            paste(into: grid, row: 0, column: 0)

            #expect(grid.owner.commits.isEmpty)
            #expect(grid.owner.rowPastes == 1)
        }

        @Test("Defers to row paste when every TSV line matches the column count")
        func defersOnRowShapedTSV() throws {
            try #require(RecordingClipboard.current).text = "x\ty\tz\nq\tw\te"
            let grid = makeGrid(columns: ["a", "b", "c"], rowCount: 5)

            paste(into: grid, row: 0, column: 0)

            #expect(grid.owner.commits.isEmpty)
            #expect(grid.owner.rowPastes == 1)
        }

        @Test("A block narrower than the result fills rightwards from the cursor in one step")
        func cellPastesShapeMismatchedTSV() throws {
            try #require(RecordingClipboard.current).text = "x\ty"
            let grid = makeGrid(columns: ["a", "b", "c", "d", "e"], rowCount: 5)

            paste(into: grid, row: 0, column: 1)

            #expect(grid.owner.commits.count == 1)
            #expect(grid.owner.commits.first?.actionName == String(localized: "Paste Cells"))
            #expect(grid.owner.staged(0, 1)?.value == .text("x"))
            #expect(grid.owner.staged(0, 2)?.value == .text("y"))
            #expect(grid.owner.rowPastes == 0)
        }

        // #2172: a one-value clipboard has to fill the cell rather than append a row.
        @Test("A single copied value pastes into the cursor's cell")
        func cellPastesSingleValue() throws {
            try #require(RecordingClipboard.current).text = "hello"
            let grid = makeGrid(columns: ["a", "b", "c"], rowCount: 5)
            grid.selectCell(2, 1)

            #expect(grid.commands.canPaste(.current(grid.model.selection)))
            grid.controller.paste(nil)

            #expect(grid.owner.staged(2, 1)?.value == .text("hello"))
        }

        @Test("A single value still defers to row paste when the clipboard carries the row tag")
        func singleValueDefersOnGridRowsTag() throws {
            let clipboard = try #require(RecordingClipboard.current)
            clipboard.text = "hello"
            clipboard.gridRows = Self.gridRowsTag
            let grid = makeGrid(columns: ["a", "b", "c"], rowCount: 5)

            paste(into: grid, row: 2, column: 1)

            #expect(grid.owner.commits.isEmpty)
            #expect(grid.owner.rowPastes == 1)
        }

        @Test("A single value fills the cell even in a one-column table, where it looks row-shaped")
        func singleValueInSingleColumnTable() throws {
            try #require(RecordingClipboard.current).text = "hello"
            let grid = makeGrid(columns: ["a"], rowCount: 3)

            paste(into: grid, row: 1, column: 0)

            #expect(grid.owner.staged(1, 0)?.value == .text("hello"))
        }

        @Test("Validation agrees with the paste and writes nothing")
        func canPasteAgreesAndDoesNotMutate() throws {
            try #require(RecordingClipboard.current).text = "x\ty"
            let grid = makeGrid(columns: ["a", "b", "c", "d", "e"], rowCount: 5)
            grid.owner.pastesRows = false
            grid.selectCell(0, 0)
            let before = Array(grid.owner.tableRows.rows)

            #expect(grid.isEnabled(#selector(DataGridViewController.paste(_:))))
            #expect(Array(grid.owner.tableRows.rows) == before)
            #expect(grid.owner.commits.isEmpty)
        }

        @Test("Whole rows with an empty line between them still go to row paste")
        func defersOnRowShapedTSVWithEmptyLine() throws {
            try #require(RecordingClipboard.current).text = "x\ty\tz\n\nq\tw\te\n\n"
            let grid = makeGrid(columns: ["a", "b", "c"], rowCount: 5)

            paste(into: grid, row: 0, column: 0)

            #expect(grid.owner.commits.isEmpty)
            #expect(grid.owner.rowPastes == 1)
        }

        @Test("A value with trailing line breaks still fills only the cursor's cell in a one-column table")
        func singleValueWithTrailingBreaksInSingleColumnTable() throws {
            try #require(RecordingClipboard.current).text = "hello\n\n"
            let grid = makeGrid(columns: ["a"], rowCount: 3)

            paste(into: grid, row: 1, column: 0)

            #expect(grid.owner.staged(1, 0)?.value == .text("hello"))
            #expect(grid.owner.editCount == 1)
        }

        @Test("A read-only grid pastes nothing and dims Paste")
        func refusesWhenReadOnly() throws {
            try #require(RecordingClipboard.current).text = "x\ty"
            let grid = makeGrid(columns: ["a", "b"], rowCount: 2, isEditable: false)

            paste(into: grid, row: 0, column: 0)

            #expect(grid.owner.commits.isEmpty)
            #expect(grid.owner.rowPastes == 0)
            #expect(!grid.isEnabled(#selector(DataGridViewController.paste(_:))))
        }

        @Test("The context menu's Paste on a cell outside the selection fills the clicked cell (interaction 4)")
        func contextMenuPasteTakesTheClickedCell() throws {
            try #require(RecordingClipboard.current).text = "hello"
            let grid = makeGrid(columns: ["a", "b", "c"], rowCount: 5)
            grid.select(rows: 0...1, columns: 0...0)

            grid.controller.paste(grid.contextItem(row: 3, displayColumn: 2))

            #expect(grid.owner.staged(3, 2)?.value == .text("hello"))
            #expect(grid.owner.editCount == 1)
            #expect(grid.owner.rowPastes == 0)
        }

        // A filter applied while the values load must not move the paste onto other records.
        @Test("A paste that waits for values writes the records it was pasted onto", arguments: ["x", "x\ny"])
        func pasteKeepsItsRecordsAcrossALoad(clipboardText: String) throws {
            try #require(RecordingClipboard.current).text = clipboardText
            let grid = CommandGrid(TableRows.from(
                queryRows: [[.text("1"), .null], [.text("2"), .null], [.text("3"), .text("c")]],
                columns: ["id", "body"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                unloadedCells: [0: [1: 2_000_000], 1: [1: 2_000_000]]
            ))
            grid.owner.loadableValues = [.existing(0): [1: .text("a")], .existing(1): [1: .text("b")]]
            grid.owner.defersLoads = true
            if clipboardText == "x" {
                grid.select(rows: 0...1, columns: 1...1)
            } else {
                grid.selectCell(0, 1)
            }

            grid.controller.paste(nil)
            try #require(grid.owner.commits.isEmpty)
            var filter = GridValueFilterState()
            filter.set(ColumnValueFilter(selectedValues: ["2", "3"], includesNull: false), columnName: "id", forColumn: 0)
            grid.model.setValueFilter(filter)
            grid.owner.finishLoads()

            #expect(grid.owner.staged(0, 1)?.value == .text("x"))
            #expect(grid.owner.staged(1, 1)?.value == .text(clipboardText == "x" ? "x" : "y"))
            #expect(grid.owner.staged(2, 1) == nil)
        }

        @Test("The row-number menu's Paste goes to row paste")
        func rowNumberPasteIsRowPaste() throws {
            try #require(RecordingClipboard.current).text = "hello"
            let grid = makeGrid(columns: ["a", "b", "c"], rowCount: 5)

            grid.controller.paste(grid.contextItem(row: 1, displayColumn: nil))

            #expect(grid.owner.commits.isEmpty)
            #expect(grid.owner.rowPastes == 1)
        }
    }
}
