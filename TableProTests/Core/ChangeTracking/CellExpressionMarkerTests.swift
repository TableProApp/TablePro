//
//  CellExpressionMarkerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct CellExpressionPendingChangesTests {
    private let row = RowID.existing(0)

    @Test("An expression over stored text that reads the same is a change")
    func expressionOverEqualTextIsAChange() throws {
        var pending = PendingChanges()

        let recorded = pending.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "note", oldValue: "now()", newValue: "now()",
            originalRow: ["1", "Ada", "now()"], isExpression: true
        )

        #expect(recorded)
        let cell = try #require(pending.changes.first?.cellChanges.first)
        #expect(cell.newIsExpression && !cell.oldIsExpression)
        #expect(pending.isExpression(rowID: row, columnIndex: 2))
        #expect(pending.expressionColumns(forRow: row) == [2])
    }

    @Test("Setting the stored text back over the expression leaves nothing pending")
    func textBackOverExpressionCollapses() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "note", oldValue: "now()", newValue: "now()", isExpression: true
        )
        pending.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "note", oldValue: "now()", newValue: "now()", isExpression: false
        )

        #expect(pending.isEmpty)
    }

    @Test("The same expression set twice is a no-op the second time")
    func sameExpressionTwiceIsANoOp() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "at", oldValue: "2026-01-01", newValue: "now()", isExpression: true
        )
        let second = pending.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "at", oldValue: "now()", newValue: "now()", isExpression: true
        )

        #expect(!second)
        #expect(pending.isExpression(rowID: row, columnIndex: 2))
    }

    @Test("A new row's cell takes and drops the mark with each edit")
    func insertedCellFollowsEachEdit() {
        var pending = PendingChanges()
        let inserted = RowID.inserted(UUID())
        pending.recordRowInsertion(rowID: inserted, values: ["1", .null, .null])

        pending.recordCellChange(
            rowID: inserted, columnIndex: 2, columnName: "at", oldValue: .null, newValue: "now()", isExpression: true
        )
        #expect(pending.insertedExpressionColumns(forRow: inserted) == [2])
        #expect(pending.insertedRowData[inserted]?[2] == "now()")

        pending.recordCellChange(
            rowID: inserted, columnIndex: 2, columnName: "at", oldValue: "now()", newValue: "2026-01-01"
        )
        #expect(pending.insertedExpressionColumns(forRow: inserted).isEmpty)
    }

    @Test("Recording a new row again replaces its marks with the new ones")
    func reRecordReplacesMarks() {
        var pending = PendingChanges()
        let inserted = RowID.inserted(UUID())
        pending.recordRowInsertion(rowID: inserted, values: ["1", "now()"], expressionColumns: [1])
        pending.recordRowInsertion(rowID: inserted, values: ["1", "x"])

        #expect(pending.insertedExpressionColumns(forRow: inserted).isEmpty)
    }

    @Test("Removing an earlier change keeps a later row's marks with that row")
    func swapRemoveKeepsMarks() {
        var pending = PendingChanges()
        let first = RowID.inserted(UUID())
        let second = RowID.inserted(UUID())
        pending.recordRowInsertion(rowID: first, values: ["1"])
        pending.recordRowInsertion(rowID: second, values: ["now()"], expressionColumns: [0])

        let removed = pending.undoRowInsertion(rowID: first)

        #expect(removed)
        #expect(pending.insertedExpressionColumns(forRow: second) == [0])
    }
}

@MainActor
struct CellExpressionUndoTests {
    private func manager(databaseType: DatabaseType = .postgresql) -> (DataChangeManager, UndoManager) {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "events",
            columns: ["id", "name", "at"],
            primaryKeyColumns: ["id"],
            databaseType: databaseType,
            generatedColumns: []
        )
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        return (manager, undoManager)
    }

    private let row = RowID.existing(0)
    private let original: [PluginCellValue] = ["1", "Ada", "2026-01-01"]

    @Test("Undo takes the expression away and redo puts it back as an expression")
    func undoAndRedo() throws {
        let (manager, undoManager) = manager()
        manager.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "at", oldValue: "2026-01-01", newValue: "now()",
            originalRow: original, absence: FieldAbsence(), isExpression: true
        )
        #expect(manager.isExpression(rowID: row, columnIndex: 2))

        undoManager.undo()
        #expect(!manager.hasChanges)
        #expect(!manager.isExpression(rowID: row, columnIndex: 2))

        undoManager.redo()
        let cell = try #require(manager.changes.first?.cellChanges.first)
        #expect(cell.newValue == "now()")
        #expect(cell.newIsExpression)
        #expect(cell.oldValue == "2026-01-01")
    }

    @Test("Undoing an expression set over pending text brings the text back as text")
    func undoOverPendingText() throws {
        let (manager, undoManager) = manager()
        manager.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "at", oldValue: "2026-01-01", newValue: "now()",
            originalRow: original
        )
        manager.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "at", oldValue: "now()", newValue: "now()",
            originalRow: original, absence: FieldAbsence(), isExpression: true
        )
        #expect(manager.isExpression(rowID: row, columnIndex: 2))

        undoManager.undo()
        let text = try #require(manager.changes.first?.cellChanges.first)
        #expect(text.newValue == "now()")
        #expect(!text.newIsExpression)

        undoManager.redo()
        #expect(manager.isExpression(rowID: row, columnIndex: 2))
    }

    @Test("A typed run that ends on an expression undoes as one step and redoes the expression")
    func coalescedRun() {
        let (manager, undoManager) = manager()
        manager.recordTypedCellChange(
            rowID: row, columnIndex: 2, columnName: "at", oldValue: "2026-01-01", newValue: "n", originalRow: original
        )
        manager.recordTypedCellChange(
            rowID: row, columnIndex: 2, columnName: "at", oldValue: "n", newValue: "now()", originalRow: original,
            isExpression: true
        )
        manager.endCoalescedUndoRun()
        #expect(manager.isExpression(rowID: row, columnIndex: 2))

        undoManager.undo()
        #expect(!manager.hasChanges)

        undoManager.redo()
        #expect(manager.isExpression(rowID: row, columnIndex: 2))
        #expect(manager.changes.first?.cellChanges.first?.newValue == "now()")
    }

    @Test("A typed run that only turns text into the same expression still registers a step")
    func coalescedRunExpressionOnly() {
        let (manager, undoManager) = manager()
        manager.recordTypedCellChange(
            rowID: row, columnIndex: 1, columnName: "name", oldValue: "now()", newValue: "now()",
            originalRow: ["1", "now()", "2026-01-01"], isExpression: true
        )
        manager.endCoalescedUndoRun()

        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(!manager.hasChanges)
    }

    @Test("Undoing and redoing a new row keeps its expression cells")
    func rowInsertionRedo() {
        let (manager, undoManager) = manager()
        let inserted = RowID.inserted(UUID())
        manager.recordRowInsertion(rowID: inserted, values: ["1", "Ada", "now()"], expressionColumns: [2])

        undoManager.undo()
        #expect(!manager.isRowInserted(inserted))

        undoManager.redo()
        #expect(manager.pending.insertedExpressionColumns(forRow: inserted) == [2])
        #expect(manager.expressionColumns(forRow: inserted) == [2])
    }

    @Test("Undoing the removal of several new rows brings back their expression cells")
    func batchInsertionUndo() {
        let (manager, undoManager) = manager()
        let first = RowID.inserted(UUID())
        let second = RowID.inserted(UUID())
        manager.recordRowInsertion(rowID: first, values: ["1", "Ada", "now()"], expressionColumns: [2])
        manager.recordRowInsertion(rowID: second, values: ["2", "Grace", "2026-01-01"])

        manager.undoBatchRowInsertion(rows: [
            InsertedRowLocation(rowID: first, storageIndex: 0),
            InsertedRowLocation(rowID: second, storageIndex: 1),
        ])
        #expect(!manager.isRowInserted(first))

        undoManager.undo()
        #expect(manager.pending.insertedExpressionColumns(forRow: first) == [2])
        #expect(manager.pending.insertedExpressionColumns(forRow: second).isEmpty)
    }

    @Test("A marked cell is written as the SQL, an unmarked one with the same text is bound")
    func statements() throws {
        let (manager, _) = manager()
        manager.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "at", oldValue: "2026-01-01", newValue: "now()",
            originalRow: original, absence: FieldAbsence(), isExpression: true
        )
        manager.recordCellChange(
            rowID: .existing(1), columnIndex: 1, columnName: "name", oldValue: "Ada", newValue: "now()",
            originalRow: ["2", "Ada", "2026-01-01"]
        )

        let statements = try manager.generateSQL()

        #expect(statements.count == 2)
        let marked = try #require(statements.first { $0.sql.contains("\"at\"") })
        #expect(marked.sql.contains("\"at\" = now()"))
        #expect(marked.parameters.count == 1)
        let literal = try #require(statements.first { $0.sql.contains("\"name\"") })
        #expect(literal.sql.contains("\"name\" = $1"))
        #expect(literal.parameters.first as? String == "now()")
    }

    @Test("An expression over stored text that reads the same still saves the expression")
    func expressionOverEqualStoredText() throws {
        let (manager, _) = manager()
        manager.recordCellChange(
            rowID: row, columnIndex: 2, columnName: "at", oldValue: "now()", newValue: "now()",
            originalRow: ["1", "Ada", "now()"], absence: FieldAbsence(), isExpression: true
        )

        let statements = try manager.generateSQL()

        #expect(statements.count == 1)
        #expect(statements.first?.sql.contains("\"at\" = now()") == true)
    }

    @Test("A new row's marked cell goes into the INSERT as written")
    func insertStatement() throws {
        let (manager, _) = manager()
        manager.recordRowInsertion(rowID: .inserted(UUID()), values: ["1", "now()", "now()"], expressionColumns: [2])

        let statements = try manager.generateSQL()

        let insert = try #require(statements.first)
        #expect(insert.sql.contains("VALUES ($1, $2, now())"))
        #expect(insert.parameters.count == 2)
        #expect(insert.parameters.last as? String == "now()")
    }

    @Test("The host writes both, a driver only what its capabilities say")
    func writerSupport() {
        let (manager, _) = manager()
        #expect(manager.cellWriterSupport == .host)

        manager.pluginDriver = CapabilityStubDriver(capabilities: [])
        #expect(manager.cellWriterSupport == .none)

        manager.pluginDriver = CapabilityStubDriver(capabilities: [.cellExpressions])
        #expect(manager.cellWriterSupport == CellWriterSupport(acceptsExpressions: true, acceptsUUIDText: false))

        manager.pluginDriver = CapabilityStubDriver(capabilities: [.cellExpressions, .uuidCellText])
        #expect(manager.cellWriterSupport == .host)
    }
}

private final class CapabilityStubDriver: PluginDriverStub, @unchecked Sendable {
    let capabilities: PluginCapabilities

    init(capabilities: PluginCapabilities) {
        self.capabilities = capabilities
    }
}
