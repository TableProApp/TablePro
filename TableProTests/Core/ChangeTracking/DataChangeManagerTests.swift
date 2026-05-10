//
//  DataChangeManagerTests.swift
//  TableProTests
//
//  Tests for DataChangeManager
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@MainActor
@Suite("Data Change Manager")
struct DataChangeManagerTests {
    private func makeManagerWithUndo() -> DataChangeManager {
        let manager = DataChangeManager()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        manager.undoManagerProvider = { undoManager }
        return manager
    }

    // MARK: - Configuration Tests

    @Test("configureForTable sets properties correctly")
    func configureForTableSetsProperties() async {
        let manager = DataChangeManager()

        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name", "email"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql
        )

        #expect(manager.tableName == "users")
        #expect(manager.columns == ["id", "name", "email"])
        #expect(manager.primaryKeyColumn == "id")
        #expect(manager.databaseType == .postgresql)
    }

    @Test("configureForTable clears existing changes")
    func configureForTableClearsChanges() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )
        #expect(manager.hasChanges)

        manager.configureForTable(
            tableName: "products",
            columns: ["id", "title"],
            primaryKeyColumns: ["id"]
        )

        #expect(!manager.hasChanges)
        #expect(manager.changes.isEmpty)
    }

    @Test("Initial state has no changes")
    func initialStateHasNoChanges() async {
        let manager = DataChangeManager()

        #expect(!manager.hasChanges)
        #expect(manager.changes.isEmpty)
        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
    }

    // MARK: - Cell Change Recording Tests

    @Test("Record cell change makes hasChanges true")
    func recordCellChangeUpdatesHasChanges() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        #expect(manager.hasChanges)
    }

    @Test("Record cell change adds entry to changes array")
    func recordCellChangeAddsToArray() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .update)
        #expect(manager.changes[0].rowIndex == 0)
        #expect(manager.changes[0].cellChanges.count == 1)
        #expect(manager.changes[0].cellChanges[0].columnName == "name")
        #expect(manager.changes[0].cellChanges[0].oldValue == "Alice")
        #expect(manager.changes[0].cellChanges[0].newValue == "Bob")
    }

    @Test("Same value is ignored, no change recorded")
    func sameValueIsIgnored() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Alice"
        )

        #expect(!manager.hasChanges)
        #expect(manager.changes.isEmpty)
    }

    @Test("Edit same cell again merges change preserving original oldValue")
    func editSameCellMergesChange() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Bob",
            newValue: "Charlie"
        )

        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].cellChanges.count == 1)
        #expect(manager.changes[0].cellChanges[0].oldValue == "Alice")
        #expect(manager.changes[0].cellChanges[0].newValue == "Charlie")
    }

    @Test("Edit back to original value removes change")
    func editBackToOriginalRemovesChange() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )
        #expect(manager.hasChanges)

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Bob",
            newValue: "Alice"
        )

        #expect(!manager.hasChanges)
        #expect(manager.changes.isEmpty)
    }

    @Test("Record changes to different rows creates separate RowChange entries")
    func differentRowsSeparateEntries() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        manager.recordCellChange(
            rowIndex: 1,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Charlie",
            newValue: "Dave"
        )

        #expect(manager.changes.count == 2)
        #expect(manager.changes[0].rowIndex == 0)
        #expect(manager.changes[1].rowIndex == 1)
    }

    // MARK: - Row Deletion Tests

    @Test("Record row deletion makes hasChanges true")
    func recordRowDeletionUpdatesHasChanges() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordRowDeletion(rowIndex: 0, originalRow: ["1", "Alice"])

        #expect(manager.hasChanges)
    }

    @Test("Delete removes any prior update changes for that row")
    func deleteRemovesPriorUpdates() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )
        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .update)

        manager.recordRowDeletion(rowIndex: 0, originalRow: ["1", "Bob"])

        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .delete)
        #expect(manager.changes[0].rowIndex == 0)
    }

    @Test("Deleted row tracked in changes with type delete")
    func deletedRowTracked() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordRowDeletion(rowIndex: 2, originalRow: ["3", "Charlie"])

        #expect(manager.changes.count == 1)
        #expect(manager.changes[0].type == .delete)
        #expect(manager.changes[0].rowIndex == 2)
        #expect(manager.changes[0].originalRow == ["3", "Charlie"])
    }

    @Test("Batch deletion records all rows")
    func batchDeletionRecordsAllRows() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        let rows: [(rowIndex: Int, originalRow: [PluginCellValue])] = [
            (rowIndex: 0, originalRow: [.text("1"), .text("Alice")]),
            (rowIndex: 1, originalRow: [.text("2"), .text("Bob")]),
            (rowIndex: 2, originalRow: [.text("3"), .text("Charlie")])
        ]

        manager.recordBatchRowDeletion(rows: rows)

        #expect(manager.changes.count == 3)
        #expect(manager.changes.allSatisfy { $0.type == .delete })
        #expect(manager.hasChanges)
    }

    // MARK: - clearChanges Tests

    @Test("clearChanges removes all changes")
    func clearChangesRemovesAll() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )
        manager.recordRowDeletion(rowIndex: 1, originalRow: ["2", "Charlie"])

        manager.clearChanges()

        #expect(manager.changes.isEmpty)
        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
    }

    @Test("clearChanges makes hasChanges false")
    func clearChangesUpdatesHasChanges() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )
        #expect(manager.hasChanges)

        manager.clearChanges()

        #expect(!manager.hasChanges)
    }

    // MARK: - Undo/Redo Tests

    @Test("After recording a change, canUndo is true")
    func canUndoAfterChange() async {
        let manager = makeManagerWithUndo()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        #expect(manager.canUndo)
    }

    @Test("After undo, the change is reversed")
    func undoReversesChange() async {
        let manager = makeManagerWithUndo()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )
        #expect(manager.changes.count == 1)

        manager.undoManagerProvider?()?.undo()

        #expect(manager.changes.isEmpty)
        #expect(!manager.hasChanges)
    }

    @Test("canRedo after undo")
    func canRedoAfterUndo() async {
        let manager = makeManagerWithUndo()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        manager.undoManagerProvider?()?.undo()

        #expect(manager.canRedo)
    }

    @Test("New change clears redo stack")
    func newChangeClearsRedo() async {
        let manager = makeManagerWithUndo()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        manager.undoManagerProvider?()?.undo()
        #expect(manager.canRedo)

        manager.recordCellChange(
            rowIndex: 1,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Charlie",
            newValue: "Dave"
        )

        #expect(!manager.canRedo)
    }

    @Test("Initial state has canUndo false and canRedo false")
    func initialUndoRedoState() async {
        let manager = DataChangeManager()

        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
    }

    // MARK: - Reload Version Tests

    @Test("reloadVersion increments on change")
    func reloadVersionIncrementsOnChange() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        let initialVersion = manager.reloadVersion

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        #expect(manager.reloadVersion == initialVersion + 1)
    }

    @Test("reloadVersion increments on clearChanges")
    func reloadVersionIncrementsOnClear() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"]
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        let versionBeforeClear = manager.reloadVersion

        manager.clearChanges()

        #expect(manager.reloadVersion == versionBeforeClear + 1)
    }
}
