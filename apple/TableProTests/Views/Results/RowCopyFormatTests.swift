//
//  RowCopyFormatTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class RowCopyLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class RowCopyDelegateSpy: DataGridViewDelegate {
    var copiedRows: Set<Int>?

    func dataGridCopyRows(_ indices: Set<Int>) {
        copiedRows = indices
    }
}

@MainActor
private final class RowCopySelectionBox {
    var value: Set<Int> = []

    func binding() -> Binding<Set<Int>> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

@MainActor
private struct RowCopyGrid {
    let tableView: KeyHandlingTableView
    let coordinator: TableViewCoordinator
    let selection: RowCopySelectionBox

    init(
        appliesRowCopyFormat: Bool = true,
        delegate: (any DataGridViewDelegate)? = nil,
        hasAuthoritativeSchema: Bool = false
    ) {
        let tableRows = TableRows.from(
            queryRows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")], [.text("3"), .text("Carol")]],
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")],
            hasAuthoritativeSchema: hasAuthoritativeSchema
        )
        let box = RowCopySelectionBox()
        selection = box
        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: box.binding(),
            delegate: delegate,
            layoutPersister: RowCopyLayoutPersister()
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.appliesRowCopyFormat = appliesRowCopyFormat

        tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.allowsMultipleSelection = true
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())

        coordinator.tableView = tableView
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: tableRows.columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 100 }
        )
        coordinator.selectionController.tableView = tableView
        coordinator.selectionController.coordinator = coordinator
        coordinator.invalidateColumnIndexCache()
        coordinator.updateCache()
        tableView.reloadData()
    }

    // What a row-number click leaves behind: the rows, and a cursor seeded for the keyboard.
    func selectRowsByNumber(_ rows: IndexSet) {
        tableView.focusedRow = -1
        tableView.focusedColumn = -1
        tableView.isCursorSeededByRowSelection = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: tableView)
        )
    }

    func focusCell(row: Int, dataColumn: Int) {
        tableView.isCursorSeededByRowSelection = false
        tableView.focusedRow = row
        tableView.focusedColumn = coordinator.tableColumnIndex(for: dataColumn) ?? -1
    }

    func selectCells(rows: ClosedRange<Int>, displayColumns: ClosedRange<Int>) {
        let anchor = GridCoord(row: rows.lowerBound, displayColumn: displayColumns.lowerBound)
        coordinator.selectionController.update(
            .single(GridRect(rows: rows, columns: displayColumns), anchor: anchor, active: anchor)
        )
    }

    func isEnabled(_ action: Selector) -> Bool {
        tableView.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }
}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct RowCopyFormatTests {
        // MARK: - Copy

        @Test(
            "Copy writes a header line and a CSV line per selected row when rows copy as CSV with Headers",
            .appSettings { $0.dataGrid.rowCopyFormat = .csvWithHeaders }
        )
        func copyUsesTheChosenFormat() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectRowsByNumber(IndexSet(0...2))

            grid.tableView.copy(nil)

            #expect(clipboard.text == "id,name\n1,Alice\n2,Bob\n3,Carol\n")
            #expect(clipboard.gridRows?.rows.count == 3)
        }

        @Test(
            "One row picked by its number copies as a row, not as the cell the keyboard cursor was seeded on",
            .appSettings { $0.dataGrid.rowCopyFormat = .csvWithHeaders }
        )
        func rowPickedByNumberCopiesTheRow() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectRowsByNumber(IndexSet(integer: 1))
            #expect(grid.tableView.focusedRow == 1)

            grid.tableView.copy(nil)

            #expect(clipboard.text == "id,name\n2,Bob\n")
        }

        @Test(
            "A cell the user put the cursor on still copies its value",
            .appSettings { $0.dataGrid.rowCopyFormat = .csvWithHeaders }
        )
        func focusedCellCopiesItsValue() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectRowsByNumber(IndexSet(integer: 1))
            grid.focusCell(row: 1, dataColumn: 1)

            grid.tableView.copy(nil)

            #expect(clipboard.text == "Bob")
        }

        @Test(
            "A cell range still copies as cells",
            .appSettings { $0.dataGrid.rowCopyFormat = .json }
        )
        func cellRangeCopiesAsCells() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectCells(rows: 0...1, displayColumns: 0...1)

            grid.tableView.copy(nil)

            #expect(clipboard.text == "1\tAlice\n2\tBob")
            #expect(clipboard.gridCells != nil)
        }

        @Test(
            "The TSV default keeps the grid's own row copy",
            .appSettings { $0.dataGrid.rowCopyFormat = .rows }
        )
        func defaultFormatKeepsTheGridsCopy() {
            let spy = RowCopyDelegateSpy()
            let grid = RowCopyGrid(delegate: spy)
            grid.selectRowsByNumber(IndexSet(0...1))

            grid.tableView.copy(nil)

            #expect(spy.copiedRows == Set([0, 1]))
        }

        @Test(
            "A grid of definitions keeps its own row copy whatever the format",
            .appSettings { $0.dataGrid.rowCopyFormat = .csvWithHeaders }
        )
        func definitionsGridKeepsItsCopy() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let spy = RowCopyDelegateSpy()
            let grid = RowCopyGrid(appliesRowCopyFormat: false, delegate: spy)
            grid.selectRowsByNumber(IndexSet(0...1))

            grid.tableView.copy(nil)

            #expect(spy.copiedRows == Set([0, 1]))
            #expect(clipboard.text == nil)
        }

        @Test(
            "The row menu's Copy on a row number follows the format",
            .appSettings { $0.dataGrid.rowCopyFormat = .markdown }
        )
        func rowMenuCopyFollowsTheFormat() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectRowsByNumber(IndexSet(0...1))
            let rowView = DataGridRowView()
            rowView.coordinator = grid.coordinator
            rowView.rowIndex = 0
            let item = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
            item.representedObject = DataGridRowView.CopyContextTarget.row

            _ = rowView.perform(NSSelectorFromString("copyFromContextMenu:"), with: item)

            #expect(clipboard.text?.hasPrefix("| id | name |") == true)
            #expect(clipboard.text?.contains("Bob") == true)
            #expect(clipboard.text?.contains("Carol") != true)
        }

        @Test("Rows a held result shows copy as TSV")
        func heldRowsCopyAsTSV() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let delegate = HeldRowsGridDelegate()
            let grid = RowCopyGrid(delegate: delegate)
            delegate.dataGridAttach(tableViewCoordinator: grid.coordinator)

            delegate.dataGridCopyRows([0, 2])

            #expect(clipboard.text == "1\tAlice\n3\tCarol")
            #expect(clipboard.html == nil)
            #expect(clipboard.gridRows?.rows.count == 2)
        }

        @Test("Rows copied as CSV paste into a data file by column name, not as one cell per line")
        func dataFilePasteReadsTheCopiedRows() async throws {
            let clipboard = try #require(RecordingClipboard.current)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RowCopyFormatTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

            DataFileGridDelegate(controller: controller).dataGridPasteRows()
            await controller.waitForPendingWork()

            #expect(controller.tableRows.rows.count == 2)
            #expect(controller.tableRows.rows.last.map { Array($0.values) } == [.text("Bob"), .text("Oslo, NO")])
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
            let coordinator = TableViewCoordinator(
                changeManager: AnyChangeManager(DataChangeManager()),
                isEditable: true,
                selectedRowIndices: .constant([]),
                delegate: nil,
                layoutPersister: RowCopyLayoutPersister()
            )
            let tableRows = TableRows.from(
                queryRows: (0..<rowCount).map { [.text("\($0)"), .text("v\($0)")] },
                columns: ["id", "value"],
                columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
            )
            coordinator.tableRowsProvider = { tableRows }
            coordinator.updateCache()

            coordinator.copyRowsAsCsv(at: Set(0..<rowCount), includeHeaders: false)

            let lines = clipboard.text?.split(separator: "\n") ?? []
            #expect(lines.count == cap)
            #expect(lines.last == "\(cap - 1),v\(cap - 1)")
            #expect(clipboard.gridRows?.rows.count == cap)
        }

        // MARK: - Copy Cell Value

        private func formattedCellCoordinator(
            value: PluginCellValue,
            columnType: ColumnType,
            format: ValueDisplayFormat
        ) -> TableViewCoordinator {
            let coordinator = TableViewCoordinator(
                changeManager: AnyChangeManager(DataChangeManager()),
                isEditable: false,
                selectedRowIndices: .constant([]),
                delegate: nil,
                layoutPersister: RowCopyLayoutPersister()
            )
            let tableRows = TableRows.from(queryRows: [[value]], columns: ["payload"], columnTypes: [columnType])
            coordinator.tableRowsProvider = { tableRows }
            coordinator.updateCache()
            coordinator.updateDisplayFormats([format])
            return coordinator
        }

        @Test("A single binary cell under a decoder format copies the decoded text")
        func decodedCellCopiesDecodedText() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let bytes = Data([0x82, 0xA1, 0x61, 0x01, 0xA1, 0x62, 0xC3])
            let coordinator = formattedCellCoordinator(
                value: .bytes(bytes), columnType: .blob(rawType: "BLOB"), format: .messagePack
            )

            coordinator.copyCellValue(at: 0, columnIndex: 0)

            #expect(clipboard.text == #"{"a":1,"b":true}"#)
        }

        @Test("A format saved before the column changed type copies the stored value, as the cell draws it")
        func inapplicableFormatCopiesStoredValue() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let coordinator = formattedCellCoordinator(
                value: .text("1"), columnType: .text(rawType: "TEXT"), format: .messagePack
            )

            coordinator.copyCellValue(at: 0, columnIndex: 0)

            #expect(clipboard.text == "1")
        }

        @Test("Copy Cell Value copies the focused cell with several rows selected")
        func copyCellValueWithSeveralRows() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectRowsByNumber(IndexSet(0...2))
            grid.focusCell(row: 1, dataColumn: 1)

            grid.tableView.copyCellValue(nil)

            #expect(clipboard.text == "Bob")
        }

        @Test("Copy Cell Value copies the focused cell inside a cell range")
        func copyCellValueInsideARange() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectCells(rows: 0...2, displayColumns: 0...1)
            grid.focusCell(row: 2, dataColumn: 0)

            grid.tableView.copyCellValue(nil)

            #expect(clipboard.text == "3")
        }

        @Test("Copy Cell Value is dimmed with no cell cursor")
        func copyCellValueNeedsACursor() {
            let grid = RowCopyGrid()
            grid.selectRowsByNumber(IndexSet(0...1))
            grid.tableView.focusedRow = -1
            grid.tableView.focusedColumn = -1

            #expect(!grid.isEnabled(#selector(GridCopyCommandResponding.copyCellValue(_:))))
        }

        // MARK: - Copy Special formats

        @Test("Copy as CSV from the menu bar copies the selected rows and keeps them pasteable")
        func copyAsCsvCommand() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectRowsByNumber(IndexSet(0...1))

            #expect(grid.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsCsv(_:))))
            grid.tableView.copyRowsAsCsv(nil)

            #expect(clipboard.text == "1,Alice\n2,Bob\n")
            #expect(clipboard.gridRows?.columns == ["id", "name"])
            #expect(clipboard.gridRows?.rows.count == 2)
        }

        @Test("Copy as Markdown from the menu bar keeps the rows pasteable")
        func copyAsMarkdownCommand() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectRowsByNumber(IndexSet(integer: 2))

            grid.tableView.copyRowsAsMarkdown(nil)

            #expect(clipboard.text?.contains("| 3 | Carol |") == true)
            #expect(clipboard.gridRows?.rows.count == 1)
        }

        @Test("The row formats are dimmed on a grid of definitions")
        func formatsDimOnADefinitionsGrid() {
            let grid = RowCopyGrid(appliesRowCopyFormat: false)
            grid.selectRowsByNumber(IndexSet(0...1))

            #expect(!grid.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsCsv(_:))))
            #expect(!grid.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsMarkdown(_:))))
            #expect(!grid.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:))))
        }

        @Test("Copy as IN Clause takes the one column a cell selection covers")
        func inClauseTakesTheSelectedColumn() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectCells(rows: 0...2, displayColumns: 1...1)
            grid.focusCell(row: 0, dataColumn: 0)

            grid.tableView.copyRowsAsInClause(nil)

            #expect(clipboard.text == "('Alice', 'Bob', 'Carol')")
        }

        @Test("Copy as IN Clause takes the focused cell's column over a row selection")
        func inClauseFallsBackToTheFocusedColumn() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let grid = RowCopyGrid()
            grid.selectRowsByNumber(IndexSet(0...1))
            grid.focusCell(row: 0, dataColumn: 1)

            grid.tableView.copyRowsAsInClause(nil)

            #expect(clipboard.text == "('Alice', 'Bob')")
        }

        @Test("INSERT and UPDATE are offered only where the row menu offers them")
        func statementsFollowTheRowMenu() {
            let noTable = RowCopyGrid(hasAuthoritativeSchema: true)
            noTable.selectRowsByNumber(IndexSet(0...1))
            #expect(!noTable.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:))))

            let table = RowCopyGrid(hasAuthoritativeSchema: true)
            table.coordinator.tableName = "users"
            table.coordinator.databaseType = .mysql
            table.selectRowsByNumber(IndexSet(0...1))
            #expect(table.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:))))
            #expect(table.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsUpdateStatements(_:))))

            let schemaPending = RowCopyGrid(hasAuthoritativeSchema: false)
            schemaPending.coordinator.tableName = "users"
            schemaPending.coordinator.databaseType = .mysql
            schemaPending.selectRowsByNumber(IndexSet(0...1))
            #expect(!schemaPending.isEnabled(#selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:))))
        }
    }
}
