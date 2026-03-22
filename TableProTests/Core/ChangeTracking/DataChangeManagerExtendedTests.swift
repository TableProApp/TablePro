//
//  DataChangeManagerExtendedTests.swift
//  TableProTests
//
//  Extended tests for DataChangeManager covering gaps in existing test suite.
//

import Foundation
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
        manager.configureForTable(
            tableName: "test_table",
            columns: columns,
            primaryKeyColumn: pk
        )
        return manager
    }

    // MARK: - Row Insertion Lifecycle

    @Test("Record row insertion sets hasChanges to true")
    func recordRowInsertionSetsHasChanges() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        #expect(manager.hasChanges)
    }

    @Test("Record row insertion stores values in insertedRowData")
    func recordRowInsertionStoresInInsertedRowData() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        let state = manager.saveState()
        #expect(state.insertedRowData[5] == ["a", "b", "c"])
    }

    @Test("Record row insertion adds insert-type change with empty cellChanges")
    func recordRowInsertionAddsInsertChange() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .insert)
        #expect(manager.changes[0].cellChanges.isEmpty)
    }

    @Test("Record row insertion tracks index in insertedRowIndices")
    func recordRowInsertionTracksInInsertedRowIndices() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        #expect(manager.isRowInserted(5))
        #expect(!manager.isRowInserted(0))
    }

    @Test("Record row insertion increments reloadVersion by 1")
    func recordRowInsertionIncrementsReloadVersion() {
        let manager = makeManager()
        let before = manager.reloadVersion
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        #expect(manager.reloadVersion == before + 1)
    }

    @Test("Record row insertion enables undo")
    func recordRowInsertionEnablesUndo() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        #expect(manager.canUndo)
    }

    @Test("Record row insertion clears redo stack")
    func recordRowInsertionClearsRedoStack() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        _ = manager.undoLastChange()
        #expect(manager.canRedo)
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        #expect(!manager.canRedo)
    }

    @Test("Multiple row insertions tracked separately")
    func multipleRowInsertionsTrackedSeparately() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 0, values: ["a", "b", "c"])
        manager.recordRowInsertion(rowIndex: 1, values: ["d", "e", "f"])
        #expect(manager.changes.count == 2)
        #expect(manager.changes[0].type == .insert)
        #expect(manager.changes[1].type == .insert)
    }

    // MARK: - Query Methods

    @Test("isRowDeleted returns true for deleted row, false for others")
    func isRowDeletedCorrectness() {
        let manager = makeManager()
        manager.recordRowDeletion(rowIndex: 2, originalRow: ["3", "Charlie", "c@test.com"])
        #expect(manager.isRowDeleted(2))
        #expect(!manager.isRowDeleted(0))
    }

    @Test("isRowInserted returns true for inserted row, false for others")
    func isRowInsertedCorrectness() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        #expect(manager.isRowInserted(5))
        #expect(!manager.isRowInserted(0))
    }

    @Test("isCellModified returns true after edit, false for unmodified cells")
    func isCellModifiedTrueAfterEdit() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        #expect(manager.isCellModified(rowIndex: 0, columnIndex: 1))
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 0))
    }

    @Test("isCellModified returns false after reverting to original value")
    func isCellModifiedFalseAfterRevertToOriginal() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "B", newValue: "A"
        )
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 1))
    }

    @Test("getModifiedColumnsForRow returns correct set of modified columns")
    func getModifiedColumnsCorrectSet() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        #expect(manager.getModifiedColumnsForRow(0) == [1, 2])
    }

    @Test("getModifiedColumnsForRow returns empty set for unmodified row")
    func getModifiedColumnsEmptyForUnmodifiedRow() {
        let manager = makeManager()
        #expect(manager.getModifiedColumnsForRow(99).isEmpty)
    }

    @Test("Cell modification cleared when row is deleted")
    func cellModificationClearedOnRowDeletion() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        #expect(manager.isCellModified(rowIndex: 0, columnIndex: 1))
        manager.recordRowDeletion(rowIndex: 0, originalRow: ["1", "Bob", "a@test.com"])
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 1))
        #expect(manager.getModifiedColumnsForRow(0).isEmpty)
    }

    // MARK: - State Save/Restore

    @Test("saveState captures changes")
    func saveStateCapturesChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        #expect(state.changes.count == 1)
        #expect(state.changes[0].type == .update)
    }

    @Test("saveState captures deleted row indices")
    func saveStateCapturesDeletedRowIndices() {
        let manager = makeManager()
        manager.recordRowDeletion(rowIndex: 2, originalRow: ["3", "Charlie", "c@test.com"])
        let state = manager.saveState()
        #expect(state.deletedRowIndices.contains(2))
    }

    @Test("saveState captures inserted row indices")
    func saveStateCapturesInsertedRowIndices() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 0, values: ["a", "b", "c"])
        let state = manager.saveState()
        #expect(state.insertedRowIndices.contains(0))
    }

    @Test("saveState captures modified cells")
    func saveStateCapturesModifiedCells() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        #expect(state.modifiedCells[0]?.contains(1) == true)
    }

    @Test("saveState captures inserted row data")
    func saveStateCapturesInsertedRowData() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 0, values: ["x", "y", "z"])
        let state = manager.saveState()
        #expect(state.insertedRowData[0] == ["x", "y", "z"])
    }

    @Test("saveState captures columns and primary key")
    func saveStateCapturesColumnsAndPrimaryKey() {
        let manager = makeManager(columns: ["a", "b", "c"], pk: "a")
        let state = manager.saveState()
        #expect(state.columns == ["a", "b", "c"])
        #expect(state.primaryKeyColumn == "a")
    }

    @Test("Round-trip save/restore preserves hasChanges")
    func roundTripPreservesHasChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        manager.clearChanges()
        #expect(!manager.hasChanges)
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql)
        #expect(manager.hasChanges)
    }

    @Test("Round-trip save/restore preserves isRowDeleted")
    func roundTripPreservesIsRowDeleted() {
        let manager = makeManager()
        manager.recordRowDeletion(rowIndex: 2, originalRow: ["3", "Charlie", "c@test.com"])
        let state = manager.saveState()
        manager.clearChanges()
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql)
        #expect(manager.isRowDeleted(2))
    }

    @Test("Round-trip save/restore preserves isCellModified")
    func roundTripPreservesIsCellModified() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        manager.clearChanges()
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql)
        #expect(manager.isCellModified(rowIndex: 0, columnIndex: 1))
    }

    @Test("Round-trip save/restore allows continued editing")
    func roundTripCanContinueEditing() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let state = manager.saveState()
        manager.clearChanges()
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql)
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].cellChanges.count == 2)
    }

    @Test("Empty state round-trip preserves empty state")
    func emptyStateRoundTrip() {
        let manager = makeManager()
        let state = manager.saveState()
        manager.restoreState(from: state, tableName: "test_table", databaseType: .mysql)
        #expect(!manager.hasChanges)
        #expect(manager.changes.isEmpty)
    }

    // MARK: - discardChanges

    @Test("discardChanges sets hasChanges to false")
    func discardChangesSetsHasChangesFalse() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.discardChanges()
        #expect(!manager.hasChanges)
    }

    @Test("discardChanges clears all tracked changes")
    func discardChangesClearsAllTrackedChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordRowDeletion(rowIndex: 1, originalRow: ["2", "Charlie", "c@test.com"])
        manager.recordRowInsertion(rowIndex: 5, values: ["x", "y", "z"])
        manager.discardChanges()
        #expect(manager.changes.isEmpty)
        #expect(!manager.isRowDeleted(1))
        #expect(!manager.isRowInserted(5))
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 1))
    }

    @Test("discardChanges preserves undo/redo stacks unlike clearChanges")
    func discardChangesPreservesUndoRedoUnlikeClearChanges() {
        // discardChanges preserves undo/redo
        let manager1 = makeManager()
        manager1.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        _ = manager1.undoLastChange()
        #expect(manager1.canRedo)
        manager1.discardChanges()
        #expect(manager1.canRedo)

        // clearChanges clears undo/redo
        let manager2 = makeManager()
        manager2.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        _ = manager2.undoLastChange()
        #expect(manager2.canRedo)
        manager2.clearChanges()
        #expect(!manager2.canUndo)
        #expect(!manager2.canRedo)
    }

    @Test("discardChanges increments reloadVersion by 1")
    func discardChangesIncrementsReloadVersion() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
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
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordRowDeletion(rowIndex: 1, originalRow: ["2", "Charlie", "c@test.com"])
        manager.recordRowInsertion(rowIndex: 5, values: ["x", "y", "z"])
        manager.discardChanges()
        #expect(!manager.isRowDeleted(1))
        #expect(!manager.isRowInserted(5))
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 1))
        #expect(manager.getModifiedColumnsForRow(0).isEmpty)
        #expect(manager.getOriginalValues().isEmpty)
    }

    // MARK: - Complex Undo/Redo Chains

    @Test("Multiple sequential undos reverses all changes")
    func multipleSequentialUndos() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowIndex: 1, columnIndex: 1, columnName: "name",
            oldValue: "Charlie", newValue: "Dave"
        )
        _ = manager.undoLastChange()
        _ = manager.undoLastChange()
        #expect(manager.changes.isEmpty)
        #expect(!manager.hasChanges)
    }

    @Test("Undo cell edit then redo restores the change")
    func undoCellEditThenRedoRestoresChange() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        _ = manager.undoLastChange()
        #expect(manager.changes.isEmpty)
        _ = manager.redoLastChange()
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].cellChanges[0].newValue == "B")
    }

    @Test("Undo row insertion removes from insertedRowIndices")
    func undoRowInsertionRemovesFromIndices() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        _ = manager.undoLastChange()
        #expect(!manager.isRowInserted(5))
    }

    @Test("Undo row deletion removes from deletedRowIndices")
    func undoRowDeletionRemovesFromIndices() {
        let manager = makeManager()
        manager.recordRowDeletion(rowIndex: 2, originalRow: ["3", "Charlie", "c@test.com"])
        _ = manager.undoLastChange()
        #expect(!manager.isRowDeleted(2))
    }

    @Test("Undo row insertion then redo re-inserts the row")
    func undoRowInsertionThenRedoReInserts() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        _ = manager.undoLastChange()
        #expect(!manager.isRowInserted(5))
        _ = manager.redoLastChange()
        #expect(manager.isRowInserted(5))
    }

    @Test("Undo row deletion then redo re-deletes the row")
    func undoRowDeletionThenRedoReDeletes() {
        let manager = makeManager()
        manager.recordRowDeletion(rowIndex: 2, originalRow: ["3", "Charlie", "c@test.com"])
        _ = manager.undoLastChange()
        #expect(!manager.isRowDeleted(2))
        _ = manager.redoLastChange()
        #expect(manager.isRowDeleted(2))
    }

    @Test("Full undo/redo chain: edit A, edit B, undo B, undo A, redo A, redo B")
    func fullUndoRedoChainABUndoBUndoARedoARedoB() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "A2"
        )
        manager.recordCellChange(
            rowIndex: 1, columnIndex: 1, columnName: "name",
            oldValue: "Bob", newValue: "B2"
        )
        #expect(manager.changes.count == 2)

        _ = manager.undoLastChange()
        #expect(manager.changes.count == 1)

        _ = manager.undoLastChange()
        #expect(manager.changes.count == 0)

        _ = manager.redoLastChange()
        #expect(manager.changes.count == 1)

        _ = manager.redoLastChange()
        #expect(manager.changes.count == 2)
    }

    @Test("Undo returns cell edit action details with correct flags")
    func undoReturnsCellEditActionDetails() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        let result = manager.undoLastChange()
        #expect(result != nil)
        #expect(result?.needsRowRemoval == false)
        #expect(result?.needsRowRestore == false)
    }

    @Test("Undo returns row insertion action details with needsRowRemoval")
    func undoReturnsRowInsertionActionDetails() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 5, values: ["a", "b", "c"])
        let result = manager.undoLastChange()
        #expect(result != nil)
        #expect(result?.needsRowRemoval == true)
    }

    @Test("Undo returns row deletion action details with needsRowRestore and restoreRow")
    func undoReturnsRowDeletionActionDetails() {
        let manager = makeManager()
        manager.recordRowDeletion(rowIndex: 0, originalRow: ["1", "Alice"])
        let result = manager.undoLastChange()
        #expect(result != nil)
        #expect(result?.needsRowRestore == true)
        #expect(result?.restoreRow == ["1", "Alice"])
    }

    @Test("Undo returns nil when undo stack is empty")
    func undoReturnsNilWhenStackEmpty() {
        let manager = makeManager()
        let result = manager.undoLastChange()
        #expect(result == nil)
    }

    @Test("Redo returns nil when redo stack is empty")
    func redoReturnsNilWhenStackEmpty() {
        let manager = makeManager()
        let result = manager.redoLastChange()
        #expect(result == nil)
    }

    // MARK: - Interaction Between Operations

    @Test("Edit then delete same row replaces edit with delete")
    func editThenDeleteSameRow() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordRowDeletion(rowIndex: 0, originalRow: ["1", "Bob", "a@test.com"])
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .delete)
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 1))
    }

    @Test("Insert then edit updates insertedRowData")
    func insertThenEditUpdatesInsertedRowData() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 0, values: ["", "", ""])
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: nil, newValue: "hello"
        )
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .insert)
        let state = manager.saveState()
        #expect(state.insertedRowData[0]?[1] == "hello")
    }

    @Test("Insert then edit then undo reverts inserted row cell data")
    func insertThenEditThenUndoRevertsCell() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 0, values: [nil, nil, nil])
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: nil, newValue: "hello"
        )
        _ = manager.undoLastChange()
        let state = manager.saveState()
        #expect(state.insertedRowData[0]?[1] == nil)
    }

    @Test("Edit multiple cells in same row all tracked")
    func editMultipleCellsSameRowAllTracked() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        #expect(manager.getModifiedColumnsForRow(0) == [1, 2])
        #expect(manager.changes[0].cellChanges.count == 2)
    }

    @Test("Edit multiple cells then revert one only removes reverted modification")
    func editMultipleCellsRevertOneOnlyRevertedRemoved() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 2, columnName: "email",
            oldValue: "C", newValue: "D"
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "B", newValue: "A"
        )
        #expect(manager.getModifiedColumnsForRow(0) == [2])
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 1))
    }

    @Test("Batch deletion clears prior edits for deleted rows")
    func batchDeletionClearsPriorEdits() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "A2"
        )
        manager.recordCellChange(
            rowIndex: 1, columnIndex: 1, columnName: "name",
            oldValue: "Bob", newValue: "B2"
        )
        manager.recordCellChange(
            rowIndex: 2, columnIndex: 1, columnName: "name",
            oldValue: "Charlie", newValue: "C2"
        )
        manager.recordBatchRowDeletion(rows: [
            (rowIndex: 0, originalRow: ["1", "A2", "a@test.com"]),
            (rowIndex: 1, originalRow: ["2", "B2", "b@test.com"])
        ])
        #expect(manager.isRowDeleted(0))
        #expect(manager.isRowDeleted(1))
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 1))
        #expect(!manager.isCellModified(rowIndex: 1, columnIndex: 1))
        #expect(manager.isCellModified(rowIndex: 2, columnIndex: 1))
    }

    @Test("Undo batch deletion restores all rows")
    func undoBatchDeletionRestoresAllRows() {
        let manager = makeManager()
        manager.recordBatchRowDeletion(rows: [
            (rowIndex: 0, originalRow: ["1", "Alice", "a@test.com"]),
            (rowIndex: 1, originalRow: ["2", "Bob", "b@test.com"]),
            (rowIndex: 2, originalRow: ["3", "Charlie", "c@test.com"])
        ])
        _ = manager.undoLastChange()
        #expect(!manager.isRowDeleted(0))
        #expect(!manager.isRowDeleted(1))
        #expect(!manager.isRowDeleted(2))
    }

    @Test("getOriginalValues returns correct data for edits")
    func getOriginalValuesReturnsCorrectData() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "A", newValue: "B"
        )
        manager.recordCellChange(
            rowIndex: 1, columnIndex: 2, columnName: "email",
            oldValue: "C", newValue: "D"
        )
        manager.recordRowDeletion(rowIndex: 2, originalRow: ["3", "Charlie", "c@test.com"])
        let originals = manager.getOriginalValues()
        #expect(originals.count == 2)
        let first = originals.first { $0.rowIndex == 0 }
        #expect(first?.columnIndex == 1)
        #expect(first?.value == "A")
        let second = originals.first { $0.rowIndex == 1 }
        #expect(second?.columnIndex == 2)
        #expect(second?.value == "C")
    }

    // MARK: - Edge Cases

    @Test("Recording deletion for already-deleted row adds duplicate entry")
    func recordDeletionForAlreadyDeletedRow() {
        let manager = makeManager()
        manager.recordRowDeletion(rowIndex: 0, originalRow: ["1", "Alice", "a@test.com"])
        manager.recordRowDeletion(rowIndex: 0, originalRow: ["1", "Alice", "a@test.com"])
        #expect(manager.changes.count == 2)
    }

    @Test("changedRowIndices includes all operation types")
    func changedRowIndicesIncludesAllOperationTypes() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordRowDeletion(rowIndex: 1, originalRow: ["2", "Charlie", "c@test.com"])
        manager.recordRowInsertion(rowIndex: 2, values: ["x", "y", "z"])
        #expect(manager.changedRowIndices.contains(0))
        #expect(manager.changedRowIndices.contains(1))
        #expect(manager.changedRowIndices.contains(2))
    }

    @Test("configureForTable with triggerReload false does not increment reloadVersion")
    func configureForTableNoTriggerReload() {
        let manager = DataChangeManager()
        let before = manager.reloadVersion
        manager.configureForTable(
            tableName: "test",
            columns: ["a", "b"],
            primaryKeyColumn: "a",
            triggerReload: false
        )
        #expect(manager.reloadVersion == before)
    }

    @Test("Concurrent insertions at different indices all tracked")
    func concurrentInsertionsAtDifferentIndices() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 0, values: ["a", "b", "c"])
        manager.recordRowInsertion(rowIndex: 5, values: ["d", "e", "f"])
        manager.recordRowInsertion(rowIndex: 10, values: ["g", "h", "i"])
        #expect(manager.isRowInserted(0))
        #expect(manager.isRowInserted(5))
        #expect(manager.isRowInserted(10))
        #expect(manager.changes.count == 3)
    }

    @Test("recordCellChange with nil to nil is a no-op")
    func recordCellChangeNilToNilIsNoOp() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: nil, newValue: nil
        )
        #expect(!manager.hasChanges)
    }

    // MARK: - State Consistency Invariants

    @Test("Modified cells consistent with changes after edit")
    func invariantModifiedCellsConsistentWithChangesAfterEdit() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        #expect(manager.isCellModified(rowIndex: 0, columnIndex: 1))
        #expect(manager.changes[0].cellChanges.contains { $0.columnIndex == 1 })
    }

    @Test("Modified cells cleared when all edits reverted")
    func invariantModifiedCellsClearedWhenAllReverted() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Bob", newValue: "Alice"
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 2, columnName: "email",
            oldValue: "b@test.com", newValue: "a@test.com"
        )
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 1))
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 2))
        #expect(manager.getModifiedColumnsForRow(0).isEmpty)
        #expect(manager.changes.isEmpty)
    }

    @Test("After undo, modifiedCells matches remaining changes")
    func invariantAfterUndoModifiedCellsMatchChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 2, columnName: "email",
            oldValue: "a@test.com", newValue: "b@test.com"
        )
        _ = manager.undoLastChange()
        #expect(!manager.isCellModified(rowIndex: 0, columnIndex: 2))
        #expect(manager.isCellModified(rowIndex: 0, columnIndex: 1))
    }

    @Test("After redo, modifiedCells matches restored changes")
    func invariantAfterRedoModifiedCellsMatchChanges() {
        let manager = makeManager()
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: "Alice", newValue: "Bob"
        )
        _ = manager.undoLastChange()
        _ = manager.redoLastChange()
        #expect(manager.isCellModified(rowIndex: 0, columnIndex: 1))
        #expect(!manager.changes.isEmpty)
    }

    @Test("Inserted row edit consistency between changes and insertedRowData")
    func invariantInsertedRowEditConsistency() {
        let manager = makeManager()
        manager.recordRowInsertion(rowIndex: 0, values: ["", "", ""])
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: nil, newValue: "hello"
        )
        let cellChange = manager.changes[0].cellChanges.first { $0.columnIndex == 1 }
        #expect(cellChange?.newValue == "hello")
        let state = manager.saveState()
        #expect(state.insertedRowData[0]?[1] == "hello")
    }
}
