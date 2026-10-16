//
//  DataGridSetValueTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class SetValueLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class SetValueRowStore {
    var tableRows: TableRows

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }
}

/// The app hands the change manager the window's undo manager, so the grid's group and the cells' steps share one.
@MainActor
private final class SetValueUndoWindow: NSWindow {
    let undo = UndoManager()

    override var undoManager: UndoManager? { undo }
}

private final class NoCapabilityDriver: PluginDriverStub, @unchecked Sendable {}

@MainActor
private struct SetValueFixture {
    static let columns = ["id", "ref", "note", "label", "seen"]
    static let id = 0
    static let ref = 1
    static let note = 2
    static let label = 3
    static let seen = 4

    let manager: DataChangeManager
    let coordinator: TableViewCoordinator
    let store: SetValueRowStore

    init(selectedRows: Set<Int> = [], rowCount: Int = 3) {
        manager = DataChangeManager()
        manager.configureForTable(
            tableName: "things",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )
        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(manager),
            isEditable: true,
            selectedRowIndices: .constant(selectedRows),
            delegate: nil,
            layoutPersister: SetValueLayoutPersister()
        )
        let rows: [[PluginCellValue]] = (0..<rowCount).map { row in
            [.null, .null, .text("n\(row)"), .text("l\(row)"), .text("2024-01-0\(row + 1) 10:00:00+00")]
        }
        store = SetValueRowStore(TableRows.from(
            queryRows: rows,
            columns: Self.columns,
            columnTypes: [
                .text(rawType: "uuid"),
                .text(rawType: "uuid"),
                .text(rawType: "text"),
                .text(rawType: "text"),
                .timestamp(rawType: "timestamptz")
            ],
            columnNullable: ["id": false, "ref": true, "note": true, "label": false, "seen": true]
        ))
        let store = store
        coordinator.tableRowsProvider = { store.tableRows }
        coordinator.tableRowsMutator = { mutation in mutation(&store.tableRows) }
        coordinator.databaseType = .postgresql
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

    func attachUndoWindow() -> SetValueUndoWindow {
        let window = SetValueUndoWindow(
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
        coordinator.tableView = tableView
        let undo = window.undo
        manager.undoManagerProvider = { undo }
        return window
    }
}

@MainActor
struct DataGridSetValueTests {
    @Test("Generate UUID over a cell selection writes a different UUID into every cell")
    func uuidPerSelectedCell() throws {
        let fixture = SetValueFixture()
        fixture.select(rows: 0...2, columns: SetValueFixture.id...SetValueFixture.ref)

        fixture.coordinator.applySetValue(.uuid(.v4), to: fixture.coordinator.setValueTargets(clicked: nil))

        var written: [String] = []
        for row in 0..<3 {
            for column in [SetValueFixture.id, SetValueFixture.ref] {
                let text = try #require(fixture.staged(row: row, column: column)?.asText)
                #expect(UUID(uuidString: text) != nil)
                #expect(text == text.lowercased())
                written.append(text)
            }
        }
        #expect(Set(written).count == 6)
    }

    @Test("Generate UUID on an empty CHAR column the UUID format marks takes the length its schema declares")
    func uuidTakesTheSchemaLength() throws {
        let fixture = SetValueFixture()
        fixture.store.tableRows.columnTypes[SetValueFixture.ref] = .text(rawType: "CHAR")
        fixture.store.tableRows.columnDeclaredTypes = ["ref": "CHAR(32)"]
        fixture.coordinator.syncDisplayFormats([nil, .uuid, nil, nil, nil])

        fixture.coordinator.applySetValue(.uuid(.v4), to: [fixture.cell(0, SetValueFixture.ref)])

        let text = try #require(fixture.staged(row: 0, column: SetValueFixture.ref)?.asText)
        #expect(text.count == 32)
        #expect(text.allSatisfy { $0.isHexDigit })
    }

    @Test("A Set Value over many cells is one undo step, named for the command")
    func oneUndoStep() {
        let fixture = SetValueFixture()
        let window = fixture.attachUndoWindow()
        defer { window.orderOut(nil) }
        let targets = (0..<3).map { fixture.cell($0, SetValueFixture.id) }

        fixture.coordinator.applySetValue(.uuid(.v7), to: targets)

        #expect(window.undo.undoActionName == "Generate UUIDv7")
        window.undo.undo()
        #expect(!window.undo.canUndo)
        #expect(!fixture.manager.hasChanges)
    }

    @Test("NULL over a selection is an undo step named Set Value")
    func nullUndoName() {
        let fixture = SetValueFixture()
        let window = fixture.attachUndoWindow()
        defer { window.orderOut(nil) }

        fixture.coordinator.applySetValue(
            .null, to: [fixture.cell(0, SetValueFixture.note), fixture.cell(1, SetValueFixture.note)]
        )

        #expect(window.undo.undoActionName == "Set Value")
    }

    @Test("Without a cell selection the clicked column is written on every selected row")
    func clickedColumnAcrossSelectedRows() {
        let fixture = SetValueFixture(selectedRows: [0, 2])

        let onSelectedRow = fixture.coordinator.setValueTargets(clicked: fixture.cell(2, SetValueFixture.note))
        let onOtherRow = fixture.coordinator.setValueTargets(clicked: fixture.cell(1, SetValueFixture.note))

        #expect(onSelectedRow == [fixture.cell(0, SetValueFixture.note), fixture.cell(2, SetValueFixture.note)])
        #expect(onOtherRow == [fixture.cell(1, SetValueFixture.note)])
    }

    @Test("A click inside the cell selection acts on the selection, a click outside it on the clicked cell")
    func clickInsideOrOutsideSelection() {
        let fixture = SetValueFixture()
        fixture.select(rows: 0...1, columns: SetValueFixture.note...SetValueFixture.note)

        let inside = fixture.coordinator.setValueTargets(clicked: fixture.cell(1, SetValueFixture.note))
        let outside = fixture.coordinator.setValueTargets(clicked: fixture.cell(2, SetValueFixture.label))

        #expect(inside == [fixture.cell(0, SetValueFixture.note), fixture.cell(1, SetValueFixture.note)])
        #expect(outside == [fixture.cell(2, SetValueFixture.label)])
    }

    @Test("Cells that do not take the command, and deleted rows, are left as they were")
    func skipsCellsTheCommandDoesNotFit() {
        let fixture = SetValueFixture()
        fixture.manager.recordRowDeletion(
            rowID: .existing(1), originalRow: Array(fixture.store.tableRows.rows[1].values)
        )
        fixture.select(rows: 0...2, columns: SetValueFixture.note...SetValueFixture.label)

        fixture.coordinator.applySetValue(.null, to: fixture.coordinator.setValueTargets(clicked: nil))

        #expect(fixture.staged(row: 0, column: SetValueFixture.note) == .null)
        #expect(fixture.staged(row: 2, column: SetValueFixture.note) == .null)
        #expect(fixture.staged(row: 0, column: SetValueFixture.label) == nil)
        #expect(fixture.store.tableRows.rows[1].values[SetValueFixture.note] == .text("n1"))
        #expect(fixture.store.tableRows.rows[0].values[SetValueFixture.label] == .text("l0"))
    }

    @Test("A selection offers every command one of its cells takes, in menu order")
    func offeredCommandsAreTheUnion() {
        let fixture = SetValueFixture()
        fixture.select(rows: 0...0, columns: SetValueFixture.id...SetValueFixture.note)
        let targets = fixture.coordinator.setValueTargets(clicked: nil)

        #expect(fixture.coordinator.setValueCommands(for: targets) == [.empty, .null, .uuid(.v4), .uuid(.v7)])
        #expect(fixture.coordinator.isSetValueOffered(.uuid(.v4), for: targets))
        #expect(!fixture.coordinator.isSetValueOffered(.defaultValue, for: targets))
    }

    @Test("A function chosen from Set Value is staged as SQL, not as text")
    func expressionIsMarked() throws {
        let fixture = SetValueFixture()
        let now = try #require(
            CellExpressionVocabulary.expressions(for: .postgresql, columnType: .timestamp(rawType: "timestamptz"))
                .first { $0.sql == "now()" }
        )

        fixture.coordinator.applySetValue(.expression(now), to: [fixture.cell(0, SetValueFixture.seen)])

        #expect(fixture.staged(row: 0, column: SetValueFixture.seen) == .text("now()"))
        #expect(fixture.manager.isExpression(rowID: .existing(0), columnIndex: SetValueFixture.seen))
    }

    @Test("Typing a function into a timestamp stages its SQL, and the same text in a text cell stays text")
    func typedFunctionIsPromotedOnlyWhereItFits() {
        let fixture = SetValueFixture()

        fixture.coordinator.commitCellEdit(row: 0, columnIndex: SetValueFixture.seen, newValue: " NOW() ")
        fixture.coordinator.commitCellEdit(row: 0, columnIndex: SetValueFixture.note, newValue: "NOW()")

        #expect(fixture.staged(row: 0, column: SetValueFixture.seen) == .text("now()"))
        #expect(fixture.manager.isExpression(rowID: .existing(0), columnIndex: SetValueFixture.seen))
        #expect(fixture.staged(row: 0, column: SetValueFixture.note) == .text("NOW()"))
        #expect(!fixture.manager.isExpression(rowID: .existing(0), columnIndex: SetValueFixture.note))
    }

    @Test("A driver that does not write SQL into cells gets typed text as it was typed")
    func typedFunctionStaysLiteralForAnOldDriver() {
        let fixture = SetValueFixture()
        fixture.manager.pluginDriver = NoCapabilityDriver()

        fixture.coordinator.commitCellEdit(row: 0, columnIndex: SetValueFixture.seen, newValue: "NOW()")

        #expect(fixture.staged(row: 0, column: SetValueFixture.seen) == .text("NOW()"))
        #expect(!fixture.manager.isExpression(rowID: .existing(0), columnIndex: SetValueFixture.seen))
    }

    @Test("The same text as a literal over a staged function is an edit")
    func literalOverExpressionIsAnEdit() throws {
        let fixture = SetValueFixture()
        fixture.coordinator.commitCellEdit(row: 0, columnIndex: SetValueFixture.seen, newValue: "now()")
        #expect(fixture.manager.isExpression(rowID: .existing(0), columnIndex: SetValueFixture.seen))

        fixture.manager.pluginDriver = NoCapabilityDriver()
        fixture.coordinator.commitCellEdit(row: 0, columnIndex: SetValueFixture.seen, newValue: "now()")

        #expect(!fixture.manager.isExpression(rowID: .existing(0), columnIndex: SetValueFixture.seen))
        #expect(fixture.staged(row: 0, column: SetValueFixture.seen) == .text("now()"))
    }
}

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct DataGridSetValuePasteTests {
        @Test("A function name pasted into a timestamp cell stages its SQL")
        func pastedFunctionIsPromoted() throws {
            let clipboard = try #require(RecordingClipboard.current)
            clipboard.text = "current_timestamp"
            let fixture = SetValueFixture()

            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 1, anchorColumn: SetValueFixture.seen))

            #expect(fixture.staged(row: 1, column: SetValueFixture.seen) == .text("CURRENT_TIMESTAMP"))
            #expect(fixture.manager.isExpression(rowID: .existing(1), columnIndex: SetValueFixture.seen))
        }

        @Test("A staged function copied from the grid pastes as SQL, whichever column it lands in")
        func copiedExpressionPastesAsSQL() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let fixture = SetValueFixture()
            let now = try #require(
                CellExpressionVocabulary.expressions(for: .postgresql, columnType: .timestamp(rawType: "timestamptz"))
                    .first { $0.sql == "now()" }
            )
            fixture.coordinator.applySetValue(.expression(now), to: [fixture.cell(0, SetValueFixture.seen)])

            fixture.coordinator.copyCellValue(at: 0, columnIndex: SetValueFixture.seen)
            #expect(clipboard.gridCells?.expressionFields == [0: [0]])
            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 1, anchorColumn: SetValueFixture.note))

            #expect(fixture.staged(row: 1, column: SetValueFixture.note) == .text("now()"))
            #expect(fixture.manager.isExpression(rowID: .existing(1), columnIndex: SetValueFixture.note))
        }

        @Test("Stored text that spells a function, copied from the grid, pastes as the same text")
        func copiedLiteralIsNotPromoted() throws {
            let fixture = SetValueFixture()
            _ = fixture.store.tableRows.edit(row: 0, column: SetValueFixture.seen, value: .text("CURRENT_TIMESTAMP"))

            fixture.coordinator.copyCellValue(at: 0, columnIndex: SetValueFixture.seen)
            #expect(try #require(RecordingClipboard.current).gridCells?.expressionFields == nil)
            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 1, anchorColumn: SetValueFixture.seen))

            #expect(fixture.staged(row: 1, column: SetValueFixture.seen) == .text("CURRENT_TIMESTAMP"))
            #expect(!fixture.manager.isExpression(rowID: .existing(1), columnIndex: SetValueFixture.seen))
        }

        @Test("A copied block marks only the fields that held staged SQL")
        func copiedBlockMarksEachField() throws {
            let clipboard = try #require(RecordingClipboard.current)
            let fixture = SetValueFixture()
            fixture.coordinator.commitCellEdit(row: 0, columnIndex: SetValueFixture.seen, newValue: "now()")
            fixture.select(rows: 0...0, columns: SetValueFixture.note...SetValueFixture.seen)

            fixture.coordinator.copyGridSelection(fixture.coordinator.selectionController.selection)
            #expect(clipboard.gridCells?.fields == [["n0", "l0", "now()"]])
            #expect(clipboard.gridCells?.expressionFields == [0: [2]])
            #expect(fixture.coordinator.pasteCellsFromClipboard(anchorRow: 2, anchorColumn: SetValueFixture.note))

            #expect(fixture.manager.isExpression(rowID: .existing(2), columnIndex: SetValueFixture.seen))
            #expect(!fixture.manager.isExpression(rowID: .existing(2), columnIndex: SetValueFixture.note))
        }
    }
}
