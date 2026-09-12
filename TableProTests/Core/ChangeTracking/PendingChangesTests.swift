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
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        #expect(recorded == true)
        #expect(pending.changes.count == 1)
        #expect(pending.changes[0].type == .update)
        #expect(pending.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(pending.modifiedColumns(forRow: .existing(0)) == [1])
    }

    @Test("No-op edit when oldValue equals newValue and no prior change")
    func noOpEdit() {
        var pending = PendingChanges()
        let recorded = pending.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "a"
        )
        #expect(recorded == false)
        #expect(pending.isEmpty)
    }

    @Test("Editing back to original value collapses the change")
    func revertToOriginalCollapses() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        let collapsed = pending.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "b", newValue: "a"
        )
        #expect(collapsed == true)
        #expect(pending.isEmpty)
        #expect(!pending.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

    @Test("Recording row deletion adds delete change and marks row deleted")
    func recordRowDeletion() {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowID: .existing(5), originalRow: ["a", "b"])
        #expect(pending.isRowDeleted(.existing(5)))
        #expect(pending.changes.count == 1)
        #expect(pending.changes[0].type == .delete)
    }

    @Test("Deleting a row clears its prior cell edits")
    func deletionRemovesUpdate() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        pending.recordRowDeletion(rowID: .existing(0), originalRow: ["a", nil])
        #expect(pending.changes.count == 1)
        #expect(pending.changes[0].type == .delete)
        #expect(!pending.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

    @Test("Recording row insertion marks row inserted")
    func recordRowInsertion() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowID: insertedID(3), values: ["x", "y"])
        #expect(pending.isRowInserted(insertedID(3)))
        #expect(pending.savedInsertedValues(forRow: insertedID(3)) == ["x", "y"])
    }

    @Test("Double deletion of the same row is idempotent")
    func doubleDeletionIsIdempotent() {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowID: .existing(5), originalRow: ["a"])
        pending.recordRowDeletion(rowID: .existing(5), originalRow: ["a"])
        #expect(pending.changes.count == 1)
        #expect(pending.isRowDeleted(.existing(5)))
    }

    @Test("Double insertion of the same row updates stored values without duplicating")
    func doubleInsertionIsIdempotent() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowID: insertedID(3), values: ["x"])
        pending.recordRowInsertion(rowID: insertedID(3), values: ["y"])
        #expect(pending.changes.count == 1)
        #expect(pending.isRowInserted(insertedID(3)))
        #expect(pending.savedInsertedValues(forRow: insertedID(3)) == ["y"])
    }
}

@Suite("PendingChanges - undo")
struct PendingChangesUndoTests {
    @Test("Undo row deletion clears delete state")
    func undoRowDeletion() {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowID: .existing(0), originalRow: ["a"])
        let undone = pending.undoRowDeletion(rowID: .existing(0))
        #expect(undone == true)
        #expect(!pending.isRowDeleted(.existing(0)))
        #expect(pending.isEmpty)
    }

    @Test("Undo row insertion leaves the other inserted rows and their values alone")
    func undoRowInsertionLeavesOthers() {
        var pending = PendingChanges()
        let first = RowID.inserted(UUID())
        let second = RowID.inserted(UUID())
        let third = RowID.inserted(UUID())
        pending.recordRowInsertion(rowID: first, values: ["a"])
        pending.recordRowInsertion(rowID: second, values: ["b"])
        pending.recordRowInsertion(rowID: third, values: ["c"])

        let undone = pending.undoRowInsertion(rowID: second)
        #expect(undone == true)
        #expect(pending.isRowInserted(first))
        #expect(!pending.isRowInserted(second))
        #expect(pending.isRowInserted(third))
        #expect(pending.savedInsertedValues(forRow: first) == ["a"])
        #expect(pending.savedInsertedValues(forRow: third) == ["c"])
    }

    @Test("Undo on row that was not inserted is a no-op")
    func undoNonexistentInsertion() {
        var pending = PendingChanges()
        let undone = pending.undoRowInsertion(rowID: .existing(99))
        #expect(undone == false)
    }

    @Test("Undo batch row insertion returns saved values in order")
    func undoBatchRowInsertion() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowID: insertedID(1), values: ["a"])
        pending.recordRowInsertion(rowID: insertedID(2), values: ["b"])
        pending.recordRowInsertion(rowID: insertedID(3), values: ["c"])

        let restored = pending.undoBatchRowInsertion(
            rowIDs: [insertedID(1), insertedID(2), insertedID(3)], columnCount: 1
        )
        #expect(restored.count == 3)
        #expect(!pending.isRowInserted(insertedID(1)))
        #expect(!pending.isRowInserted(insertedID(2)))
        #expect(!pending.isRowInserted(insertedID(3)))
    }
}

@Suite("PendingChanges - replay")
struct PendingChangesReplayTests {
    @Test("Reapply cell change with no existing change")
    func reapplyCellWithoutExisting() {
        var pending = PendingChanges()
        pending.reapplyCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            originalDBValue: "orig", newValue: "x", originalRow: nil
        )
        #expect(pending.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(pending.changes[0].cellChanges[0].oldValue == "orig")
    }

    @Test("Reapply cell change preserves the original DB value as oldValue")
    func reapplyCellPreservesOriginalDBValue() {
        var pending = PendingChanges()
        pending.reapplyCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            originalDBValue: "Alice", newValue: "Bob", originalRow: nil
        )
        let cellChange = pending.changes[0].cellChanges[0]
        #expect(cellChange.oldValue == "Alice")
        #expect(cellChange.newValue == "Bob")
    }

    @Test("Reinsert row creates insert change with saved values")
    func reinsertRowFromUndo() {
        var pending = PendingChanges()
        pending.reinsertRow(rowID: .existing(2), columns: ["a", "b"], savedValues: ["x", "y"])
        #expect(pending.isRowInserted(.existing(2)))
        #expect(pending.savedInsertedValues(forRow: .existing(2)) == ["x", "y"])
    }

    @Test("Reapply row deletion adds delete change")
    func reapplyDeletion() {
        var pending = PendingChanges()
        pending.reapplyRowDeletion(rowID: .existing(0), originalRow: ["a", "b"])
        #expect(pending.isRowDeleted(.existing(0)))
    }
}

@Suite("PendingChanges - snapshot")
struct PendingChangesSnapshotTests {
    @Test("Snapshot round-trip preserves state")
    func snapshotRoundTrip() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        pending.recordRowDeletion(rowID: .existing(5), originalRow: ["x"])
        pending.recordRowInsertion(rowID: insertedID(7), values: ["new"])

        let snapshot = pending.snapshot(primaryKeyColumns: ["id"], columns: ["id", "name"])

        var restored = PendingChanges()
        restored.restore(from: snapshot)

        #expect(restored.changes.count == pending.changes.count)
        #expect(restored.isRowDeleted(.existing(5)))
        #expect(restored.isRowInserted(insertedID(7)))
        #expect(restored.isCellModified(rowID: .existing(0), columnIndex: 1))
    }
}

@Suite("PendingChanges - clear and consume")
struct PendingChangesLifecycleTests {
    @Test("Clear empties all internal state")
    func clearResets() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "a", newValue: "b"
        )
        pending.recordRowDeletion(rowID: .existing(5), originalRow: ["x"])
        pending.clear()

        #expect(pending.isEmpty)
        #expect(pending.changes.isEmpty)
        #expect(!pending.isRowDeleted(.existing(5)))
        #expect(!pending.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

}

private func insertedID(_ seed: Int) -> RowID {
    .inserted(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seed)) ?? UUID())
}
