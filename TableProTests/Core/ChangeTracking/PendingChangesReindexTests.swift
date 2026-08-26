//
//  PendingChangesReindexTests.swift
//  TableProTests
//
//  Undoing one row of a pasted batch used to renumber only two of the six things PendingChanges
//  keys by row index, so the survivors' values stayed filed under their old numbers and Save wrote
//  one row with another row's values while dropping the rest, reporting success either way.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("PendingChanges - reindexing")
struct PendingChangesReindexTests {
    @Test("Undoing one row of a batch leaves the survivors' values under their new indices")
    func partialBatchUndoKeepsSurvivorValues() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowIndex: 10, values: ["a1", "a2"])
        pending.recordRowInsertion(rowIndex: 11, values: ["b1", "b2"])
        pending.recordRowInsertion(rowIndex: 12, values: ["c1", "c2"])

        let removed = pending.undoBatchRowInsertion(rowIndices: [10], columnCount: 2)

        #expect(removed == [["a1", "a2"]])
        #expect(pending.savedInsertedValues(forRow: 10) == ["b1", "b2"])
        #expect(pending.savedInsertedValues(forRow: 11) == ["c1", "c2"])
        #expect(pending.savedInsertedValues(forRow: 12) == nil)
        #expect(pending.isRowInserted(10))
        #expect(pending.isRowInserted(11))
        #expect(!pending.isRowInserted(12))
    }

    @Test("The returned values are the whole row, not only the columns that were typed into")
    func partialBatchUndoReturnsWholeRow() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowIndex: 0, values: [.null, .null, .null, .null])
        pending.recordCellChange(
            rowIndex: 0, columnIndex: 2, columnName: "name",
            oldValue: .null, newValue: "Bob"
        )

        let removed = pending.undoBatchRowInsertion(rowIndices: [0], columnCount: 4)

        #expect(removed.first?.count == 4)
        #expect(removed.first?[2] == "Bob")
        #expect(removed.first?[0] == .null)
    }

    @Test("A restored batch comes back with the values it had, not a compacted version of them")
    func undoThenRedoRoundTrips() {
        var pending = PendingChanges()
        pending.recordRowInsertion(rowIndex: 0, values: [.null, .null, .null])
        pending.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: .null, newValue: "Bob"
        )

        let removed = pending.undoBatchRowInsertion(rowIndices: [0], columnCount: 3)
        pending.reinsertBatch(rowIndices: [0], rowValues: removed, columns: ["id", "name", "note"])

        #expect(pending.savedInsertedValues(forRow: 0)?.count == 3)
        #expect(pending.savedInsertedValues(forRow: 0)?[1] == "Bob")
    }
}

@Suite("PendingChanges - change order")
struct PendingChangesSequenceTests {
    @Test("Every recorded change gets a rising sequence number")
    func sequenceRises() {
        var pending = PendingChanges()
        pending.recordRowDeletion(rowIndex: 0, originalRow: ["a"])
        pending.recordRowInsertion(rowIndex: 1, values: ["b"])

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
            rowIndex: 0, columnIndex: 0, columnName: "a",
            oldValue: "before", newValue: "after", originalRow: ["before"]
        )
        pending.recordRowDeletion(rowIndex: 1, originalRow: ["b"])
        pending.recordRowInsertion(rowIndex: 2, values: ["c"])

        let deleteSequence = pending.changes.first { $0.type == .delete }?.sequence
        let insertSequence = pending.changes.first { $0.type == .insert }?.sequence

        pending.recordCellChange(
            rowIndex: 0, columnIndex: 0, columnName: "a",
            oldValue: "after", newValue: "before", originalRow: ["before"]
        )

        #expect(pending.changes.contains { $0.type == .delete && $0.sequence == deleteSequence })
        #expect(pending.changes.contains { $0.type == .insert && $0.sequence == insertSequence })
        #expect(deleteSequence.map { seq in insertSequence.map { $0 > seq } ?? false } == true)
    }
}
