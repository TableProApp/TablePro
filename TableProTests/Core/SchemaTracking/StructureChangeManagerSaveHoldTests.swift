//
//  StructureChangeManagerSaveHoldTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// A save writes the edits staged when it was pressed and clears them when it lands. Staging stayed
/// open in between, so on MongoDB, where the save reads every document it changes before writing,
/// an edit made during that read was left out of the script and then cleared with the edits that
/// did run.
@MainActor
struct StructureChangeManagerSaveHoldTests {
    private func makeManager() -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "users",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "name", dataType: "TEXT", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "email", dataType: "TEXT", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        return manager
    }

    private func rename(_ manager: StructureChangeManager, at row: Int, to name: String) {
        var column = manager.workingColumns[row]
        column.name = name
        manager.updateColumn(id: column.id, with: column)
    }

    @Test("A hold takes exactly what is staged, and a second one is refused")
    func holdTakesTheStagedEdits() throws {
        let manager = makeManager()
        rename(manager, at: 1, to: "full_name")
        let staged = manager.getChangesArray()

        let hold = try #require(manager.holdForSave())

        #expect(hold.changes == staged)
        #expect(manager.isHeldForSave)
        #expect(manager.holdForSave() == nil)
    }

    @Test("Nothing staged is nothing to hold")
    func nothingStagedIsNotHeld() {
        let manager = makeManager()
        #expect(manager.holdForSave() == nil)
        #expect(!manager.isHeldForSave)
    }

    @Test("Every way of staging, undoing, discarding or reloading is refused while a save holds the edits")
    func everyStagingPathIsRefusedWhileHeld() throws {
        let manager = makeManager()
        rename(manager, at: 1, to: "full_name")
        let staged = manager.getChangesArray()
        let working = manager.workingColumns
        _ = try #require(manager.holdForSave())

        manager.addNewColumn()
        manager.addNewIndex()
        manager.addNewForeignKey()
        manager.addNewCheckConstraint()
        manager.addColumn(EditableColumnDefinition.placeholder())
        rename(manager, at: 2, to: "mail")
        manager.deleteColumn(id: manager.workingColumns[2].id)
        manager.performAsOneUndoStep { manager.deleteColumn(id: manager.workingColumns[0].id) }
        manager.undoDelete(for: .columns, at: 2)
        manager.undo()
        manager.redo()
        manager.discardChanges()
        manager.loadSchema(tableName: "users", columns: [], indexes: [], foreignKeys: [], primaryKey: [])

        #expect(manager.getChangesArray() == staged)
        #expect(manager.workingColumns == working)
        #expect(manager.tableName == "users")
        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
    }

    @Test("A save that wrote clears the edits it held and opens staging again")
    func writtenSaveClearsWhatItHeld() throws {
        let manager = makeManager()
        rename(manager, at: 1, to: "full_name")
        let hold = try #require(manager.holdForSave())

        #expect(manager.releaseHold(hold, written: true))
        #expect(!manager.hasChanges)
        #expect(!manager.isHeldForSave)

        rename(manager, at: 2, to: "mail")
        #expect(manager.hasChanges)
    }

    @Test("A save that did not write leaves the edits staged and editable")
    func unwrittenSaveKeepsTheEdits() throws {
        let manager = makeManager()
        rename(manager, at: 1, to: "full_name")
        let staged = manager.getChangesArray()
        let hold = try #require(manager.holdForSave())

        #expect(!manager.releaseHold(hold, written: false))
        #expect(manager.getChangesArray() == staged)
        #expect(!manager.isHeldForSave)
        #expect(manager.canUndo)

        rename(manager, at: 2, to: "mail")
        #expect(manager.getChangesArray().count == 2)
    }

    /// A completion that arrives for a hold that has already ended must not clear what was staged
    /// after it. Only the hold a save still owns can clear, and only the edits it took.
    @Test("An ended hold cannot clear edits staged after it")
    func endedHoldClearsNothing() throws {
        let manager = makeManager()
        rename(manager, at: 1, to: "full_name")
        let hold = try #require(manager.holdForSave())
        manager.releaseHold(hold, written: false)
        rename(manager, at: 2, to: "mail")
        let staged = manager.getChangesArray()

        #expect(!manager.releaseHold(hold, written: true))
        #expect(manager.getChangesArray() == staged)

        let second = try #require(manager.holdForSave())
        #expect(!manager.releaseHold(hold, written: true))
        #expect(manager.isHeldForSave)
        #expect(manager.releaseHold(second, written: true))
        #expect(!manager.hasChanges)
    }
}
