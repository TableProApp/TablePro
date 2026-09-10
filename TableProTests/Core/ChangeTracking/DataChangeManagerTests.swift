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
            databaseType: .postgresql,
            generatedColumns: []
        )

        #expect(manager.tableName == "users")
        #expect(manager.columns == ["id", "name", "email"])
        #expect(manager.primaryKeyColumn == "id")
        #expect(manager.databaseType == .postgresql)
    }

    @Test("generateSQL throws when the table dialect is not configured")
    func generateSQLThrowsWhenDialectNotConfigured() {
        let manager = DataChangeManager()
        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        #expect(manager.databaseType == nil)
        #expect(throws: (any Error).self) {
            _ = try manager.generateSQL()
        }
    }

    @Test("configureForTable clears existing changes")
    func configureForTableClearsChanges() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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
    /// `reloadVersion` is the signal that tells the grid to throw away what it is showing and fetch
    /// again. It increments on `clearChanges`, `discardChanges` and `configureForTable`, and
    /// deliberately not on recording an edit: a reload there would discard the very edit the user
    /// just made. These asserted the opposite, which is why they sat in the quarantine file, so
    /// each now pins the real contract from both sides.
    func reloadVersionTracksReloadsNotEdits() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )

        let initialVersion = manager.reloadVersion

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob"
        )

        #expect(manager.reloadVersion == initialVersion)

        manager.clearChanges()

        #expect(manager.reloadVersion == initialVersion + 1)
    }

    @Test("reloadVersion increments on clearChanges")
    func reloadVersionIncrementsOnClear() async {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
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

/// Paste, Fill Column and the row inspector all reach `recordCellChange` directly, without passing
/// the grid's own writability check. A server-owned column could be staged there, silently filtered
/// out during statement generation, and then cleared by a save that reported success.
@MainActor
@Suite("Data Change Manager - non-writable columns")
struct DataChangeManagerNonWritableTests {
    private func makeManager(generatedColumns: Set<String>) -> DataChangeManager {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: generatedColumns
        )
        return manager
    }

    @Test("An edit to a server-owned column is refused")
    func refusesServerOwnedColumn() {
        let manager = makeManager(generatedColumns: ["id"])

        manager.recordCellChange(
            rowIndex: 0, columnIndex: 0, columnName: "id",
            oldValue: .text("1"), newValue: .text("99")
        )

        #expect(!manager.hasChanges)
        #expect(manager.rowChanges.isEmpty)
    }

    @Test("An edit to a writable column is still recorded")
    func recordsWritableColumn() {
        let manager = makeManager(generatedColumns: ["id"])

        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: .text("Alice"), newValue: .text("Bob")
        )

        #expect(manager.hasChanges)
    }

    /// The refusal must not leave the other edits of the same save behind.
    @Test("A refused edit does not disturb a legitimate one recorded alongside it")
    func refusalLeavesOtherEditsIntact() {
        let manager = makeManager(generatedColumns: ["id"])

        manager.recordCellChange(
            rowIndex: 0, columnIndex: 1, columnName: "name",
            oldValue: .text("Alice"), newValue: .text("Bob")
        )
        manager.recordCellChange(
            rowIndex: 0, columnIndex: 0, columnName: "id",
            oldValue: .text("1"), newValue: .text("99")
        )

        #expect(manager.hasChanges)
        let edited = manager.rowChanges.flatMap(\.cellChanges).map(\.columnName)
        #expect(edited == ["name"])
    }
}

/// `immutableColumns` is the driver's own list, such as MongoDB's `_id`. The grid consults it and
/// the model boundary did not, so the row inspector could still stage a change the backend rejects.
@MainActor
@Suite("Data Change Manager - immutable columns")
struct DataChangeManagerImmutableColumnTests {
    @Test("A writable column with no generated set is accepted")
    func writableColumnAccepted() {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "orders",
            columns: ["id", "total"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: []
        )

        #expect(manager.isColumnWritable("total"))
    }

    @Test("A generated column is not writable")
    func generatedColumnNotWritable() {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "orders",
            columns: ["id", "total"],
            primaryKeyColumns: ["id"],
            databaseType: .postgresql,
            generatedColumns: ["total"]
        )

        #expect(!manager.isColumnWritable("total"))
    }
}
