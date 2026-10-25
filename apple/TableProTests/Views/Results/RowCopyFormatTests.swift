//
//  RowCopyFormatTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct RowCopyFormatTests {
        private func makeGrid(appliesRowCopyFormat: Bool = true) -> CommandGrid {
            CommandGrid(CommandRows.people, configuration: CommandGrid.editable(appliesRowCopyFormat: appliesRowCopyFormat))
        }

        // MARK: - Copy

        @Test(
            "Copy writes a header line and a CSV line per selected row when rows copy as CSV with Headers",
            .appSettings { $0.dataGrid.rowCopyFormat = .csvWithHeaders }
        )
        func copyUsesTheChosenFormat() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.selectRows(0...2)

            grid.controller.copy(nil)

            #expect(clipboard.text == "id,name\n1,Alice\n2,Bob\n3,Carol\n")
            #expect(clipboard.gridRows?.rows.count == 3)
        }

        @Test(
            "One row picked by its number copies as a row, not as the cell the cursor stays on",
            .appSettings { $0.dataGrid.rowCopyFormat = .csvWithHeaders }
        )
        func rowPickedByNumberCopiesTheRow() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.selectRows(1...1, activeColumn: 1)

            grid.controller.copy(nil)

            #expect(clipboard.text == "id,name\n2,Bob\n")
        }

        @Test(
            "A cell the user clicked still copies its value",
            .appSettings { $0.dataGrid.rowCopyFormat = .csvWithHeaders }
        )
        func clickedCellCopiesItsValue() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.selectCell(1, 1)

            grid.controller.copy(nil)

            #expect(clipboard.text == "Bob")
        }

        @Test(
            "A cell range still copies as cells",
            .appSettings { $0.dataGrid.rowCopyFormat = .json }
        )
        func cellRangeCopiesAsCells() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.select(rows: 0...1, columns: 0...1)

            grid.controller.copy(nil)

            #expect(clipboard.text == "1\tAlice\n2\tBob")
            #expect(clipboard.gridCells != nil)
        }

        @Test(
            "The TSV default lets an owner that writes its own pasteboard type copy the rows",
            .appSettings { $0.dataGrid.rowCopyFormat = .rows }
        )
        func defaultFormatAsksTheOwnerFirst() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.owner.copiesRowsItself = true
            grid.selectRows(0...1)

            grid.controller.copy(nil)

            #expect(grid.owner.rowCopies == [[.existing(0), .existing(1)]])
            #expect(clipboard.text == nil)
        }

        @Test(
            "A grid of definitions keeps its owner's row copy whatever the format",
            .appSettings { $0.dataGrid.rowCopyFormat = .csvWithHeaders }
        )
        func definitionsGridKeepsItsCopy() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid(appliesRowCopyFormat: false)
            grid.owner.copiesRowsItself = true
            grid.selectRows(0...1)

            grid.controller.copy(nil)

            #expect(grid.owner.rowCopies == [[.existing(0), .existing(1)]])
            #expect(clipboard.text == nil)
        }

        @Test(
            "The row menu's Copy on a row number follows the format and copies that row alone",
            .appSettings { $0.dataGrid.rowCopyFormat = .markdown }
        )
        func rowMenuCopyFollowsTheFormat() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.selectCell(0, 0)

            grid.controller.copy(grid.contextItem(row: 1, displayColumn: nil))

            #expect(clipboard.text?.hasPrefix("| id | name |") == true)
            #expect(clipboard.text?.contains("Bob") == true)
            #expect(clipboard.text?.contains("Alice") != true)
        }

        @Test("Rows a grid without its own row copy shows copy as TSV, ready to paste back as rows")
        func heldRowsCopyAsTSV() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = CommandGrid(CommandRows.people, configuration: CommandGrid.readOnly(appliesRowCopyFormat: false))
            grid.model.setSelection(GridSelection(
                rectangles: [GridRect(rows: 0...0, columns: 0...1), GridRect(rows: 2...2, columns: 0...1)],
                activeCell: GridCoord(row: 2, displayColumn: 0),
                anchor: GridCoord(row: 2, displayColumn: 0)
            ))

            grid.controller.copySelectedRows(nil)

            #expect(clipboard.text == "1\tAlice\n3\tCarol")
            #expect(clipboard.html == nil)
            #expect(clipboard.gridRows?.rows.count == 2)
        }

        @Test("Copy with Headers writes a header line, an HTML table and the rows' payload")
        func copyWithHeaders() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.select(rows: 0...1, columns: 1...1)

            grid.controller.copyRowsWithHeaders(nil)

            #expect(clipboard.text == "id\tname\n1\tAlice\n2\tBob")
            #expect(clipboard.html?.contains("Alice") == true)
            #expect(clipboard.gridRows?.columns == ["id", "name"])
        }

        @Test("Rows copied as CSV paste into a data file by column name, not as one cell per line")
        func dataFilePasteReadsTheCopiedRows() async throws {
            let clipboard = try #require(RecordingClipboard.current)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RowCopyFormatTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("people.csv")
            try Data("name,city\nAlice,Lima\n".utf8).write(to: url)
            let undoManager = UndoManager()
            let controller = DataFileController()
            controller.undoManager = undoManager
            controller.load(url: url, kind: try #require(DataFileKind.classify(url)))
            await controller.waitForPendingWork()
            clipboard.writeCsv(
                "city,name\n\"Oslo, NO\",Bob\n",
                gridRows: GridRowsClipboardPayload(columns: ["city", "name"], rows: [[.text("Oslo, NO"), .text("Bob")]])
            )
            let adapter = DataFileGridAdapter(model: DataGridModel())
            adapter.controller = controller

            adapter.gridPasteRows()
            await controller.waitForPendingWork()

            #expect(controller.tableRows.rows.count == 2)
            #expect(controller.tableRows.rows.last.map { Array($0.values) } == [.text("Bob"), .text("Oslo, NO")])
            withExtendedLifetime(undoManager) {}
        }

        @Test("Rows from another source, or with a repeated column name, paste into a file in order")
        func dataFilePasteFallsBackToOrder() {
            let fromTable = GridRowsClipboardPayload(columns: ["id", "email"], rows: [[.text("7"), .null]])
            #expect(DataFilePasteParser.rows(from: fromTable, into: ["name", "city"]) == [["7", ""]])

            let repeated = GridRowsClipboardPayload(columns: ["id", "id"], rows: [[.text("1"), .text("2")]])
            #expect(DataFilePasteParser.rows(from: repeated, into: ["id", "id (2)"]) == [["1", "2"]])

            let hidden = GridRowsClipboardPayload(columns: ["city"], rows: [[.text("Lima")]])
            #expect(DataFilePasteParser.rows(from: hidden, into: ["name", "city"]) == [["", "Lima"]])
        }

        @Test("A formatted copy past the row cap stops there, in the text and the paste payload alike")
        func formattedCopyStopsAtTheCap() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let cap = RowOperationsManager.maxClipboardRows
            let rowCount = cap + 2
            let rows = TableRows.from(
                queryRows: (0..<rowCount).map { [.text("\($0)"), .text("v\($0)")] },
                columns: ["id", "value"],
                columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
            )
            let grid = CommandGrid(rows)
            grid.selectRows(0...(rowCount - 1))

            grid.controller.copyRowsAsCsv(nil)

            let lines = clipboard.text?.split(separator: "\n") ?? []
            #expect(lines.count == cap)
            #expect(lines.last == "\(cap - 1),v\(cap - 1)")
            #expect(clipboard.gridRows?.rows.count == cap)
        }

        // MARK: - Copy Cell Value

        private func formattedCell(value: PluginCellValue, columnType: ColumnType, format: ValueDisplayFormat) -> CommandGrid {
            let rows = TableRows.from(queryRows: [[value]], columns: ["payload"], columnTypes: [columnType])
            let grid = CommandGrid(rows, configuration: CommandGrid.readOnly())
            grid.model.setDisplayFormat(format, for: grid.model.columns.columns[0])
            grid.selectCell(0, 0)
            return grid
        }

        @Test("A single binary cell under a decoder format copies the decoded text")
        func decodedCellCopiesDecodedText() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let bytes = Data([0x82, 0xA1, 0x61, 0x01, 0xA1, 0x62, 0xC3])
            let grid = formattedCell(value: .bytes(bytes), columnType: .blob(rawType: "BLOB"), format: .messagePack)

            grid.controller.copyCellValue(nil)

            #expect(clipboard.text == #"{"a":1,"b":true}"#)
        }

        @Test("A format saved before the column changed type copies the stored value, as the cell draws it")
        func inapplicableFormatCopiesStoredValue() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = formattedCell(value: .text("1"), columnType: .text(rawType: "TEXT"), format: .messagePack)

            grid.controller.copyCellValue(nil)

            #expect(clipboard.text == "1")
        }

        @Test("Copy Cell Value copies the cursor's cell with several rows selected")
        func copyCellValueWithSeveralRows() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.selectRows(0...1, activeColumn: 1)

            grid.controller.copyCellValue(nil)

            #expect(clipboard.text == "Bob")
        }

        @Test("Copy Cell Value copies the cursor's cell inside a cell range")
        func copyCellValueInsideARange() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.select(rows: 0...2, columns: 0...1, active: GridCoord(row: 2, displayColumn: 0))

            grid.controller.copyCellValue(nil)

            #expect(clipboard.text == "3")
        }

        // MARK: - Copy Special formats

        @Test("Copy as CSV from the menu bar copies the selected rows and keeps them pasteable")
        func copyAsCsvCommand() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.selectRows(0...1)

            #expect(grid.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsCsv(_:))))
            grid.controller.copyRowsAsCsv(nil)

            #expect(clipboard.text == "1,Alice\n2,Bob\n")
            #expect(clipboard.gridRows?.columns == ["id", "name"])
            #expect(clipboard.gridRows?.rows.count == 2)
        }

        @Test("Copy as Markdown from the menu bar keeps the rows pasteable")
        func copyAsMarkdownCommand() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.selectRows(2...2)

            grid.controller.copyRowsAsMarkdown(nil)

            #expect(clipboard.text?.contains("| 3 | Carol |") == true)
            #expect(clipboard.gridRows?.rows.count == 1)
        }

        @Test("JSON, CSV and Markdown include every row a range touches", arguments: [
            RowCopyFormat.json, .csv, .markdown,
        ])
        func formatsTakeEveryRowOfTheRange(format: RowCopyFormat) throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.select(rows: 0...1, columns: 0...1, active: GridCoord(row: 1, displayColumn: 0))

            grid.commands.copyRows(.current(grid.model.selection), as: format)

            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
            #expect(clipboard.text?.contains("Carol") != true)
        }

        @Test("JSON and CSV take only the columns a picked column or a cell selection covers")
        func formatsTakeTheSelectedColumns() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.model.setSelection(GridSelection.column(0, totalRows: 3))

            grid.controller.copyRowsAsJson(nil)
            #expect(clipboard.text?.contains("\"id\"") == true)
            #expect(clipboard.text?.contains("Alice") != true)

            grid.controller.copyRowsAsCsv(nil)
            #expect(clipboard.text?.contains("Bob") != true)
            #expect(clipboard.gridRows?.columns == ["id"])
        }

        @Test("Copy as JSON from a row's menu with no selection copies that row")
        func jsonFallsBackToTheClickedRow() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()

            grid.controller.copyRowsAsJson(grid.contextItem(row: 1, displayColumn: 1))

            #expect(clipboard.text?.contains("Bob") == true)
            #expect(clipboard.text?.contains("Alice") != true)
        }

        @Test("The row formats copy nothing on a grid of definitions")
        func formatsAreInertOnADefinitionsGrid() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid(appliesRowCopyFormat: false)
            grid.selectRows(0...1)

            grid.controller.copyRowsAsCsv(nil)
            grid.controller.copyRowsAsMarkdown(nil)

            #expect(clipboard.text == nil)
        }

        @Test("Copy as IN Clause takes the one column a cell selection covers")
        func inClauseTakesTheSelectedColumn() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.select(rows: 0...2, columns: 1...1)

            grid.controller.copyRowsAsInClause(nil)

            #expect(clipboard.text == "('Alice', 'Bob', 'Carol')")
        }

        @Test("Copy as IN Clause takes the cursor's column over a row selection")
        func inClauseFallsBackToTheCursorColumn() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.selectRows(0...1, activeColumn: 1)

            grid.controller.copyRowsAsInClause(nil)

            #expect(clipboard.text == "('Alice', 'Bob')")
        }

        // MySQL reads a backslash as an escape, so quote doubling alone would let a value close the list.
        @Test("Copy as IN Clause without an owner's dialect escapes for the grid's engine")
        func inClauseEscapesForTheEngine() throws {
            let clipboard = try #require(RecordingClipboard.current)
            var configuration = CommandGrid.editable()
            configuration.traits = DataGridEngineTraits(databaseType: .mysql)
            let grid = CommandGrid(
                TableRows.from(
                    queryRows: [[.text(#"x\') OR 1=1 -- "#)]],
                    columns: ["ref"],
                    columnTypes: [.text(rawType: "TEXT")]
                ),
                configuration: configuration
            )
            grid.select(rows: 0...0, columns: 0...0)

            grid.controller.copyRowsAsInClause(nil)

            #expect(clipboard.text == #"('x\\'') OR 1=1 -- ')"#)
        }

        @Test("Copy as IN Clause from a cell's menu inside a range takes the clicked column, through the owner's dialect")
        func inClauseTakesTheClickedColumn() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = makeGrid()
            grid.owner.exporter = RecordingSQLExporter()
            grid.select(rows: 0...1, columns: 0...1)

            grid.controller.copyRowsAsInClause(grid.contextItem(row: 0, displayColumn: 1))

            #expect(clipboard.text == "IN Alice,Bob")
        }

        // MARK: - Statements

        private func statementGrid() -> (CommandGrid, RecordingSQLExporter) {
            var configuration = CommandGrid.editable()
            configuration.commands.insert(.copyAsSQL)
            let grid = CommandGrid(
                TableRows.from(
                    queryRows: [
                        [.text("1"), .text("Alice"), .text("NYC"), .text("x")],
                        [.text("2"), .text("Bob"), .text("LA"), .text("y")],
                    ],
                    columns: ["c0", "c1", "c2", "c3"],
                    columnTypes: Array(repeating: .text(rawType: "TEXT"), count: 4)
                ),
                configuration: configuration
            )
            let exporter = RecordingSQLExporter()
            grid.owner.exporter = exporter
            return (grid, exporter)
        }

        @Test("INSERT and UPDATE take every row of a range selection")
        func statementsTakeEveryRow() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let (grid, exporter) = statementGrid()
            grid.select(rows: 0...1, columns: 0...3)

            grid.controller.copyRowsAsInsertStatements(nil)
            #expect(clipboard.text == "INSERT 2")
            grid.controller.copyRowsAsUpdateStatements(nil)

            #expect(exporter.requests.map { $0.rowIDs } == [[.existing(0), .existing(1)], [.existing(0), .existing(1)]])
            #expect(exporter.requests.map { $0.update } == [false, true])
        }

        @Test("INSERT and UPDATE take only the selected columns, a discontiguous selection as its column union")
        func statementsTakeTheSelectedColumns() {
            let (grid, exporter) = statementGrid()
            grid.model.setSelection(GridSelection(
                rectangles: [GridRect(cell: GridCoord(row: 0, displayColumn: 2)), GridRect(cell: GridCoord(row: 1, displayColumn: 0))],
                activeCell: GridCoord(row: 1, displayColumn: 0),
                anchor: GridCoord(row: 0, displayColumn: 2)
            ))

            grid.controller.copyRowsAsInsertStatements(nil)
            grid.controller.copyRowsAsUpdateStatements(nil)

            #expect(exporter.requests.map { $0.columns } == [["c0", "c2"], ["c0", "c2"]])
        }

        @Test("Whole rows, and one clicked cell, hand every presented column")
        func statementsOverRowsTakeEveryColumn() {
            let (grid, exporter) = statementGrid()
            grid.selectRows(0...0)
            grid.controller.copyRowsAsUpdateStatements(nil)

            grid.selectCell(1, 2)
            grid.controller.copyRowsAsInsertStatements(nil)

            #expect(exporter.requests.map { $0.columns } == [["c0", "c1", "c2", "c3"], ["c0", "c1", "c2", "c3"]])
            #expect(exporter.requests.last?.rowIDs == [.existing(1)])
        }
    }
}
