//
//  StructureChangeManagerTableCommentTests.swift
//  TableProTests
//
//  Staging, undo and baselining for the table comment the Properties tab edits.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Structure Change Manager Table Comment")
struct StructureChangeManagerTableCommentTests {

    @MainActor private func makeManager(baseline: String?) -> StructureChangeManager {
        let manager = StructureChangeManager()
        manager.loadSchema(
            tableName: "users",
            columns: [],
            indexes: [],
            foreignKeys: [],
            primaryKey: []
        )
        manager.setTableCommentBaseline(baseline)
        return manager
    }

    @Test("A missing comment baselines to the empty string")
    @MainActor func nilBaselineIsEmpty() {
        let manager = makeManager(baseline: nil)

        #expect(manager.currentTableComment == "")
        #expect(manager.workingTableComment == "")
        #expect(manager.hasChanges == false)
    }

    @Test("Editing the comment stages one change")
    @MainActor func editStagesChange() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("new")

        #expect(manager.workingTableComment == "new")
        #expect(manager.hasChanges)
        #expect(manager.getChangesArray() == [.modifyTableComment(old: "old", new: "new")])
    }

    @Test("Clearing the comment stages a nil replacement")
    @MainActor func clearStagesNil() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("")

        #expect(manager.getChangesArray() == [.modifyTableComment(old: "old", new: nil)])
    }

    @Test("Typing back to the baseline drops the staged change")
    @MainActor func returningToBaselineClearsChange() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("new")
        manager.setTableComment("old")

        #expect(manager.hasChanges == false)
        #expect(manager.getChangesArray().isEmpty)
    }

    @Test("Undo reverts the comment and its staged change")
    @MainActor func undoRevertsComment() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("new")

        #expect(manager.canUndo)
        manager.undo()

        #expect(manager.workingTableComment == "old")
        #expect(manager.hasChanges == false)
    }

    /// The field writes on every character, so a per-keystroke entry would fill all 100 levels of
    /// undo from one paragraph and evict the column edits staged beside it.
    @Test("Typing many characters leaves one undo step")
    @MainActor func typingCoalescesIntoOneUndoStep() {
        let manager = makeManager(baseline: "")
        for text in ["h", "he", "hel", "hell", "hello"] {
            manager.setTableComment(text)
        }

        manager.undo()

        #expect(manager.workingTableComment == "")
        #expect(manager.hasChanges == false)
        #expect(manager.canUndo == false)
    }

    @Test("Redo puts the comment back")
    @MainActor func redoRestoresComment() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("new")
        manager.undo()

        #expect(manager.canRedo)
        manager.redo()

        #expect(manager.workingTableComment == "new")
        #expect(manager.getChangesArray() == [.modifyTableComment(old: "old", new: "new")])
    }

    @Test("Undo and redo alternate more than once")
    @MainActor func undoRedoAlternates() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("new")

        for _ in 0..<3 {
            manager.undo()
            #expect(manager.workingTableComment == "old")
            manager.redo()
            #expect(manager.workingTableComment == "new")
        }

        #expect(manager.hasChanges)
    }

    @Test("Discarding reverts the comment to its baseline")
    @MainActor func discardRevertsComment() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("new")
        manager.discardChanges()

        #expect(manager.workingTableComment == "old")
        #expect(manager.hasChanges == false)
    }

    /// A fresh baseline arrives after every save and every refresh, and it must not overwrite what
    /// the user is typing. Only an unstaged field follows the database.
    @Test("A new baseline leaves a staged edit alone")
    @MainActor func baselineDoesNotClobberStagedEdit() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("mine")
        manager.setTableCommentBaseline("theirs")

        #expect(manager.workingTableComment == "mine")
        #expect(manager.getChangesArray() == [.modifyTableComment(old: "theirs", new: "mine")])
    }

    /// A refresh that finds the server already holding what the user typed leaves nothing to write,
    /// so the staged change goes rather than saving a statement that changes nothing.
    @Test("A baseline that catches up with the edit drops the staged change")
    @MainActor func baselineMatchingEditDropsChange() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("mine")
        manager.setTableCommentBaseline("mine")

        #expect(manager.workingTableComment == "mine")
        #expect(manager.hasChanges == false)
    }

    @Test("A new baseline moves an unstaged field")
    @MainActor func baselineMovesUnstagedField() {
        let manager = makeManager(baseline: "old")
        manager.setTableCommentBaseline("fresh")

        #expect(manager.workingTableComment == "fresh")
        #expect(manager.hasChanges == false)
    }

    /// `loadSchema` is the "adopt a new baseline" entry point and clears every staged edit. The
    /// comment has to travel with the rest rather than surviving as an orphan pending change.
    @Test("Reloading the schema resets the comment with everything else")
    @MainActor func loadSchemaResetsComment() {
        let manager = makeManager(baseline: "old")
        manager.setTableComment("new")

        manager.loadSchema(
            tableName: "users",
            columns: [],
            indexes: [],
            foreignKeys: [],
            primaryKey: []
        )

        #expect(manager.workingTableComment == "old")
        #expect(manager.hasChanges == false)
    }
}
