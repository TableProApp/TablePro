//
//  DataGridSetCellsToValueTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private enum CellsToValueFixture {
    static let columns = ["id", "note", "label", "seen", "born", "calc", "payload"]
    static let id = 0
    static let note = 1
    static let label = 2
    static let seen = 3
    static let born = 4
    static let calc = 5
    static let payload = 6

    static func grid(rowCount: Int = 4) -> CommandGrid {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "things",
            columns: columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: ["calc"]
        )
        let rows: [[PluginCellValue]] = (0..<rowCount).map { row in
            [
                .text("00000000-0000-0000-0000-00000000000\(row)"),
                .text("n\(row)"),
                .text("l\(row)"),
                .text("2024-01-0\(row + 1) 10:00:00+00"),
                .text("2024-01-0\(row + 1)"),
                .text("c\(row)"),
                .null,
            ]
        }
        return CommandGrid(
            TableRows.from(
                queryRows: rows,
                columns: columns,
                columnTypes: [
                    .text(rawType: "uuid"),
                    .text(rawType: "text"),
                    .text(rawType: "text"),
                    .timestamp(rawType: "timestamptz"),
                    .date(rawType: "date"),
                    .text(rawType: "text"),
                    .blob(rawType: "bytea"),
                ],
                columnNullable: [
                    "id": false, "note": true, "label": false, "seen": true, "born": false, "calc": true, "payload": true,
                ]
            ),
            changeManager: manager
        )
    }

    static func cell(_ grid: CommandGrid, _ row: Int, _ column: Int) -> DataGridCommandCell? {
        guard let rowID = grid.model.rowID(at: row), let column = grid.model.columns.column(at: column) else { return nil }
        return DataGridCommandCell(rowID: rowID, row: row, column: column)
    }

    static func selectedCells(_ grid: CommandGrid) -> [DataGridCommandCell] {
        grid.commands.cells(.current(grid.model.selection))
    }

    static func setCellsToValue(_ text: String, in grid: CommandGrid) {
        let commands = grid.commands
        commands.applyEnteredText(text, to: selectedCells(grid).filter { commands.typingCanEdit($0) })
    }

    static func deleteRow(_ row: Int, in grid: CommandGrid) {
        grid.owner.changeManager.recordRowDeletion(rowID: .existing(row), originalRow: Array(grid.owner.tableRows.rows[row].values))
    }
}

@MainActor
struct DataGridSetCellsToValueTests {
    private typealias Fixture = CellsToValueFixture

    @Test("The typed value goes into every selected cell and no other, as one commit named Set Cells to Value")
    func writesEverySelectedCell() {
        let grid = Fixture.grid()
        grid.select(rows: 0...2, columns: Fixture.note...Fixture.note)

        Fixture.setCellsToValue("archived", in: grid)

        for row in 0...2 {
            #expect(grid.owner.staged(row, Fixture.note)?.value == .text("archived"))
            #expect(grid.owner.tableRows.rows[row].values[Fixture.note] == .text("archived"))
        }
        #expect(grid.owner.staged(3, Fixture.note) == nil)
        #expect(grid.owner.staged(0, Fixture.label) == nil)
        #expect(grid.owner.commits.map { $0.actionName } == [String(localized: "Set Cells to Value")])
    }

    @Test("A server-owned column, a binary column and a deleted row are left out of the cells it writes")
    func leavesOutCellsTypingCannotEdit() {
        let grid = Fixture.grid()
        Fixture.deleteRow(1, in: grid)
        grid.select(rows: 0...1, columns: Fixture.born...Fixture.payload)
        let targets = Fixture.selectedCells(grid)

        let cells = targets.filter { grid.commands.typingCanEdit($0) }

        #expect(targets.count == 6)
        #expect(cells == [Fixture.cell(grid, 0, Fixture.born)].compactMap { $0 })
        #expect(grid.commands.isSetCellsToValueOffered(for: targets))
    }

    @Test("Nothing is offered where typing could edit no cell")
    func notOfferedWithoutAnEditableCell() {
        let grid = Fixture.grid()
        let readOnly = [Fixture.cell(grid, 0, Fixture.calc), Fixture.cell(grid, 1, Fixture.payload)].compactMap { $0 }

        #expect(!grid.commands.isSetCellsToValueOffered(for: readOnly))
        #expect(!grid.commands.isSetCellsToValueOffered(for: []))

        grid.model.configuration.isEditable = false
        #expect(!grid.commands.isSetCellsToValueOffered(for: [Fixture.cell(grid, 0, Fixture.note)].compactMap { $0 }))
    }

    @Test("The sheet says how many cells take the value, and how many it skips")
    func impactCountsTheCells() {
        #expect(DataGridCommands.setCellsToValueImpact(cells: 1, targets: 1) == "This sets 1 cell.")
        #expect(DataGridCommands.setCellsToValueImpact(cells: 40, targets: 40) == "This sets 40 cells.")
        #expect(
            DataGridCommands.setCellsToValueImpact(cells: 38, targets: 40)
                == "This sets 38 of 40 cells. The others cannot be edited."
        )
    }

    @Test("A column that holds neither the text nor NULL keeps its cells, and the others take it")
    func refusingColumnKeepsItsCells() {
        let grid = Fixture.grid()
        grid.select(rows: 0...1, columns: Fixture.note...Fixture.born)

        Fixture.setCellsToValue("", in: grid)

        #expect(grid.owner.staged(0, Fixture.note)?.value == .text(""))
        #expect(grid.owner.staged(1, Fixture.seen)?.value == .null)
        #expect(grid.owner.staged(0, Fixture.born) == nil)
        #expect(grid.owner.tableRows.rows[1].values[Fixture.born] == .text("2024-01-02"))
    }

    @Test("A function name stages as SQL on a timestamp and as text on a text column, as typing it does")
    func functionIsReadPerColumn() {
        let grid = Fixture.grid()
        grid.select(rows: 0...0, columns: Fixture.note...Fixture.seen)

        Fixture.setCellsToValue("now()", in: grid)

        #expect(grid.owner.staged(0, Fixture.seen)?.value == .text("now()"))
        #expect(grid.owner.staged(0, Fixture.seen)?.isExpression == true)
        #expect(grid.owner.staged(0, Fixture.note)?.value == .text("now()"))
        #expect(grid.owner.staged(0, Fixture.note)?.isExpression == false)
    }

    @Test("With whole rows selected the clicked column is written on each of them")
    func clickedColumnOnSelectedRows() {
        let grid = Fixture.grid()
        grid.model.setSelection(GridSelection(
            rectangles: [GridRect(rows: 0...0, columns: 0...6), GridRect(rows: 2...2, columns: 0...6)],
            activeCell: GridCoord(row: 2, displayColumn: 0),
            anchor: GridCoord(row: 0, displayColumn: 0)
        ))
        let scope = DataGridCommandScope.contextMenu(selection: grid.model.selection, row: 2, displayColumn: Fixture.note, columnCount: 7)

        grid.commands.applyEnteredText("archived", to: grid.commands.cells(scope))

        #expect(grid.owner.staged(0, Fixture.note)?.value == .text("archived"))
        #expect(grid.owner.staged(1, Fixture.note) == nil)
        #expect(grid.owner.staged(2, Fixture.note)?.value == .text("archived"))
    }

    @Test("A window with its own Set Cells to Value runs it, and the grid stages nothing")
    func windowCommandTakesOver() {
        let grid = Fixture.grid()
        grid.owner.runsSetCellsToValue = true
        grid.select(rows: 0...1, columns: Fixture.note...Fixture.note)

        grid.controller.setCellsToValue(nil)

        let handed = grid.owner.setCellsToValueRequests
        #expect(handed.map { $0.map { $0.rowID } } == [[.existing(0), .existing(1)]])
        #expect(handed.map { $0.map { $0.column } } == [["note", "note"]])
        #expect(grid.owner.commits.isEmpty)
    }

    @Test("The records under the sheet are found again after a value filter moves them")
    func recordsFollowTheirRows() throws {
        let grid = Fixture.grid()
        let records = DataGridCellRecords(
            [Fixture.cell(grid, 1, Fixture.note), Fixture.cell(grid, 3, Fixture.label)].compactMap { $0 },
            in: grid.model
        )
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["n1", "n2", "n3"], includesNull: false), columnName: "note", forColumn: Fixture.note)
        grid.model.setValueFilter(filter)

        let moved = try #require(records.current(in: grid.model))

        #expect(moved.map { $0.row } == [0, 2])
        #expect(moved.map { $0.column.name } == ["note", "label"])
    }

    @Test("A load that replaces the records under the sheet drops the write")
    func replacedRecordsDropTheWrite() {
        let grid = Fixture.grid()
        let records = DataGridCellRecords([Fixture.cell(grid, 1, Fixture.note)].compactMap { $0 }, in: grid.model)

        _ = grid.owner.tableRows.edit(row: 1, column: Fixture.label, value: .text("reloaded"))
        grid.model.reloadRows()

        #expect(records.current(in: grid.model) == nil)
    }

    @Test("A record a value filter now hides drops the write")
    func hiddenRecordDropsTheWrite() {
        let grid = Fixture.grid()
        let records = DataGridCellRecords([Fixture.cell(grid, 1, Fixture.note)].compactMap { $0 }, in: grid.model)
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["n0", "n2"], includesNull: false), columnName: "note", forColumn: Fixture.note)

        grid.model.setValueFilter(filter)

        #expect(records.current(in: grid.model) == nil)
    }
}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct DataGridPasteIntoSelectionTests {
        private typealias Fixture = CellsToValueFixture

        @Test("One pasted value goes into every selected cell, as one commit named Paste Cells")
        func singleValueFillsTheSelection() throws {
            try #require(RecordingClipboard.current).text = "archived"
            let grid = Fixture.grid()
            grid.select(rows: 0...2, columns: Fixture.note...Fixture.label)

            grid.controller.paste(nil)

            for row in 0...2 {
                #expect(grid.owner.staged(row, Fixture.note)?.value == .text("archived"))
                #expect(grid.owner.staged(row, Fixture.label)?.value == .text("archived"))
            }
            #expect(grid.owner.staged(3, Fixture.note) == nil)
            #expect(grid.owner.commits.map { $0.actionName } == [String(localized: "Paste Cells")])
        }

        @Test("A NULL copied from the grid fills nullable cells and leaves a NOT NULL column alone")
        func copiedNullFillsWhereItFits() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = Fixture.grid()
            grid.selectCell(0, Fixture.payload)
            grid.controller.copy(nil)
            #expect(clipboard.gridCells?.fields == [[nil]])
            grid.select(rows: 1...2, columns: Fixture.note...Fixture.label)

            grid.controller.paste(nil)

            #expect(grid.owner.staged(1, Fixture.note)?.value == .null)
            #expect(grid.owner.staged(2, Fixture.note)?.value == .null)
            #expect(grid.owner.staged(1, Fixture.label) == nil)
            #expect(grid.owner.tableRows.rows[2].values[Fixture.label] == .text("l2"))
        }

        @Test("A block, or a single selected cell, keeps the paste anchored at the cursor")
        func blockOrOneCellKeepsTheAnchor() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = Fixture.grid()

            clipboard.text = "a\tb"
            grid.select(rows: 0...1, columns: Fixture.note...Fixture.label, active: GridCoord(row: 0, displayColumn: Fixture.note))
            let block = try #require(DataGridCellPasteBlock.fromClipboard())
            #expect(grid.commands.pasteFillTargets(.current(grid.model.selection), block: block) == nil)

            clipboard.text = "a"
            grid.selectCell(0, Fixture.note)
            let single = try #require(DataGridCellPasteBlock.fromClipboard())
            #expect(grid.commands.pasteFillTargets(.current(grid.model.selection), block: single) == nil)
            #expect(grid.commands.pasteAnchor(.current(grid.model.selection), block: single) == GridCoord(row: 0, displayColumn: Fixture.note))
        }

        @Test("Paste is enabled over a cell selection with no cursor when one value is on the clipboard")
        func pasteIsEnabledWithoutACursor() throws {
            try #require(RecordingClipboard.current).text = "archived"
            let grid = Fixture.grid()
            grid.model.setSelection(GridSelection(
                rectangles: [GridRect(rows: 0...3, columns: Fixture.note...Fixture.note)],
                activeCell: nil,
                anchor: nil
            ))

            #expect(grid.isEnabled(#selector(DataGridViewController.paste(_:))))
        }
    }
}
