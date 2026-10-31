// Tests that MainContentCommandActions correctly forwards calls
// to MainContentCoordinator and its sub-handlers.

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct CommandActionsDispatchTests {
        // MARK: - Helpers

        private func makeSUT() -> (MainContentCommandActions, MainContentCoordinator) {
            let connection = TestFixtures.makeConnection()
            let state = SessionStateFactory.create(connection: connection, payload: nil)
            let coordinator = state.coordinator

            var selectedTables: Set<DatabaseTreeTableRef> = []
            var pendingTruncates: Set<DatabaseTreeTableRef> = []
            var pendingDeletes: Set<DatabaseTreeTableRef> = []
            var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
            let trailingPaneState = TrailingPaneState()

            let actions = MainContentCommandActions(
                coordinator: coordinator,
                connection: connection,
                selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
                pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
                pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
                tableOperationOptions: Binding(
                    get: { tableOperationOptions },
                    set: { tableOperationOptions = $0 }
                ),
                trailingPaneState: trailingPaneState
            )

            return (actions, coordinator)
        }

        // MARK: - Query text

        // The menu tested the text for emptiness while the editor bar trimmed it, so Run stayed lit over whitespace.
        @Test("An editor holding only whitespace or invisible characters has no query text for the menu")
        func blankEditorHasNoQueryText() {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(initialQuery: "  \n\t\u{200B}\u{FEFF}", databaseName: "testdb")

            #expect(!actions.hasQueryText)
            #expect(!actions.canSaveAsFavorite)
            #expect(actions.canClearQuery)
        }

        @Test("An editor with a statement has query text for the menu")
        func editorWithStatementHasQueryText() {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(initialQuery: "  SELECT 1 ", databaseName: "testdb")

            #expect(actions.hasQueryText)
            #expect(actions.canSaveAsFavorite)
        }

        // MARK: - loadQueryIntoEditor

        @Test("loadQueryIntoEditor forwards query to coordinator and updates tab")
        func loadQueryIntoEditor_forwardsToCoordinator() {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")

            actions.loadQueryIntoEditor("SELECT 1")

            let tab = coordinator.tabManager.selectedTab
            #expect(tab?.content.query == "SELECT 1")
        }

        // MARK: - insertQueryFromAI

        @Test("insertQueryFromAI forwards query to coordinator and updates tab")
        func insertQueryFromAI_forwardsToCoordinator() {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")

            actions.insertQueryFromAI("SELECT 2")

            let tab = coordinator.tabManager.selectedTab
            #expect(tab?.content.query == "SELECT 2")
        }

        @Test("insertQueryFromAI leaves a tab the user has typed into alone")
        func insertQueryFromAI_appendsToExisting() {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")

            // Set an initial query on the tab
            if let idx = coordinator.tabManager.selectedTabIndex {
                coordinator.tabManager.tabs[idx].content.query = "SELECT 1"
            }

            actions.insertQueryFromAI("SELECT 2")

            // Appending went in #1257: generated SQL takes over only an empty query tab and otherwise opens its own.
            #expect(coordinator.tabManager.selectedTab?.content.query == "SELECT 1")
        }

        @Test("insertQueryFromAI reuses the selected query tab when it is empty")
        @MainActor
        func insertQueryFromAI_reusesAnEmptyTab() {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")

            actions.insertQueryFromAI("SELECT 2")

            #expect(coordinator.tabManager.selectedTab?.content.query == "SELECT 2")
        }

        // MARK: - Structure mode

        private func showStructure(
            of coordinator: MainContentCoordinator
        ) throws -> StructureEditingSession {
            coordinator.tabManager.addTab(databaseName: "testdb")
            let index = try #require(coordinator.tabManager.selectedTabIndex)
            coordinator.tabManager.tabs[index].display.resultsViewMode = .structure
            let session = TestFixtures.makeStructureSession()
            session.changeManager.loadSchema(
                tableName: "users", columns: [], indexes: [], foreignKeys: [], primaryKey: []
            )
            session.markBaselineAdopted()
            coordinator.structureSessions[coordinator.tabManager.tabs[index].id] = session
            return session
        }

        @Test("Add Row in Structure stages a column on the tab's session")
        func addNewRow_structureMode_stagesOnTheSession() throws {
            let (actions, coordinator) = makeSUT()
            let session = try showStructure(of: coordinator)
            #expect(actions.selectionOwner == .schemaGrid)
            #expect(actions.isCurrentTabEditable)
            #expect(actions.isCurrentTabSchemaResolved)

            actions.addNewRow()

            #expect(session.changeManager.workingColumns.count == 1)
            #expect(session.hasChanges)
        }

        // Cmd+Shift+D reached only the data grid, so it did nothing in Structure.
        @Test("Duplicate Row in Structure duplicates the selected column")
        func duplicateRow_structureMode_duplicatesTheSelection() throws {
            let (actions, coordinator) = makeSUT()
            let session = try showStructure(of: coordinator)
            actions.addNewRow()
            try #require(session.editor.focusedSection == .columns)

            actions.duplicateRow()

            #expect(session.changeManager.workingColumns.count == 2)
        }

        @Test("Delete in Structure removes the selected column")
        func deleteSelectedRows_structureMode_removesTheSelection() throws {
            let (actions, coordinator) = makeSUT()
            let session = try showStructure(of: coordinator)
            actions.addNewRow()
            try #require(actions.hasRowSelection)

            actions.deleteSelectedRows()

            #expect(session.changeManager.workingColumns.isEmpty)
        }

        @Test("A Structure view with no session takes no row commands")
        func structureModeWithoutASession_ownsNoSelection() throws {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")
            let index = try #require(coordinator.tabManager.selectedTabIndex)
            coordinator.tabManager.tabs[index].display.resultsViewMode = .structure

            #expect(actions.selectionOwner == .none)
            #expect(!actions.isCurrentTabEditable)
        }

        // MARK: - saveChanges (createTable tab)

        // The structure arm would otherwise apply the staged edits of whatever session the tab id carries.
        @Test("saveChanges on a createTable tab never applies a structure session's edits")
        func saveChanges_createTableTab_leavesStructureSessionAlone() throws {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addCreateTableTab(databaseName: "testdb")
            let id = try #require(coordinator.tabManager.selectedTabId)
            let session = TestFixtures.makeStructureSession()
            coordinator.structureSessions[id] = session
            session.changeManager.loadSchema(
                tableName: "users", columns: [], indexes: [], foreignKeys: [], primaryKey: []
            )
            session.changeManager.addNewColumn()

            actions.saveChanges()

            #expect(session.appliedVersion == 0)
            #expect(session.changeManager.hasChanges)
        }

        // Leaving Structure for Data used to dim Save while the session still held its ALTERs.
        @Test("From the Data view, Save reaches staged structure edits only when no grid edit is ahead of them")
        func stagedStructureSession_followsTheDataView() throws {
            let (actions, coordinator) = makeSUT()
            let session = try showStructure(of: coordinator)
            session.changeManager.addNewColumn()
            let index = try #require(coordinator.tabManager.selectedTabIndex)
            coordinator.tabManager.tabs[index].display.resultsViewMode = .data

            #expect(actions.stagedStructureSession === session)

            coordinator.changeManager.configureForTable(
                tableName: "users",
                columns: ["id"],
                primaryKeyColumns: ["id"],
                databaseType: .mysql,
                generatedColumns: []
            )
            coordinator.changeManager.recordRowDeletion(rowID: .existing(0), originalRow: [.text("1")])

            #expect(actions.stagedStructureSession == nil)
        }

        // MARK: - Row selection resolution

        private func seedRows(_ coordinator: MainContentCoordinator) {
            guard let tabId = coordinator.tabManager.selectedTabId else { return }
            let tableRows = TableRows.from(
                queryRows: [
                    [.text("1"), .text("Alice")],
                    [.text("2"), .text("Bob")]
                ],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)]
            )
            coordinator.setActiveTableRows(tableRows, for: tabId)
        }

        private func selectRange(in coordinator: MainContentCoordinator) throws -> DataGridModel {
            let tabId = try #require(coordinator.tabManager.selectedTabId)
            let model = coordinator.gridModel(forTab: tabId)
            model.setSelection(
                .single(
                    GridRect(rows: 0...1, columns: 0...0),
                    anchor: GridCoord(row: 0, displayColumn: 0),
                    active: GridCoord(row: 1, displayColumn: 0)
                )
            )
            return model
        }

        @Test("copySelectedRowsAsJson honors the model's range selection")
        func copySelectedRowsAsJson_usesRangeSelection() throws {
            let clipboard = try #require(RecordingClipboard.current)

            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")
            seedRows(coordinator)
            _ = try selectRange(in: coordinator)

            actions.copySelectedRowsAsJson()

            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
        }

        @Test("copySelectedRowsAsJson reads the model's row selection with no grid mounted")
        func copySelectedRowsAsJson_readsTheModelWithoutAGrid() throws {
            let clipboard = try #require(RecordingClipboard.current)

            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")
            seedRows(coordinator)
            let tabId = try #require(coordinator.tabManager.selectedTabId)
            let model = coordinator.gridModel(forTab: tabId)
            model.selectRows([.existing(0)])
            #expect(!model.isMounted)

            actions.copySelectedRowsAsJson()

            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") != true)
        }

        @Test("Copy Rows in Data mode copies the rows the model selected")
        func copySelectedRows_dataMode_readsTheModel() throws {
            let clipboard = try #require(RecordingClipboard.current)

            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")
            seedRows(coordinator)
            let tabId = try #require(coordinator.tabManager.selectedTabId)
            coordinator.gridModel(forTab: tabId).selectRows([.existing(1)])

            actions.copySelectedRows()

            #expect(clipboard.writes.last == "2\tBob")
        }

        @Test(
            "Copy with the grid not focused writes the selected rows in the row copy format",
            .appSettings { $0.dataGrid.rowCopyFormat = .csvWithHeaders }
        )
        func copyInCopyFormat_unfocusedGrid_usesTheFormat() throws {
            let clipboard = try #require(RecordingClipboard.current)

            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")
            seedRows(coordinator)
            let tabId = try #require(coordinator.tabManager.selectedTabId)
            coordinator.gridModel(forTab: tabId).selectCell(GridCoord(row: 1, displayColumn: 1))

            actions.copySelectedRowsInCopyFormat()

            #expect(clipboard.writes.last == "id,name\n2,Bob\n")
        }

        @Test("hasRowSelection reflects the model's range selection")
        func hasRowSelection_reflectsRangeSelection() throws {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")
            seedRows(coordinator)
            #expect(!actions.hasRowSelection)

            _ = try selectRange(in: coordinator)

            #expect(actions.hasRowSelection)
            #expect(actions.hasDataGridRowSelection)
        }

        // MARK: - Use Selection for Find

        // The menu lit the item over a query result's selection while the window sent it to the editor.
        @Test("Use Selection for Find over a query result's selection goes to its grid unless the editor has a selection")
        func useSelectionForFind_queryResult_reachesTheGrid() throws {
            let (actions, coordinator) = makeSUT()
            coordinator.tabManager.addTab(databaseName: "testdb")
            seedRows(coordinator)
            let tabId = try #require(coordinator.tabManager.selectedTabId)
            #expect(coordinator.tabManager.selectedTab?.tabType == .query)
            let model = coordinator.gridModel(forTab: tabId)
            let mounted = DataTabGridMountStub()
            model.attach(mounted)
            defer { model.detach(mounted) }
            model.selectCell(GridCoord(row: 1, displayColumn: 1))

            var context = MenuValidationContext()
            context.isConnected = true
            context.canUseGridFindCommands = actions.canUseGridFindCommands
            context.hasDataGridRowSelection = actions.hasDataGridRowSelection
            #expect(context.usesGridSelectionForFind)
            #expect(MainSplitViewController.isEnabled(#selector(MainSplitViewController.useSelectionForFind(_:)), context: context))
            context.hasSelectionForFind = true
            #expect(!context.usesGridSelectionForFind)

            actions.useGridSelectionForFind()

            #expect(model.find.term == "Bob")
            #expect(model.find.isVisible)
        }
    }
}
