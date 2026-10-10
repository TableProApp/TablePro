//
//  StructureChangeManagerTableCommentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureChangeManagerTableCommentTests {
    private func makeManager(comment: String? = "Customer orders") -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "total", dataType: "INT", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"],
            tableComment: comment
        )
        return manager
    }

    private func typeKeystrokes(_ text: String, into manager: StructureChangeManager) {
        var typed = ""
        for character in text {
            typed.append(character)
            manager.stageTableComment(typed)
        }
    }

    private func rename(_ manager: StructureChangeManager, at row: Int, to name: String) {
        var column = manager.workingColumns[row]
        column.name = name
        manager.updateColumn(id: column.id, with: column)
    }

    @Test("Loading seeds the comment with nothing staged and nothing to undo")
    func loadSeedsTheComment() {
        let manager = makeManager()

        #expect(manager.tableComment.original == "Customer orders")
        #expect(manager.tableComment.text == "Customer orders")
        #expect(!manager.hasChanges)
        #expect(!manager.canUndo)
    }

    @Test("A different text stages exactly one comment change")
    func differentTextStagesOneChange() {
        let manager = makeManager()

        manager.stageTableComment("Orders placed online")

        #expect(manager.getChangesArray() == [.modifyTableComment(old: "Customer orders", new: "Orders placed online")])
    }

    @Test("Typing the comment back to what it was stages nothing")
    func typingBackUnstages() {
        let manager = makeManager()

        manager.stageTableComment("Orders")
        manager.stageTableComment("Customer orders")

        #expect(!manager.hasChanges)
    }

    @Test("Whitespace-only text removes a comment, and stages nothing where there was none")
    func whitespaceRemovesOnlyAnExistingComment() {
        let commented = makeManager()
        commented.stageTableComment("   ")
        #expect(commented.getChangesArray() == [.modifyTableComment(old: "Customer orders", new: nil)])

        let uncommented = makeManager(comment: nil)
        uncommented.stageTableComment("   ")
        #expect(!uncommented.hasChanges)
    }

    @Test("A typing run is one undo step, and redo brings it back")
    func typingRunIsOneUndoStep() {
        let manager = makeManager(comment: nil)
        typeKeystrokes("Orders", into: manager)
        manager.endTableCommentRun()

        manager.undo()
        #expect(manager.tableComment.text.isEmpty)
        #expect(!manager.hasChanges)
        #expect(!manager.canUndo)

        manager.redo()
        #expect(manager.tableComment.text == "Orders")
        #expect(manager.getChangesArray() == [.modifyTableComment(old: nil, new: "Orders")])
    }

    @Test("Undo during an open run reverts the whole run")
    func undoEndsTheOpenRun() {
        let manager = makeManager()
        typeKeystrokes(" (archived)", into: manager)

        #expect(manager.hasTableCommentRun)
        #expect(manager.canUndo)
        #expect(!manager.canRedo)

        manager.undo()

        #expect(!manager.hasTableCommentRun)
        #expect(manager.tableComment.text == "Customer orders")
        #expect(!manager.hasChanges)
    }

    @Test("A column edit after typing undoes first, the comment second")
    func columnEditAfterTypingIsItsOwnStep() {
        let manager = makeManager()
        manager.stageTableComment("Orders")
        rename(manager, at: 1, to: "amount")

        manager.undo()
        #expect(manager.workingColumns[1].name == "total")
        #expect(manager.tableComment.text == "Orders")

        manager.undo()
        #expect(manager.tableComment.text == "Customer orders")
        #expect(!manager.hasChanges)
    }

    @Test("Discard restores the loaded comment and drops the run")
    func discardRestoresTheComment() {
        let manager = makeManager()
        manager.stageTableComment("Orders")

        manager.discardChanges()

        #expect(manager.tableComment.text == "Customer orders")
        #expect(!manager.hasTableCommentRun)
        #expect(!manager.hasChanges)
        #expect(!manager.canUndo)
    }

    @Test("A save hold ends the run as an undo step and refuses more typing")
    func holdRefusesStaging() throws {
        let manager = makeManager()
        manager.stageTableComment("Orders")
        let staged = manager.getChangesArray()

        _ = try #require(manager.holdForSave())
        manager.stageTableComment("Something else")

        #expect(!manager.hasTableCommentRun)
        #expect(manager.tableComment.text == "Orders")
        #expect(manager.getChangesArray() == staged)
    }

    @Test("A save that wrote shows the written comment with nothing staged")
    func writtenReleaseAdoptsTheComment() throws {
        let manager = makeManager()
        manager.stageTableComment("Orders")
        let hold = try #require(manager.holdForSave())

        #expect(manager.releaseHold(hold, written: true))

        #expect(manager.tableComment.original == "Orders")
        #expect(manager.tableComment.text == "Orders")
        #expect(!manager.hasChanges)
    }

    @Test("A save that did not write keeps the comment staged and undoable")
    func unwrittenReleaseKeepsTheComment() throws {
        let manager = makeManager()
        manager.stageTableComment("Orders")
        let hold = try #require(manager.holdForSave())

        #expect(!manager.releaseHold(hold, written: false))

        #expect(manager.getChangesArray() == [.modifyTableComment(old: "Customer orders", new: "Orders")])
        #expect(manager.canUndo)
    }

    @Test("Undo on the DDL sub-tab reaches the comment step and nothing behind it")
    func undoOnDDLReachesOnlyTheComment() {
        let manager = makeManager()
        rename(manager, at: 1, to: "amount")
        manager.stageTableComment("Orders")
        let delegate = StructureGridDelegate(
            structureChangeManager: manager,
            selectedTab: .ddl,
            connection: TestFixtures.makeConnection(type: .postgresql),
            tableName: "orders",
            coordinator: nil
        )

        delegate.dataGridUndo()
        #expect(manager.tableComment.text == "Customer orders")

        delegate.dataGridUndo()
        #expect(manager.workingColumns[1].name == "amount")

        delegate.dataGridRedo()
        #expect(manager.tableComment.text == "Orders")
    }

    @Test("Undo on the Triggers sub-tab leaves a column edit alone")
    func undoOnTriggersSkipsColumnEdits() {
        let manager = makeManager()
        rename(manager, at: 1, to: "amount")
        let delegate = StructureGridDelegate(
            structureChangeManager: manager,
            selectedTab: .triggers,
            connection: TestFixtures.makeConnection(type: .postgresql),
            tableName: "orders",
            coordinator: nil
        )

        delegate.dataGridUndo()

        #expect(manager.workingColumns[1].name == "amount")
    }
}
