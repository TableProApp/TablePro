//
//  CreateTableDraftCommandTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct CreateTableDraftCommandTests {
    private func makeDraft(database: String = "app", schema: String? = "sales") -> CreateTableDraft {
        let connection = TestFixtures.makeConnection(database: "postgres", type: .postgresql)
        let draft = CreateTableDraft(
            connection: connection,
            scope: DatabaseScope(connectionId: connection.id, database: database, schema: schema)
        )
        draft.resolveForm(from: nil)
        return draft
    }

    @Test("Add Row adds a column while nothing is selected")
    func addRowDefaultsToColumns() {
        let draft = makeDraft()

        #expect(draft.canAddRow)
        draft.addRow()

        #expect(draft.changeManager.workingColumns.count == 2)
        #expect(draft.editor.inspectorTarget == .entity(.columns, draft.changeManager.workingColumns[1].id))
    }

    @Test("Add Row adds to the section holding the selection")
    func addRowFollowsTheFocusedSection() {
        let draft = makeDraft()
        draft.editor.add(.indexes)

        draft.addRow()

        #expect(draft.changeManager.workingIndexes.count == 2)
        #expect(draft.changeManager.workingColumns.count == 1)
        #expect(draft.commandSection == .indexes)
    }

    @Test("Add Row does nothing while the DDL is on screen")
    func addRowNeedsTheDefinition() {
        let draft = makeDraft()
        draft.pane = .ddl

        draft.addRow()

        #expect(!draft.canAddRow)
        #expect(draft.changeManager.workingColumns.count == 1)
    }

    @Test("Remove deletes the selected definition, and Undo brings it back")
    func removeThenUndo() {
        let draft = makeDraft()
        draft.addRow()
        let added = draft.changeManager.workingColumns[1].id

        #expect(draft.canRemoveRows)
        draft.removeSelectedRows()
        #expect(draft.changeManager.workingColumns.map { $0.id }.contains(added) == false)

        #expect(draft.canUndo)
        draft.undo()
        #expect(draft.changeManager.workingColumns.map { $0.id }.contains(added))
        #expect(draft.editor.adapter(for: .columns).visibleRowCount == 2)
    }

    @Test("Undo takes back an added row and Redo restores it")
    func undoThenRedo() {
        let draft = makeDraft()
        draft.editor.add(.checkConstraints)
        #expect(draft.changeManager.workingCheckConstraints.count == 1)

        draft.undo()
        #expect(draft.changeManager.workingCheckConstraints.isEmpty)
        #expect(draft.editor.adapter(for: .checkConstraints).visibleRowCount == 0)

        #expect(draft.canRedo)
        draft.redo()
        #expect(draft.changeManager.workingCheckConstraints.count == 1)
    }

    @Test("A typed check counts as work worth protecting")
    func checkConstraintHoldsWork() {
        let draft = makeDraft()
        draft.editor.add(.checkConstraints)
        #expect(!draft.holdsWork)

        draft.changeManager.workingCheckConstraints[0].expression = "total > 0"

        #expect(draft.holdsWork)
        #expect(draft.hasChanges)
    }

    @Test("An issue on a row reveals that row in its section")
    func revealingAnIssueSelectsItsRow() throws {
        let draft = makeDraft()
        draft.tableName = "orders"
        draft.changeManager.workingColumns[0].name = "id"
        draft.editor.refresh()
        draft.pane = .ddl

        let issue = try #require(draft.issues.first { $0.row == 0 })
        draft.reveal(issue)

        #expect(issue.section == .columns)
        #expect(draft.pane == .definition)
        #expect(draft.editor.inspectorTarget == .entity(.columns, draft.changeManager.workingColumns[0].id))
    }

    @Test("A named table with a typed column is ready to create before the composition lands")
    func readyFromThePlan() {
        let draft = makeDraft()
        #expect(!draft.isReadyToCreate)

        draft.tableName = "orders"
        draft.changeManager.workingColumns[0].name = "id"
        draft.changeManager.workingColumns[0].dataType = "INT"

        #expect(draft.issues.isEmpty)
        #expect(draft.isReadyToCreate)
    }

    // The sidebar can browse another database while the tab creates its table in its own (#10 in the verify lane).
    @Test("The editor works on the tab's database and schema, never the sidebar's")
    func editorUsesTheTabScope() {
        let draft = makeDraft(database: "app", schema: "sales")
        let scope = DatabaseScope(connectionId: draft.connection.id, database: "app", schema: "sales")

        #expect(draft.editor.context.isCreatingTable)
        #expect(draft.editor.context.scope == scope)
        #expect(draft.editor.referenceMenus.schemaName == "sales")
        #expect(draft.editor.adapter(for: .columns).model.configuration.traits.connectionScope?.database == "app")

        draft.editor.add(.foreignKeys)
        _ = draft.editor.adapter(for: .foreignKeys).menuOptions(sourceIndex: 0, field: 1)

        #expect(draft.editor.referenceMenus.origin == scope)
    }
}
