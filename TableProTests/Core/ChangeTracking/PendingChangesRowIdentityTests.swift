//
//  PendingChangesRowIdentityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("PendingChanges - row identity")
struct PendingChangesRowIdentityTests {
    @Test("Undoing one row of a batch leaves the survivors' values on their own rows")
    func partialBatchUndoKeepsSurvivorValues() {
        var pending = PendingChanges()
        let first = RowID.inserted(UUID())
        let second = RowID.inserted(UUID())
        let third = RowID.inserted(UUID())
        pending.recordRowInsertion(rowID: first, values: ["a1", "a2"])
        pending.recordRowInsertion(rowID: second, values: ["b1", "b2"])
        pending.recordRowInsertion(rowID: third, values: ["c1", "c2"])

        let removed = pending.undoBatchRowInsertion(rowIDs: [first], columnCount: 2)

        #expect(removed == [["a1", "a2"]])
        #expect(pending.savedInsertedValues(forRow: first) == nil)
        #expect(pending.savedInsertedValues(forRow: second) == ["b1", "b2"])
        #expect(pending.savedInsertedValues(forRow: third) == ["c1", "c2"])
        #expect(!pending.isRowInserted(first))
        #expect(pending.isRowInserted(second))
        #expect(pending.isRowInserted(third))
    }

    @Test("Undoing an inserted row leaves another row's edits where they were")
    func undoInsertionKeepsOtherRowsEdits() {
        var pending = PendingChanges()
        let inserted = RowID.inserted(UUID())
        pending.recordRowInsertion(rowID: inserted, values: [.null, .null])
        pending.recordCellChange(
            rowID: .existing(4), columnIndex: 1, columnName: "name",
            oldValue: "Ann", newValue: "Bea", originalRow: ["4", "Ann"]
        )

        _ = pending.undoRowInsertion(rowID: inserted)

        #expect(pending.isCellModified(rowID: .existing(4), columnIndex: 1))
        #expect(pending.change(forRow: .existing(4), type: .update)?.cellChanges.first?.newValue == "Bea")
        #expect(pending.changes.count == 1)
    }

    @Test("An existing row and an inserted row never share a key")
    func existingAndInsertedRowsAreDistinct() {
        var pending = PendingChanges()
        let inserted = RowID.inserted(UUID())
        pending.recordRowDeletion(rowID: .existing(0), originalRow: ["1"])
        pending.recordRowInsertion(rowID: inserted, values: ["2"])

        #expect(pending.isRowDeleted(.existing(0)))
        #expect(!pending.isRowDeleted(inserted))
        #expect(pending.isRowInserted(inserted))
        #expect(!pending.isRowInserted(.existing(0)))
    }

    @Test("The returned values are the whole row, not only the columns that were typed into")
    func partialBatchUndoReturnsWholeRow() {
        var pending = PendingChanges()
        let inserted = RowID.inserted(UUID())
        pending.recordRowInsertion(rowID: inserted, values: [.null, .null, .null, .null])
        pending.recordCellChange(
            rowID: inserted, columnIndex: 2, columnName: "name",
            oldValue: .null, newValue: "Bob"
        )

        let removed = pending.undoBatchRowInsertion(rowIDs: [inserted], columnCount: 4)

        #expect(removed.first?.count == 4)
        #expect(removed.first?[2] == "Bob")
        #expect(removed.first?[0] == .null)
    }

    @Test("A restored batch comes back with the values it had, not a compacted version of them")
    func undoThenRedoRoundTrips() {
        var pending = PendingChanges()
        let inserted = RowID.inserted(UUID())
        pending.recordRowInsertion(rowID: inserted, values: [.null, .null, .null])
        pending.recordCellChange(
            rowID: inserted, columnIndex: 1, columnName: "name",
            oldValue: .null, newValue: "Bob"
        )

        let removed = pending.undoBatchRowInsertion(rowIDs: [inserted], columnCount: 3)
        pending.reinsertBatch(rowIDs: [inserted], rowValues: removed, columns: ["id", "name", "note"])

        #expect(pending.savedInsertedValues(forRow: inserted)?.count == 3)
        #expect(pending.savedInsertedValues(forRow: inserted)?[1] == "Bob")
    }
}

@Suite("PendingChanges - change order")
struct PendingChangesSequenceTests {
    @Test("Every recorded change gets a rising sequence number")
    func sequenceRises() {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowID: .existing(0), originalRow: ["a"])
        pending.recordRowInsertion(rowID: .inserted(UUID()), values: ["b"])

        let sequences = pending.changes.map(\.sequence)
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == sequences.count)
    }

    /// A cancelled change is removed by swapping the last element into its slot, so array order
    /// stops matching edit order. The sequence number is what survives that.
    @Test("Cancelling a change does not disturb the order of the ones that remain")
    func cancellingKeepsOrder() {
        var pending = PendingChanges()
        pending.recordCellChange(
            rowID: .existing(0), columnIndex: 0, columnName: "a",
            oldValue: "before", newValue: "after", originalRow: ["before"]
        )
        pending.recordRowDeletion(rowID: .existing(1), originalRow: ["b"])
        pending.recordRowInsertion(rowID: .inserted(UUID()), values: ["c"])

        let deleteSequence = pending.changes.first { $0.type == .delete }?.sequence
        let insertSequence = pending.changes.first { $0.type == .insert }?.sequence

        pending.recordCellChange(
            rowID: .existing(0), columnIndex: 0, columnName: "a",
            oldValue: "after", newValue: "before", originalRow: ["before"]
        )

        #expect(pending.changes.contains { $0.type == .delete && $0.sequence == deleteSequence })
        #expect(pending.changes.contains { $0.type == .insert && $0.sequence == insertSequence })
        #expect(deleteSequence.map { seq in insertSequence.map { $0 > seq } ?? false } == true)
    }
}
