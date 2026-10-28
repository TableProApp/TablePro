//
//  StructureChangeManagerTableOptionsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureChangeManagerTableOptionsTests {
    private static let loaded = TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci", autoIncrement: 4)

    private func makeManager(
        options: TableOptions? = StructureChangeManagerTableOptionsTests.loaded,
        idType: String = "INT",
        autoIncrement: Bool = true
    ) -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "t",
            columns: [
                ColumnInfo(name: "id", dataType: idType, isNullable: false, isPrimaryKey: true,
                           extra: autoIncrement ? "auto_increment" : nil),
                ColumnInfo(name: "name", dataType: "VARCHAR(32)", isNullable: true, isPrimaryKey: false,
                           charset: "latin1", collation: "latin1_swedish_ci")
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"],
            tableOptions: options
        )
        return manager
    }

    private func staged(_ manager: StructureChangeManager, _ edit: (inout TableOptions) -> Void) {
        guard var options = manager.tableOptions.current else {
            Issue.record("No table options loaded")
            return
        }
        edit(&options)
        manager.stageTableOptions(options)
    }

    private static func toUTF8(_ options: inout TableOptions) {
        options.characterSet = "utf8mb4"
        options.collation = "utf8mb4_0900_ai_ci"
    }

    private func edit(_ manager: StructureChangeManager, column row: Int, _ change: (inout EditableColumnDefinition) -> Void) {
        var column = manager.workingColumns[row]
        change(&column)
        manager.updateColumn(id: column.id, with: column)
    }

    @Test("Text in Next Auto Increment that is not a counter holds Save and counts as unsaved until cleared")
    func invalidCounterEntryHoldsTheSave() {
        let manager = makeManager()
        staged(manager, Self.toUTF8)
        manager.noteAutoIncrementEntry(invalid: "Enter a whole number from 1 to 2147483647.")

        #expect(manager.hasChanges)
        #expect(!manager.canCommit)
        #expect(manager.validationErrors[.autoIncrement] == "Enter a whole number from 1 to 2147483647.")

        manager.noteAutoIncrementEntry(invalid: nil)
        #expect(manager.canCommit)

        manager.noteAutoIncrementEntry(invalid: "Enter a whole number from 1 to 2147483647.")
        manager.discardChanges()
        #expect(!manager.hasChanges)
        #expect(manager.validationErrors.isEmpty)
    }

    @Test("A table with no AUTO_INCREMENT column keeps no counter text to hold Save with")
    func invalidCounterEntryNeedsACounter() {
        let manager = makeManager(autoIncrement: false)
        manager.noteAutoIncrementEntry(invalid: "Enter a whole number from 1 to 2147483647.")
        #expect(!manager.hasChanges)
    }

    @Test("Loading seeds the options with nothing staged and nothing to undo")
    func loadSeedsTheOptions() {
        let manager = makeManager()

        #expect(manager.tableOptions.original == Self.loaded)
        #expect(manager.tableOptions.current == Self.loaded)
        #expect(!manager.hasChanges)
        #expect(!manager.canUndo)
    }

    @Test("A new character set and collation stage one change, written as one value")
    func characterSetStagesOneChange() {
        let manager = makeManager()

        staged(manager, Self.toUTF8)

        #expect(manager.getChangesArray() == [.modifyTableCharacterSet(
            old: TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci"),
            new: TableOptions(characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci")
        )])
    }

    @Test("A character set and a counter stage two changes, and setting them back stages none")
    func bothStageTwoChanges() {
        let manager = makeManager()

        staged(manager) { Self.toUTF8(&$0); $0.autoIncrement = 500 }
        #expect(manager.pendingChanges[.tableCharacterSet] != nil)
        #expect(manager.pendingChanges[.autoIncrement] == .modifyAutoIncrement(old: 4, new: 500))

        manager.stageTableOptions(Self.loaded)
        #expect(!manager.hasChanges)
    }

    @Test("A counter edit leaves the staged character set change as it was")
    func counterEditKeepsTheCharacterSetChange() {
        let manager = makeManager()
        staged(manager, Self.toUTF8)
        let characterSetChange = manager.pendingChanges[.tableCharacterSet]

        staged(manager) { $0.autoIncrement = 900 }

        #expect(manager.pendingChanges[.tableCharacterSet] == characterSetChange)
    }

    @Test("Each write is one undo step, and redo brings it back")
    func eachWriteIsOneUndoStep() {
        let manager = makeManager()
        staged(manager, Self.toUTF8)
        staged(manager) { $0.autoIncrement = 500 }

        manager.undo()
        #expect(manager.tableOptions.current?.autoIncrement == 4)
        #expect(manager.tableOptions.current?.characterSet == "utf8mb4")
        #expect(manager.pendingChanges[.autoIncrement] == nil)

        manager.undo()
        #expect(manager.tableOptions.current == Self.loaded)
        #expect(!manager.hasChanges)
        #expect(!manager.canUndo)

        manager.redo()
        #expect(manager.tableOptions.current?.collation == "utf8mb4_0900_ai_ci")
        #expect(manager.pendingChanges[.tableCharacterSet] != nil)
    }

    @Test("Discard restores the loaded options")
    func discardRestoresTheOptions() {
        let manager = makeManager()
        staged(manager) { Self.toUTF8(&$0); $0.convertsColumns = true; $0.autoIncrement = 500 }

        manager.discardChanges()

        #expect(manager.tableOptions.current == Self.loaded)
        #expect(!manager.hasChanges)
        #expect(!manager.canUndo)
    }

    @Test("Options that failed to load stage nothing")
    func failedReadStagesNothing() {
        let manager = makeManager(options: nil)

        manager.stageTableOptions(TableOptions(characterSet: "utf8mb4", collation: "utf8mb4_bin", autoIncrement: 10))

        #expect(manager.tableOptions.current == nil)
        #expect(!manager.hasChanges)
        #expect(!manager.canUndo)
    }

    @Test("A save hold refuses a table options edit")
    func holdRefusesStaging() throws {
        let manager = makeManager()
        staged(manager, Self.toUTF8)
        let changes = manager.getChangesArray()
        _ = try #require(manager.holdForSave())

        manager.stageTableOptions(Self.loaded)

        #expect(manager.getChangesArray() == changes)
    }

    @Test("A save that wrote adopts the character set and keeps the counter's baseline for the re-read")
    func writtenReleaseAdoptsTheCharacterSetOnly() throws {
        let manager = makeManager()
        staged(manager) { Self.toUTF8(&$0); $0.convertsColumns = true; $0.autoIncrement = 2 }
        let hold = try #require(manager.holdForSave())

        #expect(manager.releaseHold(hold, written: true))

        #expect(manager.tableOptions.original == TableOptions(
            characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci", autoIncrement: 4
        ))
        #expect(manager.tableOptions.current == manager.tableOptions.original)
        #expect(!manager.hasChanges)
        #expect(!manager.tableOptions.isAutoIncrementConfirmed)
    }

    @Test("A save that did not write keeps the options staged")
    func unwrittenReleaseKeepsTheOptions() throws {
        let manager = makeManager()
        staged(manager, Self.toUTF8)
        let hold = try #require(manager.holdForSave())

        #expect(!manager.releaseHold(hold, written: false))

        #expect(manager.pendingChanges[.tableCharacterSet] != nil)
        #expect(manager.canUndo)
        #expect(manager.tableOptions.isAutoIncrementConfirmed)
    }

    @Test("A written counter refuses a counter edit through a discard, until a confirmed baseline loads")
    func writtenCounterRefusesEditsUntilConfirmed() throws {
        let manager = makeManager()
        staged(manager) { $0.autoIncrement = 500 }
        let hold = try #require(manager.holdForSave())
        #expect(manager.releaseHold(hold, written: true))

        staged(manager) { $0.autoIncrement = 6 }
        #expect(!manager.hasChanges)
        manager.discardChanges()
        #expect(!manager.tableOptions.isAutoIncrementConfirmed)

        manager.loadSchema(
            tableName: "t", columns: [], indexes: [], foreignKeys: [], primaryKey: [],
            tableOptions: TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci", autoIncrement: 500)
        )
        staged(manager) { $0.autoIncrement = 6 }
        #expect(manager.tableOptions.isAutoIncrementConfirmed)
        #expect(manager.pendingChanges[.autoIncrement] == .modifyAutoIncrement(old: 500, new: 6))
    }

    @Test("A save that wrote only the character set leaves the counter confirmed")
    func characterSetSaveKeepsTheCounterConfirmed() throws {
        let manager = makeManager()
        staged(manager, Self.toUTF8)
        let hold = try #require(manager.holdForSave())

        #expect(manager.releaseHold(hold, written: true))

        #expect(manager.tableOptions.isAutoIncrementConfirmed)
    }

    @Test("The counter is held to the AUTO_INCREMENT column's type")
    func counterOutOfRangeIsRefused() {
        let manager = makeManager(idType: "TINYINT")
        #expect(manager.autoIncrementRange == 1...127)

        staged(manager) { $0.autoIncrement = 1_000 }

        #expect(manager.validationErrors[.autoIncrement] != nil)
        #expect(!manager.canCommit)
    }

    @Test("A counter over the old type's maximum is valid once the same save widens the column")
    func counterFollowsTheDraftType() {
        let manager = makeManager(idType: "TINYINT")
        staged(manager) { $0.autoIncrement = 1_000 }

        edit(manager, column: 0) { $0.dataType = "INT" }

        #expect(manager.validationErrors[.autoIncrement] == nil)
        #expect(manager.canCommit)
    }

    @Test("A counter with no AUTO_INCREMENT column left is refused")
    func counterWithoutColumnIsRefused() {
        let manager = makeManager()
        staged(manager) { $0.autoIncrement = 50 }

        edit(manager, column: 0) { $0.autoIncrement = false }

        #expect(manager.autoIncrementColumn == nil)
        #expect(manager.validationErrors[.autoIncrement] != nil)
    }

    @Test("Turning AUTO_INCREMENT on in the save makes room for a counter on a table that had none")
    func counterOnANewlyAutoIncrementedColumn() {
        let manager = makeManager(
            options: TableOptions(characterSet: "latin1", collation: "latin1_swedish_ci"), autoIncrement: false
        )
        edit(manager, column: 0) { $0.autoIncrement = true }

        staged(manager) { $0.autoIncrement = 500 }

        #expect(manager.pendingChanges[.autoIncrement] == .modifyAutoIncrement(old: nil, new: 500))
        #expect(manager.canCommit)
    }

    private static let convertRefusal = "Save column and primary key changes before converting existing columns."

    private static func convertToUTF8(_ options: inout TableOptions) {
        toUTF8(&options)
        options.convertsColumns = true
    }

    @Test("A convert cannot share a save with a column change, staged in either order")
    func convertRefusesAColumnChange() {
        let manager = makeManager()
        staged(manager, Self.convertToUTF8)
        edit(manager, column: 1) { $0.comment = "Display name" }

        #expect(manager.validationErrors[.tableCharacterSet] == Self.convertRefusal)
        #expect(!manager.canCommit)

        manager.undo()
        #expect(manager.validationErrors[.tableCharacterSet] == nil)
        #expect(manager.canCommit)

        let columnFirst = makeManager()
        edit(columnFirst, column: 1) { $0.dataType = "TEXT" }
        staged(columnFirst, Self.convertToUTF8)
        #expect(columnFirst.validationErrors[.tableCharacterSet] == Self.convertRefusal)
    }

    @Test("A convert cannot share a save with a primary key change")
    func convertRefusesAPrimaryKeyChange() {
        let manager = makeManager()
        staged(manager, Self.convertToUTF8)

        edit(manager, column: 1) { $0.isPrimaryKey = true }

        #expect(manager.validationErrors[.tableCharacterSet] == Self.convertRefusal)
        #expect(!manager.canCommit)
    }

    @Test("A convert can share a save with column drops and additions, and a new default with column changes")
    func convertAllowsDropsAndAdditions() {
        let manager = makeManager()
        staged(manager, Self.convertToUTF8)
        manager.deleteColumn(id: manager.workingColumns[1].id)
        var note = EditableColumnDefinition.placeholder()
        note.name = "note"
        note.dataType = "VARCHAR(64)"
        manager.addColumn(note)

        #expect(manager.validationErrors.isEmpty)
        #expect(manager.canCommit)

        let defaultOnly = makeManager()
        staged(defaultOnly, Self.toUTF8)
        edit(defaultOnly, column: 1) { $0.comment = "Display name" }

        #expect(defaultOnly.validationErrors.isEmpty)
        #expect(defaultOnly.canCommit)
    }

    @Test("The Options sub-tab has no rows to mark")
    func optionsTabHasNoRowState() {
        let manager = makeManager()
        manager.deleteColumn(id: manager.workingColumns[1].id)

        let state = manager.deleteInsertState(for: 1, tab: .options)
        #expect(!state.isDeleted)
        #expect(!state.isInserted)
        manager.undoDelete(for: .options, at: 1)
        #expect(manager.hasChanges)
    }
}
