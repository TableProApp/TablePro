//
//  StructureChangeManagerUndoTests.swift
//  TableProTests
//
//  Tests for S-01: Undo/Redo must be functional in StructureChangeManager
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

// MARK: - StructureChangeManager Undo Integration Tests

@Suite("Structure Change Manager Undo/Redo Integration")
struct StructureChangeManagerUndoTests {

    // MARK: - Helpers

    @MainActor private func makeManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        return manager
    }

    @MainActor private func loadSampleSchema(_ manager: StructureChangeManager) {
        let columns: [ColumnInfo] = [
            ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
            ColumnInfo(name: "name", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
            ColumnInfo(name: "email", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                       defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
        ]
        let indexes: [IndexInfo] = [
            IndexInfo(name: "PRIMARY", columns: ["id"], isUnique: true, isPrimary: true,
                      type: "BTREE")
        ]
        manager.loadSchema(
            tableName: "users",
            columns: columns,
            indexes: indexes,
            foreignKeys: [],
            primaryKey: ["id"],
            databaseType: .mysql
        )
    }

    // MARK: - Column Undo Tests

    @Test("Undo column edit reverts to previous value")
    @MainActor func undoColumnEdit() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let nameCol = manager.workingColumns[1]
        var modified = nameCol
        modified.dataType = "TEXT"
        manager.updateColumn(id: nameCol.id, with: modified)

        #expect(manager.workingColumns[1].dataType == "TEXT")
        #expect(manager.hasChanges == true)
        #expect(manager.canUndo == true)

        manager.undo()
        #expect(manager.workingColumns[1].dataType == "VARCHAR(255)")
        #expect(manager.hasChanges == false)
    }

    @Test("Redo column edit re-applies the change")
    @MainActor func redoColumnEdit() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let nameCol = manager.workingColumns[1]
        var modified = nameCol
        modified.dataType = "TEXT"
        manager.updateColumn(id: nameCol.id, with: modified)

        manager.undo()
        #expect(manager.workingColumns[1].dataType == "VARCHAR(255)")

        manager.redo()
        #expect(manager.workingColumns[1].dataType == "TEXT")
        #expect(manager.hasChanges == true)
    }

    @Test("Undo add column removes it")
    @MainActor func undoAddColumn() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let initialCount = manager.workingColumns.count
        manager.addNewColumn()
        #expect(manager.workingColumns.count == initialCount + 1)
        #expect(manager.canUndo == true)

        manager.undo()
        #expect(manager.workingColumns.count == initialCount)
    }

    @Test("Undo delete column restores it")
    @MainActor func undoDeleteColumn() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let emailCol = manager.workingColumns[2]
        manager.deleteColumn(id: emailCol.id)
        #expect(manager.hasChanges == true)
        #expect(manager.canUndo == true)

        manager.undo()
        let change = manager.pendingChanges[.column(emailCol.id)]
        #expect(change == nil)
        #expect(manager.hasChanges == false)
    }

    @Test("Multiple undo operations work in sequence")
    @MainActor func multipleUndos() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let nameCol = manager.workingColumns[1]
        var mod1 = nameCol
        mod1.dataType = "TEXT"
        manager.updateColumn(id: nameCol.id, with: mod1)

        let emailCol = manager.workingColumns[2]
        var mod2 = emailCol
        mod2.dataType = "TEXT"
        manager.updateColumn(id: emailCol.id, with: mod2)

        manager.undo()
        #expect(manager.workingColumns[2].dataType == "VARCHAR(255)")
        #expect(manager.workingColumns[1].dataType == "TEXT")

        manager.undo()
        #expect(manager.workingColumns[1].dataType == "VARCHAR(255)")
        #expect(manager.hasChanges == false)
    }

    // MARK: - Index Undo Tests

    @Test("Undo add index removes it")
    @MainActor func undoAddIndex() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let initialCount = manager.workingIndexes.count
        manager.addNewIndex()
        #expect(manager.workingIndexes.count == initialCount + 1)
        #expect(manager.canUndo == true)

        manager.undo()
        #expect(manager.workingIndexes.count == initialCount)
    }

    @Test("Undo delete index restores it")
    @MainActor func undoDeleteIndex() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let primaryIndex = manager.workingIndexes[0]
        manager.deleteIndex(id: primaryIndex.id)
        #expect(manager.hasChanges == true)

        manager.undo()
        let change = manager.pendingChanges[.index(primaryIndex.id)]
        #expect(change == nil)
        #expect(manager.hasChanges == false)
    }

    // MARK: - Foreign Key Undo Tests

    @Test("Undo add foreign key removes it")
    @MainActor func undoAddForeignKey() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let initialCount = manager.workingForeignKeys.count
        manager.addNewForeignKey()
        #expect(manager.workingForeignKeys.count == initialCount + 1)

        manager.undo()
        #expect(manager.workingForeignKeys.count == initialCount)
    }

    // MARK: - Duplicate Row Bug Tests

    @Test("Undo delete of existing column does NOT duplicate the row")
    @MainActor func undoDeleteExistingColumnNoDuplicate() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let initialCount = manager.workingColumns.count
        let emailCol = manager.workingColumns[2]

        manager.deleteColumn(id: emailCol.id)
        #expect(manager.workingColumns.count == initialCount)
        #expect(manager.hasChanges == true)

        manager.undo()
        #expect(manager.workingColumns.count == initialCount)
        #expect(manager.hasChanges == false)
    }

    @Test("Undo two sequential deletes of existing columns restores both without duplicates")
    @MainActor func undoTwoDeletesNoDuplicates() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let initialCount = manager.workingColumns.count
        let nameCol = manager.workingColumns[1]
        let emailCol = manager.workingColumns[2]

        manager.deleteColumn(id: nameCol.id)
        manager.deleteColumn(id: emailCol.id)
        #expect(manager.workingColumns.count == initialCount)

        manager.undo()
        #expect(manager.workingColumns.count == initialCount)
        #expect(manager.pendingChanges[.column(emailCol.id)] == nil)
        #expect(manager.pendingChanges[.column(nameCol.id)] != nil)

        manager.undo()
        #expect(manager.workingColumns.count == initialCount)
        #expect(manager.pendingChanges[.column(nameCol.id)] == nil)
        #expect(manager.hasChanges == false)
    }

    @Test("Undo delete of NEW column re-adds it")
    @MainActor func undoDeleteNewColumnReAdds() {
        let manager = makeManager()
        loadSampleSchema(manager)

        let initialCount = manager.workingColumns.count

        manager.addNewColumn()
        #expect(manager.workingColumns.count == initialCount + 1)
        let newCol = manager.workingColumns.last!

        manager.deleteColumn(id: newCol.id)
        #expect(manager.workingColumns.count == initialCount)

        manager.undo()
        #expect(manager.workingColumns.count == initialCount + 1)
        #expect(manager.workingColumns.contains(where: { $0.id == newCol.id }))
    }

    // MARK: - Discard Clears Undo

    @Test("Discard changes clears undo stack")
    @MainActor func discardClearsUndo() {
        let manager = makeManager()
        loadSampleSchema(manager)

        manager.addNewColumn()
        #expect(manager.canUndo == true)

        manager.discardChanges()
        #expect(manager.canUndo == false)
        #expect(manager.canRedo == false)
    }
}
