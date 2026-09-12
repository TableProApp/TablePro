//
//  DataChangeManagerExtendedTests.swift
//  TableProTests
//
//  Extended tests for DataChangeManager covering gaps in existing test suite.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
@Suite("Data Change Manager Extended")
struct DataChangeManagerExtendedTests {
    private func makeManager(
        columns: [String] = ["id", "name", "email"],
        pk: String? = "id"
    ) -> DataChangeManager {
        let manager = DataChangeManager()
        let undoManager = UndoManager()
        undoManager.levelsOfUndo = 100
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        manager.configureForTable(
            tableName: "test_table",
            columns: columns,
            primaryKeyColumns: [pk].compactMap { $0 },
            databaseType: .mysql,
            generatedColumns: []
        )
        return manager
    }

    // MARK: - Row Insertion Lifecycle

    @Test("Record row insertion sets hasChanges to true")
    func recordRowInsertionSetsHasChanges() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        #expect(manager.hasChanges)
    }

    @Test("Record row insertion stores values in insertedRowData")
    func recordRowInsertionStoresInInsertedRowData() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        let state = manager.saveState()
        #expect(state.insertedRowData[insertedID(5)] == ["a", "b", "c"])
    }

    @Test("Record row insertion adds insert-type change with empty cellChanges")
    func recordRowInsertionAddsInsertChange() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .insert)
        #expect(manager.changes[0].cellChanges.isEmpty)
    }

    @Test("Record row insertion tracks index in insertedRowIDs")
    func recordRowInsertionTracksInInsertedRowIndices() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        #expect(manager.isRowInserted(insertedID(5)))
        #expect(!manager.isRowInserted(.existing(0)))
    }

    @Test("Record row insertion increments reloadVersion by 1")
    /// `reloadVersion` is the signal that tells the grid to throw away what it is showing and fetch
    /// again. It increments on `clearChanges`, `discardChanges` and `configureForTable`, and
    /// deliberately not on recording an edit: a reload there would discard the very edit the user
    /// just made. These asserted the opposite, which is why they sat in the quarantine file, so
    /// each now pins the real contract from both sides.
    func recordRowInsertionDoesNotAskTheGridToReload() {
        let manager = makeManager()
        let before = manager.reloadVersion

        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])

        #expect(manager.reloadVersion == before)

        manager.discardChanges()

        #expect(manager.reloadVersion == before + 1)
    }

    @Test("Record row insertion enables undo")
    func recordRowInsertionEnablesUndo() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        #expect(manager.canUndo)
    }

    @Test("Record row insertion clears redo stack")
    func recordRowInsertionClearsRedoStack() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        manager.undoManagerProvider?()?.undo()
        #expect(manager.canRedo)
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        #expect(!manager.canRedo)
    }

    @Test("Multiple row insertions tracked separately")
    func multipleRowInsertionsTrackedSeparately() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(0), values: ["a", "b", "c"])
        manager.recordRowInsertion(rowID: insertedID(1), values: ["d", "e", "f"])
        #expect(manager.changes.count == 2)
        #expect(manager.changes[0].type == .insert)
        #expect(manager.changes[1].type == .insert)
    }

    // MARK: - Query Methods

    @Test("isRowDeleted returns true for deleted row, false for others")
    func isRowDeletedCorrectness() {
        let manager = makeManager()
        manager.recordRowDeletion(rowID: .existing(2), originalRow: ["3", "Charlie", "c@test.com"])
        #expect(manager.isRowDeleted(.existing(2)))
        #expect(!manager.isRowDeleted(.existing(0)))
    }

    @Test("isRowInserted returns true for inserted row, false for others")
    func isRowInsertedCorrectness() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        #expect(manager.isRowInserted(insertedID(5)))
        #expect(!manager.isRowInserted(.existing(0)))
    }

    @Test("isCellModified returns true after edit, false for unmodified cells")
    func isCellModifiedTrueAfterEdit() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        #expect(manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 0))
    }

    @Test("isCellModified returns false after reverting to original value")
    func isCellModifiedFalseAfterRevertToOriginal() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "B", newValue: "A"
        )
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

    @Test("getModifiedColumnsForRow returns correct set of modified columns")
    func getModifiedColumnsCorrectSet() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        #expect(manager.getModifiedColumnsForRow(.existing(0)) == [1, 2])
    }

    @Test("getModifiedColumnsForRow returns empty set for unmodified row")
    func getModifiedColumnsEmptyForUnmodifiedRow() {
        let manager = makeManager()
        #expect(manager.getModifiedColumnsForRow(.existing(99)).isEmpty)
    }

    @Test("Cell modification cleared when row is deleted")
    func cellModificationClearedOnRowDeletion() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        #expect(manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["1", "Bob", "a@test.com"])
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(manager.getModifiedColumnsForRow(.existing(0)).isEmpty)
    }

    // MARK: - State Save/Restore

    @Test("saveState captures changes")
    func saveStateCapturesChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        #expect(state.changes.count == 1)
        #expect(state.changes[0].type == .update)
    }

    @Test("saveState captures deleted row indices")
    func saveStateCapturesDeletedRowIndices() {
        let manager = makeManager()
        manager.recordRowDeletion(rowID: .existing(2), originalRow: ["3", "Charlie", "c@test.com"])
        let state = manager.saveState()
        #expect(state.deletedRowIDs.contains(.existing(2)))
    }

    @Test("saveState captures inserted row indices")
    func saveStateCapturesInsertedRowIndices() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(0), values: ["a", "b", "c"])
        let state = manager.saveState()
        #expect(state.insertedRowIDs.contains(insertedID(0)))
    }

    @Test("saveState captures modified cells")
    func saveStateCapturesModifiedCells() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        #expect(state.modifiedCells[.existing(0)]?.contains(1) == true)
    }

    @Test("saveState captures inserted row data")
    func saveStateCapturesInsertedRowData() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(0), values: ["x", "y", "z"])
        let state = manager.saveState()
        #expect(state.insertedRowData[insertedID(0)] == ["x", "y", "z"])
    }

    @Test("saveState captures columns and primary key")
    func saveStateCapturesColumnsAndPrimaryKey() {
        let manager = makeManager(columns: ["a", "b", "c"], pk: "a")
        let state = manager.saveState()
        #expect(state.columns == ["a", "b", "c"])
        #expect(state.primaryKeyColumns == ["a"])
    }

    @Test("Round-trip save/restore preserves hasChanges")
    func roundTripPreservesHasChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        manager.clearChanges()
        #expect(!manager.hasChanges)
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql, generatedColumns: [])
        #expect(manager.hasChanges)
    }

    @Test("Round-trip save/restore preserves isRowDeleted")
    func roundTripPreservesIsRowDeleted() {
        let manager = makeManager()
        manager.recordRowDeletion(rowID: .existing(2), originalRow: ["3", "Charlie", "c@test.com"])
        let state = manager.saveState()
        manager.clearChanges()
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql, generatedColumns: [])
        #expect(manager.isRowDeleted(.existing(2)))
    }

    @Test("Round-trip save/restore preserves isCellModified")
    func roundTripPreservesIsCellModified() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        manager.clearChanges()
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql, generatedColumns: [])
        #expect(manager.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

    @Test("Round-trip save/restore allows continued editing")
    func roundTripCanContinueEditing() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        manager.clearChanges()
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql, generatedColumns: [])
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].cellChanges.count == 2)
    }

    @Test("Empty state round-trip preserves empty state")
    func emptyStateRoundTrip() {
        let manager = makeManager()
        let state = manager.saveState()
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql, generatedColumns: [])
        #expect(!manager.hasChanges)
        #expect(manager.changes.isEmpty)
    }

    // MARK: - discardChanges

    @Test("discardChanges sets hasChanges to false")
    func discardChangesSetsHasChangesFalse() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.discardChanges()
        #expect(!manager.hasChanges)
    }

    @Test("discardChanges clears all tracked changes")
    func discardChangesClearsAllTrackedChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordRowDeletion(rowID: .existing(1), originalRow: ["2", "Charlie", "c@test.com"])
        manager.recordRowInsertion(rowID: insertedID(5), values: ["x", "y", "z"])
        manager.discardChanges()
        #expect(manager.changes.isEmpty)
        #expect(!manager.isRowDeleted(.existing(1)))
        #expect(!manager.isRowInserted(insertedID(5)))
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

    @Test("only clearChangesAndUndoHistory drops the undo stack")
    func discardChangesPreservesUndoRedoUnlikeClearChanges() {
        // discardChanges preserves undo/redo
        let manager1 = makeManager()
        manager1.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager1.undoManagerProvider?()?.undo()
        #expect(manager1.canRedo)
        manager1.discardChanges()
        #expect(manager1.canRedo)

        /// `clearChanges` drops the pending edits and leaves the undo stack standing, exactly as
        /// `discardChanges` does. Clearing the history is a separate call,
        /// `clearChangesAndUndoHistory`, and that distinction is the point: this case asserted that
        /// `clearChanges` wiped undo, which would make the two indistinguishable.
        let manager2 = makeManager()
        manager2.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager2.undoManagerProvider?()?.undo()
        #expect(manager2.canRedo)
        manager2.clearChanges()
        #expect(manager2.canRedo)

        manager2.clearChangesAndUndoHistory()
        #expect(!manager2.canUndo)
        #expect(!manager2.canRedo)
    }

    @Test("discardChanges increments reloadVersion by 1")
    func discardChangesIncrementsReloadVersion() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let before = manager.reloadVersion
        manager.discardChanges()
        #expect(manager.reloadVersion == before + 1)
    }

    @Test("discardChanges makes all query methods return defaults")
    func discardChangesAllQueryMethodsReturnDefaults() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordRowDeletion(rowID: .existing(1), originalRow: ["2", "Charlie", "c@test.com"])
        manager.recordRowInsertion(rowID: insertedID(5), values: ["x", "y", "z"])
        manager.discardChanges()
        #expect(!manager.isRowDeleted(.existing(1)))
        #expect(!manager.isRowInserted(insertedID(5)))
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(manager.getModifiedColumnsForRow(.existing(0)).isEmpty)
        #expect(manager.getOriginalValues().isEmpty)
    }

    // MARK: - Complex Undo/Redo Chains

    @Test("Multiple sequential undos reverses all changes")
    func multipleSequentialUndos() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowID: .existing(1), columnIndex: 1, columnName: "name",
            oldValue: "Charlie", newValue: "Dave"
        )
        manager.undoManagerProvider?()?.undo()
        manager.undoManagerProvider?()?.undo()
        #expect(manager.changes.isEmpty)
        #expect(!manager.hasChanges)
    }

    @Test("Undo cell edit then redo restores the change")
    func undoCellEditThenRedoRestoresChange() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        manager.undoManagerProvider?()?.undo()
        #expect(manager.changes.isEmpty)
        manager.undoManagerProvider?()?.redo()
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].cellChanges[0].newValue == "B")
    }

    @Test("Undo row insertion removes from insertedRowIDs")
    func undoRowInsertionRemovesFromIndices() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        manager.undoManagerProvider?()?.undo()
        #expect(!manager.isRowInserted(insertedID(5)))
    }

    @Test("Undo row deletion removes from deletedRowIDs")
    func undoRowDeletionRemovesFromIndices() {
        let manager = makeManager()
        manager.recordRowDeletion(rowID: .existing(2), originalRow: ["3", "Charlie", "c@test.com"])
        manager.undoManagerProvider?()?.undo()
        #expect(!manager.isRowDeleted(.existing(2)))
    }

    @Test("Undo row insertion then redo re-inserts the row")
    func undoRowInsertionThenRedoReInserts() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        manager.undoManagerProvider?()?.undo()
        #expect(!manager.isRowInserted(insertedID(5)))
        manager.undoManagerProvider?()?.redo()
        #expect(manager.isRowInserted(insertedID(5)))
    }

    @Test("Undo row deletion then redo re-deletes the row")
    func undoRowDeletionThenRedoReDeletes() {
        let manager = makeManager()
        manager.recordRowDeletion(rowID: .existing(2), originalRow: ["3", "Charlie", "c@test.com"])
        manager.undoManagerProvider?()?.undo()
        #expect(!manager.isRowDeleted(.existing(2)))
        manager.undoManagerProvider?()?.redo()
        #expect(manager.isRowDeleted(.existing(2)))
    }

    @Test("Full undo/redo chain: edit A, edit B, undo B, undo A, redo A, redo B")
    func fullUndoRedoChainABUndoBUndoARedoARedoB() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "A2"
        )
        manager.recordCellChange(
            rowID: .existing(1), columnIndex: 1, columnName: "name",
            oldValue: "Bob", newValue: "B2"
        )
        #expect(manager.changes.count == 2)

        manager.undoManagerProvider?()?.undo()
        #expect(manager.changes.count == 1)

        manager.undoManagerProvider?()?.undo()
        #expect(manager.changes.count == 0)

        manager.undoManagerProvider?()?.redo()
        #expect(manager.changes.count == 1)

        manager.undoManagerProvider?()?.redo()
        #expect(manager.changes.count == 2)
    }

    @Test("Undo returns cell edit action details with correct flags")
    func undoReturnsCellEditActionDetails() {
        let manager = makeManager()
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.undoManagerProvider?()?.undo()
        #expect(captured != nil)
        #expect(captured?.needsRowRemoval == false)
        #expect(captured?.needsRowRestore == false)
    }

    @Test("Undo returns row insertion action details with needsRowRemoval")
    func undoReturnsRowInsertionActionDetails() {
        let manager = makeManager()
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        manager.recordRowInsertion(rowID: insertedID(5), values: ["a", "b", "c"])
        manager.undoManagerProvider?()?.undo()
        #expect(captured != nil)
        #expect(captured?.needsRowRemoval == true)
    }

    @Test("Undo returns row deletion action details with needsRowRestore and restoreRow")
    func undoReturnsRowDeletionActionDetails() {
        let manager = makeManager()
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["1", "Alice"])
        manager.undoManagerProvider?()?.undo()
        #expect(captured != nil)
        #expect(captured?.needsRowRestore == true)
        #expect(captured?.restoreRow == ["1", "Alice"])
    }

    @Test("Undo does nothing when undo stack is empty")
    func undoNoopWhenStackEmpty() {
        let manager = makeManager()
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        let undoManager = manager.undoManagerProvider?()
        #expect(undoManager?.canUndo == false)
        undoManager?.undo()
        #expect(captured == nil)
    }

    @Test("Redo does nothing when redo stack is empty")
    func redoNoopWhenStackEmpty() {
        let manager = makeManager()
        var captured: UndoResult?
        manager.onUndoApplied = { captured = $0 }
        let undoManager = manager.undoManagerProvider?()
        #expect(undoManager?.canRedo == false)
        undoManager?.redo()
        #expect(captured == nil)
    }

    // MARK: - Interaction Between Operations

    @Test("Edit then delete same row replaces edit with delete")
    func editThenDeleteSameRow() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["1", "Bob", "a@test.com"])
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .delete)
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

    @Test("Insert then edit updates insertedRowData")
    func insertThenEditUpdatesInsertedRowData() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(0), values: ["", "", ""])
        manager.recordCellChange(
            rowID: insertedID(0), columnIndex: 1, columnName: "name",
            oldValue: nil, newValue: "hello"
        )
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .insert)
        let state = manager.saveState()
        #expect(state.insertedRowData[insertedID(0)]?[1] == "hello")
    }

    @Test("Insert then edit then undo reverts inserted row cell data")
    func insertThenEditThenUndoRevertsCell() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(0), values: [nil, nil, nil])
        manager.recordCellChange(
            rowID: insertedID(0), columnIndex: 1, columnName: "name",
            oldValue: nil, newValue: "hello"
        )
        manager.undoManagerProvider?()?.undo()
        let state = manager.saveState()
        /// `.null`, not a Swift nil. An inserted row holds an explicit SQL NULL for a cell with no
        /// value, so undoing an edit restores `.null` rather than removing the entry.
        #expect(state.insertedRowData[insertedID(0)]?[1] == .null)
    }

    @Test("Edit multiple cells in same row all tracked")
    func editMultipleCellsSameRowAllTracked() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        #expect(manager.getModifiedColumnsForRow(.existing(0)) == [1, 2])
        #expect(manager.changes[0].cellChanges.count == 2)
    }

    @Test("Edit multiple cells then revert one only removes reverted modification")
    func editMultipleCellsRevertOneOnlyRevertedRemoved() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "C", newValue: "D"
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "B", newValue: "A"
        )
        #expect(manager.getModifiedColumnsForRow(.existing(0)) == [2])
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

    @Test("Batch deletion clears prior edits for deleted rows")
    func batchDeletionClearsPriorEdits() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "A2"
        )
        manager.recordCellChange(
            rowID: .existing(1), columnIndex: 1, columnName: "name",
            oldValue: "Bob", newValue: "B2"
        )
        manager.recordCellChange(
            rowID: .existing(2), columnIndex: 1, columnName: "name",
            oldValue: "Charlie", newValue: "C2"
        )
        manager.recordBatchRowDeletion(rows: [
            (rowID: .existing(0), originalRow: ["1", "A2", "a@test.com"]),
            (rowID: .existing(1), originalRow: ["2", "B2", "b@test.com"])
        ])
        #expect(manager.isRowDeleted(.existing(0)))
        #expect(manager.isRowDeleted(.existing(1)))
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(1), columnIndex: 1))
        #expect(manager.isCellModified(rowID: .existing(2), columnIndex: 1))
    }

    @Test("Undo batch deletion restores all rows")
    func undoBatchDeletionRestoresAllRows() {
        let manager = makeManager()
        manager.recordBatchRowDeletion(rows: [
            (rowID: .existing(0), originalRow: ["1", "Alice", "a@test.com"]),
            (rowID: .existing(1), originalRow: ["2", "Bob", "b@test.com"]),
            (rowID: .existing(2), originalRow: ["3", "Charlie", "c@test.com"])
        ])
        manager.undoManagerProvider?()?.undo()
        #expect(!manager.isRowDeleted(.existing(0)))
        #expect(!manager.isRowDeleted(.existing(1)))
        #expect(!manager.isRowDeleted(.existing(2)))
    }

    @Test("getOriginalValues returns correct data for edits")
    func getOriginalValuesReturnsCorrectData() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        manager.recordCellChange(
            rowID: .existing(1), columnIndex: 2, columnName: "email",
            oldValue: "C", newValue: "D"
        )
        manager.recordRowDeletion(rowID: .existing(2), originalRow: ["3", "Charlie", "c@test.com"])
        let originals = manager.getOriginalValues()
        #expect(originals.count == 2)
        let first = originals.first { $0.rowID == .existing(0) }
        #expect(first?.columnIndex == 1)
        #expect(first?.value == "A")
        let second = originals.first { $0.rowID == .existing(1) }
        #expect(second?.columnIndex == 2)
        #expect(second?.value == "C")
    }

    // MARK: - Edge Cases

    @Test("Recording deletion for already-deleted row is idempotent")
    func recordDeletionForAlreadyDeletedRow() {
        let manager = makeManager()
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["1", "Alice", "a@test.com"])
        manager.recordRowDeletion(rowID: .existing(0), originalRow: ["1", "Alice", "a@test.com"])
        #expect(manager.changes.count == 1)
    }

    @Test("configureForTable with triggerReload false does not increment reloadVersion")
    func configureForTableNoTriggerReload() {
        let manager = DataChangeManager()
        let before = manager.reloadVersion
        manager.configureForTable(
            tableName: "test",
            columns: ["a", "b"],
            primaryKeyColumns: ["a"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        #expect(manager.reloadVersion == before)
    }

    @Test("Concurrent insertions at different indices all tracked")
    func concurrentInsertionsAtDifferentIndices() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(0), values: ["a", "b", "c"])
        manager.recordRowInsertion(rowID: insertedID(5), values: ["d", "e", "f"])
        manager.recordRowInsertion(rowID: insertedID(10), values: ["g", "h", "i"])
        #expect(manager.isRowInserted(insertedID(0)))
        #expect(manager.isRowInserted(insertedID(5)))
        #expect(manager.isRowInserted(insertedID(10)))
        #expect(manager.changes.count == 3)
    }

    @Test("recordCellChange with nil to nil is a no-op")
    func recordCellChangeNilToNilIsNoOp() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: nil, newValue: nil
        )
        #expect(!manager.hasChanges)
    }

    // MARK: - State Consistency Invariants

    @Test("Modified cells consistent with changes after edit")
    func invariantModifiedCellsConsistentWithChangesAfterEdit() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        #expect(manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(manager.changes[0].cellChanges.contains { $0.columnIndex == 1 })
    }

    @Test("Modified cells cleared when all edits reverted")
    func invariantModifiedCellsClearedWhenAllReverted() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Bob", newValue: "Alice"
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "b@test.com", newValue: "a@test.com"
        )
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 2))
        #expect(manager.getModifiedColumnsForRow(.existing(0)).isEmpty)
        #expect(manager.changes.isEmpty)
    }

    @Test("After undo, modifiedCells matches remaining changes")
    func invariantAfterUndoModifiedCellsMatchChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        manager.undoManagerProvider?()?.undo()
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 2))
        #expect(manager.isCellModified(rowID: .existing(0), columnIndex: 1))
    }

    @Test("After redo, modifiedCells matches restored changes")
    func invariantAfterRedoModifiedCellsMatchChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.undoManagerProvider?()?.undo()
        manager.undoManagerProvider?()?.redo()
        #expect(manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(!manager.changes.isEmpty)
    }

    @Test("Edit -> undo -> redo -> undo collapses cleanly (no orphan modifiedCells)")
    func editUndoRedoUndoCollapses() {
        let manager = makeManager()
        manager.recordCellChange(
            rowID: .existing(0), columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.undoManagerProvider?()?.undo()
        manager.undoManagerProvider?()?.redo()
        #expect(manager.isCellModified(rowID: .existing(0), columnIndex: 1))

        manager.undoManagerProvider?()?.undo()
        #expect(!manager.isCellModified(rowID: .existing(0), columnIndex: 1))
        #expect(manager.changes.isEmpty)
        #expect(!manager.hasChanges)
    }

    @Test("Inserted row edit consistency between changes and insertedRowData")
    func invariantInsertedRowEditConsistency() {
        let manager = makeManager()
        manager.recordRowInsertion(rowID: insertedID(0), values: ["", "", ""])
        manager.recordCellChange(
            rowID: insertedID(0), columnIndex: 1, columnName: "name",
            oldValue: nil, newValue: "hello"
        )
        let cellChange = manager.changes[0].cellChanges.first { $0.columnIndex == 1 }
        #expect(cellChange?.newValue == "hello")
        let state = manager.saveState()
        #expect(state.insertedRowData[insertedID(0)]?[1] == "hello")
    }
}

private func insertedID(_ seed: Int) -> RowID {
    .inserted(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", seed)) ?? UUID())
}
