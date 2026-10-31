//
//  StructureCommandRoutingTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureCommandRoutingTests {
    private func makeSUT() -> (MainContentCommandActions, MainContentCoordinator) {
        let connection = TestFixtures.makeConnection()
        let coordinator = SessionStateFactory.create(connection: connection, payload: nil).coordinator
        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(get: { tableOperationOptions }, set: { tableOperationOptions = $0 }),
            trailingPaneState: TrailingPaneState()
        )
        return (actions, coordinator)
    }

    private func showStructure(of coordinator: MainContentCoordinator) throws -> StructureEditingSession {
        coordinator.tabManager.addTab(databaseName: "testdb")
        let index = try #require(coordinator.tabManager.selectedTabIndex)
        coordinator.tabManager.tabs[index].display.resultsViewMode = .structure
        let session = TestFixtures.makeStructureSession()
        session.changeManager.loadSchema(
            tableName: "users", columns: [], indexes: [], foreignKeys: [], primaryKey: []
        )
        coordinator.structureSessions[coordinator.tabManager.tabs[index].id] = session
        return session
    }

    private func showCreateTable(in coordinator: MainContentCoordinator) throws -> CreateTableDraft {
        coordinator.tabManager.addCreateTableTab(databaseName: "testdb")
        let id = try #require(coordinator.tabManager.selectedTabId)
        let draft = CreateTableDraft(connection: TestFixtures.makeConnection(), scope: nil)
        draft.resolveForm(from: nil)
        coordinator.createTableDrafts[id] = draft
        return draft
    }

    private func stageCellEdit(on coordinator: MainContentCoordinator) {
        coordinator.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
        coordinator.changeManager.recordRowDeletion(rowID: .existing(0), originalRow: [.text("1"), .text("ada")])
    }

    // MARK: - Undo

    // The menu used to stay lit in Structure whenever the view was mounted, with nothing to undo.
    @Test("Undo in Structure is dim and plainly titled with nothing staged")
    func structureUndoIsDimWithNothingStaged() throws {
        let (actions, coordinator) = makeSUT()
        _ = try showStructure(of: coordinator)

        #expect(!actions.canUndo)
        #expect(!actions.canRedo)
        #expect(actions.resolvedUndoTitle == String(localized: "Undo"))
        #expect(actions.resolvedRedoTitle == String(localized: "Redo"))
    }

    @Test("Undo in Structure is named and run by the session's own history")
    func structureUndoFollowsTheSession() throws {
        let (actions, coordinator) = makeSUT()
        let session = try showStructure(of: coordinator)
        session.changeManager.addNewColumn()

        #expect(actions.canUndo)
        #expect(actions.resolvedUndoTitle == session.undoMenuItemTitle)
        #expect(actions.resolvedUndoTitle != String(localized: "Undo"))

        actions.undoChange()

        #expect(!session.hasChanges)
        #expect(!actions.canUndo)
        #expect(actions.canRedo)
        #expect(actions.resolvedRedoTitle == session.redoMenuItemTitle)

        actions.redoChange()

        #expect(session.hasChanges)
    }

    @Test("A session behind the Data view takes no Undo")
    func sessionBehindTheDataViewKeepsItsHistory() throws {
        let (actions, coordinator) = makeSUT()
        let session = try showStructure(of: coordinator)
        session.changeManager.addNewColumn()
        let index = try #require(coordinator.tabManager.selectedTabIndex)
        coordinator.tabManager.tabs[index].display.resultsViewMode = .data

        actions.undoChange()

        #expect(session.hasChanges)
    }

    // A Create Table tab keeps its view mode at Data, so Undo read the window's history, which holds none of the draft.
    @Test("Undo on a Create Table tab is enabled, named and run by the draft")
    func createTableUndoFollowsTheDraft() throws {
        let (actions, coordinator) = makeSUT()
        let draft = try showCreateTable(in: coordinator)
        draft.changeManager.addNewColumn()

        #expect(actions.canUndo == draft.canUndo)
        #expect(actions.canUndo)
        #expect(actions.resolvedUndoTitle == draft.undoMenuItemTitle)

        actions.undoChange()

        #expect(actions.canRedo)
        #expect(actions.resolvedRedoTitle == draft.redoMenuItemTitle)
    }

    // MARK: - Discard Changes

    @Test("Discard Changes follows the session's staged edits")
    func discardFollowsStagedStructureEdits() throws {
        let (actions, coordinator) = makeSUT()
        let session = try showStructure(of: coordinator)
        #expect(!actions.canDiscardChanges)

        session.changeManager.addNewColumn()
        #expect(actions.canDiscardChanges)

        session.discardChanges()
        #expect(!actions.canDiscardChanges)
    }

    @Test("Discard Changes clears grid edits")
    func discardClearsGridEdits() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")
        #expect(!actions.canDiscardChanges)

        stageCellEdit(on: coordinator)
        #expect(actions.canDiscardChanges)

        actions.discardDataWork()

        #expect(!coordinator.changeManager.hasChanges)
        #expect(!actions.canDiscardChanges)
    }

    @Test("Discard Changes is not offered on a Create Table tab")
    func discardIsNotOfferedForCreateTable() throws {
        let (actions, coordinator) = makeSUT()
        let draft = try showCreateTable(in: coordinator)
        draft.tableName = "invoices"

        #expect(draft.holdsWork)
        #expect(!actions.canDiscardChanges)
    }

    @Test("Discard Changes needs a connection and something to discard")
    func discardValidation() {
        let selector = #selector(MainSplitViewController.discardChanges(_:))
        var context = MenuValidationContext()
        #expect(MainSplitViewController.resolvedEnablement(selector, context: context) == false)

        context.isConnected = true
        #expect(MainSplitViewController.resolvedEnablement(selector, context: context) == false)

        context.canDiscardChanges = true
        #expect(MainSplitViewController.resolvedEnablement(selector, context: context) == true)

        context.isAgentMode = true
        #expect(MainSplitViewController.resolvedEnablement(selector, context: context) == false)
    }
}
