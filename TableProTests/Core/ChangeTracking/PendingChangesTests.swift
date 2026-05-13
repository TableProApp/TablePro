//
//  PendingChangesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("PendingChanges - record")
struct PendingChangesRecordTests {
    @Test("Empty by default")
    func emptyByDefault() {
        let pending = PendingChanges()
        #expect(pending.isEmpty)
        #expect(pending.changes.isEmpty)
    }

    @Test("Recording cell edit creates an update change")
    func recordCellCreatesUpdate() {
        var pending = PendingChanges()
        let recorded = pending.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        #expect(recorded == true)
        #expect(pending.changes.count == 1)
        #expect(pending.changes[0].type == .update)
        #expect(pending.isCellModified(rowIndex: 0, columnIndex: 1))
        #expect(pending.modifiedColumns(forRow: 0) == [1])
    }

    @Test("No-op edit when oldValue equals newValue and no prior change")
    func noOpEdit() {
        var pending = PendingChanges()
        let recorded = pending.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "a"
        )
        #expect(recorded == false)
        #expect(pending.isEmpty)
    }

    @Test("Editing back to original value collapses the change")
    func revertToOriginalCollapses() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        let collapsed = pending.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "b", newValue: "a"
        )
        #expect(collapsed == true)
        #expect(pending.isEmpty)
        #expect(!pending.isCellModified(rowIndex: 0, columnIndex: 1))
    }

    @Test("Recording row deletion adds delete change and marks row deleted")
    func recordRowDeletion() {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowIndex: 5, originalRow: ["a", "b"])
        #expect(pending.isRowDeleted(5))
        #expect(pending.changes.count == 1)
        #expect(pending.changes[0].type == .delete)
    }

    @Test("Deleting a row clears its prior cell edits")
    func deletionRemovesUpdate() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        pending.recordRowDeletion(rowIndex: 0, originalRow: ["a", nil])
        #expect(pending.changes.count == 1)
        #expect(pending.changes[0].type == .delete)
        #expect(!pending.isCellModified(rowIndex: 0, columnIndex: 1))
    }

    @Test("Recording row insertion marks row inserted")
    func recordRowInsertion() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowIndex: 3, values: ["x", "y"])
        #expect(pending.isRowInserted(3))
        #expect(pending.savedInsertedValues(forRow: 3) == ["x", "y"])
    }

    @Test("Double deletion of the same row is idempotent")
    func doubleDeletionIsIdempotent() {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowIndex: 5, originalRow: ["a"])
        pending.recordRowDeletion(rowIndex: 5, originalRow: ["a"])
        #expect(pending.changes.count == 1)
        #expect(pending.isRowDeleted(5))
    }

    @Test("Double insertion of the same row updates stored values without duplicating")
    func doubleInsertionIsIdempotent() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowIndex: 3, values: ["x"])
        pending.recordRowInsertion(rowIndex: 3, values: ["y"])
        #expect(pending.changes.count == 1)
        #expect(pending.isRowInserted(3))
        #expect(pending.savedInsertedValues(forRow: 3) == ["y"])
    }
}

@Suite("PendingChanges - undo")
struct PendingChangesUndoTests {
    @Test("Undo row deletion clears delete state")
    func undoRowDeletion() {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowIndex: 0, originalRow: ["a"])
        let undone = pending.undoRowDeletion(rowIndex: 0)
        #expect(undone == true)
        #expect(!pending.isRowDeleted(0))
        #expect(pending.isEmpty)
    }

    @Test("Undo row insertion shifts later inserted rows down")
    func undoRowInsertionShiftsOthers() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowIndex: 1, values: ["a"])
        pending.recordRowInsertion(rowIndex: 2, values: ["b"])
        pending.recordRowInsertion(rowIndex: 3, values: ["c"])

        let undone = pending.undoRowInsertion(rowIndex: 2)
        #expect(undone == true)
        #expect(pending.isRowInserted(1))
        #expect(pending.isRowInserted(2))
        #expect(!pending.isRowInserted(3))
    }

    @Test("Undo on row that was not inserted is a no-op")
    func undoNonexistentInsertion() {
        var pending = PendingChanges()
        let undone = pending.undoRowInsertion(rowIndex: 99)
        #expect(undone == false)
    }

    @Test("Undo batch row insertion returns saved values in order")
    func undoBatchRowInsertion() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowIndex: 1, values: ["a"])
        pending.recordRowInsertion(rowIndex: 2, values: ["b"])
        pending.recordRowInsertion(rowIndex: 3, values: ["c"])

        let restored = pending.undoBatchRowInsertion(rowIndices: [1, 2, 3], columnCount: 1)
        #expect(restored.count == 3)
        #expect(!pending.isRowInserted(1))
        #expect(!pending.isRowInserted(2))
        #expect(!pending.isRowInserted(3))
    }
}

@Suite("PendingChanges - replay")
struct PendingChangesReplayTests {
    @Test("Reapply cell change with no existing change")
    func reapplyCellWithoutExisting() {
        var pending = PendingChanges()
        pending.reapplyCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            originalDBValue: "orig", newValue: "x", originalRow: nil
        )
        #expect(pending.isCellModified(rowIndex: 0, columnIndex: 1))
        #expect(pending.changes[0].cellChanges[0].oldValue == "orig")
    }

    @Test("Reapply cell change preserves the original DB value as oldValue")
    func reapplyCellPreservesOriginalDBValue() {
        var pending = PendingChanges()
        pending.reapplyCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            originalDBValue: "Alice", newValue: "Bob", originalRow: nil
        )
        let cellChange = pending.changes[0].cellChanges[0]
        #expect(cellChange.oldValue == "Alice")
        #expect(cellChange.newValue == "Bob")
    }

    @Test("Reinsert row creates insert change with saved values")
    func reinsertRowFromUndo() {
        var pending = PendingChanges()
        pending.reinsertRow(rowIndex: 2, columns: ["a", "b"], savedValues: ["x", "y"])
        #expect(pending.isRowInserted(2))
        #expect(pending.savedInsertedValues(forRow: 2) == ["x", "y"])
    }

    @Test("Reapply row deletion adds delete change")
    func reapplyDeletion() {
        var pending = PendingChanges()
        pending.reapplyRowDeletion(rowIndex: 0, originalRow: ["a", "b"])
        #expect(pending.isRowDeleted(0))
    }
}

@Suite("PendingChanges - snapshot")
struct PendingChangesSnapshotTests {
    @Test("Snapshot round-trip preserves state")
    func snapshotRoundTrip() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        pending.recordRowDeletion(rowIndex: 5, originalRow: ["x"])
        pending.recordRowInsertion(rowIndex: 7, values: ["new"])

        let snapshot = pending.snapshot(primaryKeyColumns: ["id"], columns: ["id", "name"])

        var restored = PendingChanges()
        restored.restore(from: snapshot)

        #expect(restored.changes.count == pending.changes.count)
        #expect(restored.isRowDeleted(5))
        #expect(restored.isRowInserted(7))
        #expect(restored.isCellModified(rowIndex: 0, columnIndex: 1))
    }
}

@Suite("PendingChanges - clear and consume")
struct PendingChangesLifecycleTests {
    @Test("Clear empties all internal state")
    func clearResets() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        pending.recordRowDeletion(rowIndex: 5, originalRow: ["x"])
        pending.clear()

        #expect(pending.isEmpty)
        #expect(pending.changes.isEmpty)
        #expect(!pending.isRowDeleted(5))
        #expect(!pending.isCellModified(rowIndex: 0, columnIndex: 1))
    }

}
