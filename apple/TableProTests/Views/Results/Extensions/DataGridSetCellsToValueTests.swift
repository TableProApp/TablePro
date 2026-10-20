//
//  DataGridSetCellsToValueTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class CellsToValueLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class CellsToValueRowStore {
    var tableRows: TableRows

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }
}

@MainActor
private final class CellsToValueUndoWindow: NSWindow {
    let undo = UndoManager()

    override var undoManager: UndoManager? { undo }
}

@MainActor
private final class OwnCommandDelegate: DataGridViewDelegate {
    private(set) var handedTargets: [[SetValueTarget]] = []

    func dataGridSetCellsToValue(_ targets: [SetValueTarget]) -> Bool {
        handedTargets.append(targets)
        return true
    }
}

@MainActor
private struct CellsToValueFixture {
    static let columns = ["id", "note", "label", "seen", "born", "calc", "payload"]
    static let id = 0
    static let note = 1
    static let label = 2
    static let seen = 3
    static let born = 4
    static let calc = 5
    static let payload = 6

    let manager: DataChangeManager
    let coordinator: TableViewCoordinator
    let store: CellsToValueRowStore

    init(rowCount: Int = 4, selectedRows: Set<Int> = []) {
        manager = DataChangeManager()
        manager.configureForTable(
            tableName: "things",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: ["calc"]
        )
        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(manager),
            isEditable: true,
            selectedRowIndices: .constant(selectedRows),
            delegate: nil,
            layoutPersister: CellsToValueLayoutPersister()
        )
        let rows: [[PluginCellValue]] = (0..<rowCount).map { row in
            [
                .text("00000000-0000-0000-0000-00000000000\(row)"),
                .text("n\(row)"),
                .text("l\(row)"),
                .text("2024-01-0\(row + 1) 10:00:00+00"),
                .text("2024-01-0\(row + 1)"),
                .text("c\(row)"),
                .null
            ]
        }
        store = CellsToValueRowStore(TableRows.from(
            queryRows: rows,
            columns: Self.columns,
            columnTypes: [
                .text(rawType: "uuid"),
                .text(rawType: "text"),
                .text(rawType: "text"),
                .timestamp(rawType: "timestamptz"),
                .date(rawType: "date"),
                .text(rawType: "text"),
                .blob(rawType: "bytea")
            ],
            columnNullable: [
                "id": false, "note": true, "label": false, "seen": true, "born": false, "calc": true, "payload": true
            ]
        ))
        let store = store
        coordinator.tableRowsProvider = { store.tableRows }
        coordinator.tableRowsMutator = { mutation in mutation(&store.tableRows) }
        coordinator.databaseType = .postgresql
        coordinator.rebuildColumnMetadataCache(from: store.tableRows)
        coordinator.updateCache()
    }

    func staged(row: Int, column: Int) -> PluginCellValue? {
        manager.pending.change(forRow: .existing(row), type: .update)?
            .cellChanges.first { $0.columnIndex == column }?.newValue
    }

    func select(rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        coordinator.selectionController.update(.single(
            GridRect(rows: rows, columns: columns),
            anchor: GridCoord(row: rows.lowerBound, displayColumn: columns.lowerBound),
            active: GridCoord(row: rows.upperBound, displayColumn: columns.upperBound)
        ))
    }

    func cell(_ row: Int, _ column: Int) -> SetValueTarget {
        SetValueTarget(displayRow: row, columnIndex: column)
    }

    func selectedTargets() -> [SetValueTarget] {
        coordinator.setValueTargets(clicked: nil)
    }

    func setCellsToValue(_ text: String) {
        coordinator.applyCellsToValue(text, to: coordinator.setCellsToValueCells(selectedTargets()))
    }

    func deleteRow(_ row: Int) {
        manager.recordRowDeletion(rowID: .existing(row), originalRow: Array(store.tableRows.rows[row].values))
    }

    func attachUndoWindow() -> CellsToValueUndoWindow {
        let window = CellsToValueUndoWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.undo.groupsByEvent = false
        let tableView = KeyHandlingTableView()
        window.contentView?.addSubview(tableView)
        tableView.coordinator = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        // Built through the column pool, so the selection's display positions resolve to the grid's own columns.
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: [],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 100 }
        )
        coordinator.invalidateColumnIndexCache()
        let undo = window.undo
        manager.undoManagerProvider = { undo }
        return window
    }
}

@MainActor
struct DataGridSetCellsToValueTests {
    @Test("The typed value goes into every selected cell and no other")
    func writesEverySelectedCell() {
        let fixture = CellsToValueFixture()
        fixture.select(rows: 0...2, columns: CellsToValueFixture.note...CellsToValueFixture.note)

        fixture.setCellsToValue("archived")

        for row in 0...2 {
            #expect(fixture.staged(row: row, column: CellsToValueFixture.note) == .text("archived"))
            #expect(fixture.store.tableRows.rows[row].values[CellsToValueFixture.note] == .text("archived"))
        }
        #expect(fixture.staged(row: 3, column: CellsToValueFixture.note) == nil)
        #expect(fixture.store.tableRows.rows[3].values[CellsToValueFixture.note] == .text("n3"))
        #expect(fixture.staged(row: 0, column: CellsToValueFixture.label) == nil)
    }

    @Test("A server-owned column, a binary column and a deleted row are left out of the cells it writes")
    func leavesOutCellsTypingCannotEdit() {
        let fixture = CellsToValueFixture()
        fixture.deleteRow(1)
        fixture.select(rows: 0...1, columns: CellsToValueFixture.born...CellsToValueFixture.payload)
        let targets = fixture.selectedTargets()

        let cells = fixture.coordinator.setCellsToValueCells(targets)

        #expect(targets.count == 6)
        #expect(cells == [fixture.cell(0, CellsToValueFixture.born)])
        #expect(fixture.coordinator.isSetCellsToValueOffered(for: targets))
    }

    @Test("Nothing is offered where typing could edit no cell")
    func notOfferedWithoutAnEditableCell() {
        let fixture = CellsToValueFixture()
        let readOnly = [fixture.cell(0, CellsToValueFixture.calc), fixture.cell(1, CellsToValueFixture.payload)]

        #expect(!fixture.coordinator.isSetCellsToValueOffered(for: readOnly))
        #expect(!fixture.coordinator.isSetCellsToValueOffered(for: []))

        fixture.coordinator.isEditable = false
        #expect(!fixture.coordinator.isSetCellsToValueOffered(for: [fixture.cell(0, CellsToValueFixture.note)]))
    }

    @Test("The sheet says how many cells take the value, and how many it skips")
    func impactCountsTheCells() {
        #expect(TableViewCoordinator.setCellsToValueImpact(cells: 1, targets: 1) == "This sets 1 cell.")
        #expect(TableViewCoordinator.setCellsToValueImpact(cells: 40, targets: 40) == "This sets 40 cells.")
        #expect(
            TableViewCoordinator.setCellsToValueImpact(cells: 38, targets: 40)
                == "This sets 38 of 40 cells. The others cannot be edited."
        )
    }

    @Test("Every cell it writes is one undo step, named Set Cells to Value")
    func oneUndoStep() {
        let fixture = CellsToValueFixture()
        let window = fixture.attachUndoWindow()
        defer { window.orderOut(nil) }
        fixture.select(rows: 0...3, columns: CellsToValueFixture.note...CellsToValueFixture.label)

        fixture.setCellsToValue("archived")

        #expect(window.undo.undoActionName == "Set Cells to Value")
        window.undo.undo()
        #expect(!window.undo.canUndo)
        #expect(!fixture.manager.hasChanges)
    }

    @Test("A column that holds neither the text nor NULL keeps its cells, and the others take it")
    func refusingColumnKeepsItsCells() {
        let fixture = CellsToValueFixture()
        fixture.select(rows: 0...1, columns: CellsToValueFixture.note...CellsToValueFixture.born)

        fixture.setCellsToValue("")

        #expect(fixture.staged(row: 0, column: CellsToValueFixture.note) == .text(""))
        #expect(fixture.staged(row: 1, column: CellsToValueFixture.seen) == .null)
        #expect(fixture.staged(row: 0, column: CellsToValueFixture.born) == nil)
        #expect(fixture.store.tableRows.rows[1].values[CellsToValueFixture.born] == .text("2024-01-02"))
    }

    @Test("A function name stages as SQL on a timestamp and as text on a text column, as typing it does")
    func functionIsReadPerColumn() {
        let fixture = CellsToValueFixture()
        fixture.select(rows: 0...0, columns: CellsToValueFixture.note...CellsToValueFixture.seen)

        fixture.setCellsToValue("now()")

        #expect(fixture.staged(row: 0, column: CellsToValueFixture.seen) == .text("now()"))
        #expect(fixture.manager.isExpression(rowID: .existing(0), columnIndex: CellsToValueFixture.seen))
        #expect(fixture.staged(row: 0, column: CellsToValueFixture.note) == .text("now()"))
        #expect(!fixture.manager.isExpression(rowID: .existing(0), columnIndex: CellsToValueFixture.note))
    }

    @Test("With whole rows selected the clicked column is written on each of them")
    func clickedColumnOnSelectedRows() {
        let fixture = CellsToValueFixture(selectedRows: [0, 2])
        let targets = fixture.coordinator.setValueTargets(clicked: fixture.cell(2, CellsToValueFixture.note))

        fixture.coordinator.applyCellsToValue("archived", to: fixture.coordinator.setCellsToValueCells(targets))

        #expect(fixture.staged(row: 0, column: CellsToValueFixture.note) == .text("archived"))
        #expect(fixture.staged(row: 1, column: CellsToValueFixture.note) == nil)
        #expect(fixture.staged(row: 2, column: CellsToValueFixture.note) == .text("archived"))
    }

    @Test("A window with its own Set Cells to Value runs it, and the grid stages nothing")
    func windowCommandTakesOver() {
        let fixture = CellsToValueFixture()
        let delegate = OwnCommandDelegate()
        fixture.coordinator.delegate = delegate
        fixture.select(rows: 0...1, columns: CellsToValueFixture.note...CellsToValueFixture.note)

        fixture.coordinator.setCellsToValue(fixture.selectedTargets())

        #expect(delegate.handedTargets == [[fixture.cell(0, CellsToValueFixture.note), fixture.cell(1, CellsToValueFixture.note)]])
        #expect(!fixture.manager.hasChanges)
    }

    @Test("The records under the sheet are found again after a sort or a value filter moves them")
    func recordsFollowTheirRows() throws {
        let fixture = CellsToValueFixture()
        let records = SetCellsToValueRecords(
            [fixture.cell(1, CellsToValueFixture.note), fixture.cell(3, CellsToValueFixture.label)],
            in: fixture.coordinator
        )

        fixture.coordinator.valueFilteredIDs = [.existing(3), .existing(2), .existing(1)]

        let moved = try #require(records.targets(in: fixture.coordinator))
        #expect(moved == [fixture.cell(2, CellsToValueFixture.note), fixture.cell(0, CellsToValueFixture.label)])
    }

    @Test("A load that replaces the records under the sheet drops the write")
    func replacedRecordsDropTheWrite() {
        let fixture = CellsToValueFixture()
        let records = SetCellsToValueRecords([fixture.cell(1, CellsToValueFixture.note)], in: fixture.coordinator)

        _ = fixture.store.tableRows.edit(row: 1, column: CellsToValueFixture.label, value: .text("reloaded"))

        #expect(records.targets(in: fixture.coordinator) == nil)
    }

    @Test("A record a value filter now hides drops the write")
    func hiddenRecordDropsTheWrite() {
        let fixture = CellsToValueFixture()
        let records = SetCellsToValueRecords([fixture.cell(1, CellsToValueFixture.note)], in: fixture.coordinator)

        fixture.coordinator.valueFilteredIDs = [.existing(0), .existing(2)]

        #expect(records.targets(in: fixture.coordinator) == nil)
    }
}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct DataGridPasteIntoSelectionTests {
        @Test("One pasted value goes into every selected cell, as one undo step")
        func singleValueFillsTheSelection() throws {
            let clipboard = try #require(RecordingClipboard.current)
            clipboard.text = "archived"
            let fixture = CellsToValueFixture()
            let window = fixture.attachUndoWindow()
            defer { window.orderOut(nil) }
            fixture.select(rows: 0...2, columns: CellsToValueFixture.note...CellsToValueFixture.label)

            #expect(fixture.coordinator.pasteValueIntoSelectedCells())

            for row in 0...2 {
                #expect(fixture.staged(row: row, column: CellsToValueFixture.note) == .text("archived"))
                #expect(fixture.staged(row: row, column: CellsToValueFixture.label) == .text("archived"))
            }
            #expect(fixture.staged(row: 3, column: CellsToValueFixture.note) == nil)
            #expect(window.undo.undoActionName == "Paste Cells")
            window.undo.undo()
            #expect(!fixture.manager.hasChanges)
        }

        @Test("Paste in the grid fills a cell selection rather than only the focused cell")
        func pasteCommandFillsTheSelection() throws {
            try #require(RecordingClipboard.current).text = "archived"
            let fixture = CellsToValueFixture()
            let window = fixture.attachUndoWindow()
            defer { window.orderOut(nil) }
            let tableView = try #require(fixture.coordinator.tableView as? KeyHandlingTableView)
            fixture.select(rows: 1...2, columns: CellsToValueFixture.note...CellsToValueFixture.note)

            tableView.paste(nil)

            #expect(fixture.staged(row: 1, column: CellsToValueFixture.note) == .text("archived"))
            #expect(fixture.staged(row: 2, column: CellsToValueFixture.note) == .text("archived"))
            #expect(fixture.staged(row: 0, column: CellsToValueFixture.note) == nil)
        }

        @Test("A NULL copied from the grid fills nullable cells and leaves a NOT NULL column alone")
        func copiedNullFillsWhereItFits() throws {
            let fixture = CellsToValueFixture()
            fixture.coordinator.copyCellValue(at: 0, columnIndex: CellsToValueFixture.payload)
            #expect(try #require(RecordingClipboard.current).gridCells?.fields == [[nil]])
            fixture.select(rows: 1...2, columns: CellsToValueFixture.note...CellsToValueFixture.label)

            #expect(fixture.coordinator.pasteValueIntoSelectedCells())

            #expect(fixture.staged(row: 1, column: CellsToValueFixture.note) == .null)
            #expect(fixture.staged(row: 2, column: CellsToValueFixture.note) == .null)
            #expect(fixture.staged(row: 1, column: CellsToValueFixture.label) == nil)
            #expect(fixture.store.tableRows.rows[2].values[CellsToValueFixture.label] == .text("l2"))
        }

        @Test("A block, or a single selected cell, keeps the paste anchored at the focused cell")
        func blockOrOneCellKeepsTheAnchor() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let fixture = CellsToValueFixture()

            clipboard.text = "a\tb"
            fixture.select(rows: 0...1, columns: CellsToValueFixture.note...CellsToValueFixture.label)
            #expect(!fixture.coordinator.canPasteValueIntoSelectedCells())
            #expect(!fixture.coordinator.pasteValueIntoSelectedCells())

            clipboard.text = "a"
            fixture.select(rows: 0...0, columns: CellsToValueFixture.note...CellsToValueFixture.note)
            #expect(!fixture.coordinator.canPasteValueIntoSelectedCells())
            #expect(!fixture.coordinator.pasteValueIntoSelectedCells())

            fixture.coordinator.selectionController.clear()
            #expect(!fixture.coordinator.pasteValueIntoSelectedCells())
            #expect(!fixture.manager.hasChanges)
        }

        @Test("Paste is enabled over a cell selection with no focused cell when one value is on the clipboard")
        func pasteIsEnabledWithoutAFocusedCell() throws {
            try #require(RecordingClipboard.current).text = "archived"
            let fixture = CellsToValueFixture()
            let window = fixture.attachUndoWindow()
            defer { window.orderOut(nil) }
            let tableView = try #require(fixture.coordinator.tableView as? KeyHandlingTableView)
            fixture.select(rows: 0...3, columns: CellsToValueFixture.note...CellsToValueFixture.note)
            tableView.focusedRow = -1
            tableView.focusedColumn = -1
            let paste = NSMenuItem(title: "", action: #selector(KeyHandlingTableView.paste(_:)), keyEquivalent: "")

            #expect(fixture.coordinator.canPasteValueIntoSelectedCells())
            #expect(tableView.validateUserInterfaceItem(paste))
        }
    }
}
