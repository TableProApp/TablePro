//
//  CommandActionsDispatchTests.swift
//  TableProTests
//
//  Tests that MainContentCommandActions correctly forwards calls
//  to MainContentCoordinator and its sub-handlers.
//

import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class CommandActionsClipboard: ClipboardProvider {
    var text: String?
    var hasGridRowsValue = false

    func readText() -> String? { text }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) { self.text = text; hasGridRowsValue = false }
    func writeCsv(_ csv: String) { text = csv; hasGridRowsValue = false }
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { text = tsv; hasGridRowsValue = true }
    var hasText: Bool { text != nil }
    var hasGridRows: Bool { hasGridRowsValue }
}

@MainActor
private final class CommandActionsLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor @Suite("CommandActions Dispatch")
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
        let rightPanelState = RightPanelState()

        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectionState: coordinator.selectionState,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(
                get: { tableOperationOptions },
                set: { tableOperationOptions = $0 }
            ),
            rightPanelState: rightPanelState
        )

        return (actions, coordinator)
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

        /// Left alone. Appending was removed on purpose in #1257, and `aiInsertReusesSelectedQueryTab`
        /// is true only for a query tab that is empty, so generated SQL takes over a blank tab and
        /// otherwise opens its own. A tab the user has typed into is never rewritten, which is the
        /// property worth holding; this case asserted the concatenation that fix removed.
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

    // MARK: - copySelectedRows (structure mode)

    @Test("copySelectedRows in structure mode calls structureActions.copyRows")
    func copySelectedRows_structureMode_callsStructureActions() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")

        // Enable structure mode on the selected tab
        if let idx = coordinator.tabManager.selectedTabIndex {
            coordinator.tabManager.tabs[idx].display.resultsViewMode = .structure
        }

        // Install a spy handler
        let handler = StructureViewActionHandler()
        var copyRowsCalled = false
        handler.copyRows = { copyRowsCalled = true }
        coordinator.structureActions = handler

        actions.copySelectedRows()

        #expect(copyRowsCalled)
    }

    // MARK: - pasteRows (structure mode)

    @Test("pasteRows in structure mode calls structureActions.pasteRows")
    func pasteRows_structureMode_callsStructureActions() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")

        // Enable structure mode on the selected tab
        if let idx = coordinator.tabManager.selectedTabIndex {
            coordinator.tabManager.tabs[idx].display.resultsViewMode = .structure
        }

        // Install a spy handler
        let handler = StructureViewActionHandler()
        var pasteRowsCalled = false
        handler.pasteRows = { pasteRowsCalled = true }
        coordinator.structureActions = handler

        actions.pasteRows()

        #expect(pasteRowsCalled)
    }

    // MARK: - addNewRow (structure mode)

    @Test("addNewRow in structure mode calls structureActions.addRow")
    func addNewRow_structureMode_callsStructureActions() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")

        if let idx = coordinator.tabManager.selectedTabIndex {
            coordinator.tabManager.tabs[idx].display.resultsViewMode = .structure
        }

        let handler = StructureViewActionHandler()
        var addRowCalled = false
        handler.addRow = { addRowCalled = true }
        coordinator.structureActions = handler

        actions.addNewRow()

        #expect(addRowCalled)
    }

    // MARK: - deleteSelectedRows (structure mode)

    @Test("deleteSelectedRows in structure mode calls structureActions.removeRow")
    func deleteSelectedRows_structureMode_callsStructureActions() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")

        if let idx = coordinator.tabManager.selectedTabIndex {
            coordinator.tabManager.tabs[idx].display.resultsViewMode = .structure
        }

        let handler = StructureViewActionHandler()
        var removeRowCalled = false
        handler.removeRow = { removeRowCalled = true }
        coordinator.structureActions = handler

        actions.deleteSelectedRows()

        #expect(removeRowCalled)
    }

    // MARK: - saveChanges (createTable tab)

    /// A Create Table tab is answered by `createTableActions` and nothing else. The structure arm
    /// sits below it and would otherwise try to apply the staged edits of whatever session the tab
    /// id happens to carry.
    @Test("saveChanges dispatches createTableActions when the selected tab is createTable")
    func saveChanges_createTableTab_callsCreateTableAction() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addCreateTableTab(databaseName: "testdb")
        guard let id = coordinator.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }

        let createHandler = CreateTableActionHandler()
        var createCalled = false
        createHandler.createTable = { createCalled = true }
        coordinator.createTableActions = createHandler

        let session = TestFixtures.makeStructureSession()
        coordinator.structureSessions[id] = session
        session.changeManager.loadSchema(
            tableName: "users", columns: [], indexes: [], foreignKeys: [], primaryKey: []
        )
        session.changeManager.addNewColumn()

        actions.saveChanges()

        #expect(createCalled)
        #expect(session.appliedVersion == 0)
        #expect(session.changeManager.hasChanges)
    }

    @Test("saveChanges without createTableActions is a no-op for a createTable tab")
    func saveChanges_createTableTab_withoutAction_doesNothing() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addCreateTableTab(databaseName: "testdb")
        guard let id = coordinator.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }
        let session = TestFixtures.makeStructureSession()
        coordinator.structureSessions[id] = session

        actions.saveChanges()

        #expect(session.appliedVersion == 0)
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

    private func attachGridWithRangeSelection(
        to coordinator: MainContentCoordinator
    ) -> (DataTabGridDelegate, TableViewCoordinator) {
        let delegate = DataTabGridDelegate()
        let tableViewCoordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: delegate,
            layoutPersister: CommandActionsLayoutPersister()
        )
        tableViewCoordinator.selectionController.update(
            .single(
                GridRect(rows: 0...1, columns: 0...0),
                anchor: GridCoord(row: 0, column: 0),
                active: GridCoord(row: 1, column: 0)
            )
        )
        delegate.dataGridAttach(tableViewCoordinator: tableViewCoordinator)
        coordinator.dataTabDelegate = delegate
        return (delegate, tableViewCoordinator)
    }

    @Test("copySelectedRowsAsJson honors the grid range selection")
    func copySelectedRowsAsJson_usesRangeSelection() {
        let clipboard = CommandActionsClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")
        seedRows(coordinator)
        let attached = attachGridWithRangeSelection(to: coordinator)

        actions.copySelectedRowsAsJson()

        #expect(clipboard.text?.contains("Alice") == true)
        #expect(clipboard.text?.contains("Bob") == true)
        withExtendedLifetime(attached) {}
    }

    @Test("copySelectedRowsAsJson falls back to the row selection without a grid")
    func copySelectedRowsAsJson_fallsBackWithoutGrid() {
        let clipboard = CommandActionsClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")
        seedRows(coordinator)
        coordinator.selectionState.indices = [0]

        actions.copySelectedRowsAsJson()

        #expect(clipboard.text?.contains("Alice") == true)
        #expect(clipboard.text?.contains("Bob") != true)
    }

    @Test("hasRowSelection reflects a grid range selection")
    func hasRowSelection_reflectsRangeSelection() {
        let (actions, coordinator) = makeSUT()
        coordinator.tabManager.addTab(databaseName: "testdb")
        seedRows(coordinator)
        let attached = attachGridWithRangeSelection(to: coordinator)

        #expect(actions.hasRowSelection)
        withExtendedLifetime(attached) {}
    }
}
