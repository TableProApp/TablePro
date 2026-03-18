//
//  SaveCompletionTests.swift
//  TableProTests
//
//  Tests for the save completion paths in MainContentCoordinator.saveChanges(),
//  verifying that every exit path produces the correct outcome (error message
//  or silent success) and does not leave the coordinator in an inconsistent state.
//

import Foundation
@testable import TablePro
import Testing

@MainActor @Suite("Save Completion")
struct SaveCompletionTests {
    // MARK: - Helpers

    private func makeCoordinator(
        safeModeLevel: SafeModeLevel = .silent,
        type: DatabaseType = .mysql
    ) -> (MainContentCoordinator, QueryTabManager, DataChangeManager) {
        var conn = TestFixtures.makeConnection(type: type)
        conn.safeModeLevel = safeModeLevel
        let state = SessionStateFactory.create(connection: conn, payload: nil)
        return (state.coordinator, state.tabManager, state.changeManager)
    }

    // MARK: - No Changes

    @Test("saveChanges with no changes returns immediately without error")
    func noChanges_returnsWithoutError() {
        let (coordinator, tabManager, _) = makeCoordinator()
        tabManager.addTab(databaseName: "testdb")

        var truncates: Set<String> = []
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        #expect(tabManager.tabs.first?.errorMessage == nil)
    }

    // MARK: - Read-Only Connection

    @Test("saveChanges on read-only connection sets error message")
    func readOnly_setsErrorMessage() {
        let (coordinator, tabManager, changeManager) = makeCoordinator(safeModeLevel: .readOnly)
        tabManager.addTab(databaseName: "testdb")

        changeManager.hasChanges = true

        var truncates: Set<String> = []
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        let errorMessage = tabManager.tabs.first?.errorMessage
        #expect(errorMessage != nil)
        #expect(errorMessage?.contains("read-only") == true)
    }

    @Test("saveChanges on read-only connection does not clear changes")
    func readOnly_doesNotClearChanges() {
        let (coordinator, _, changeManager) = makeCoordinator(safeModeLevel: .readOnly)

        changeManager.hasChanges = true

        var truncates: Set<String> = []
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        #expect(changeManager.hasChanges == true)
    }

    // MARK: - Empty Generated Statements

    @Test("saveChanges with hasChanges true but no generated SQL sets error")
    func hasChangesButNoSQL_setsError() {
        let (coordinator, tabManager, changeManager) = makeCoordinator()
        tabManager.addTab(databaseName: "testdb")

        changeManager.hasChanges = true

        var truncates: Set<String> = []
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        let errorMessage = tabManager.tabs.first?.errorMessage
        #expect(errorMessage != nil)
    }

    // MARK: - Pending Table Operations

    @Test("saveChanges with pending truncates but read-only sets error")
    func pendingTruncatesReadOnly_setsError() {
        let (coordinator, tabManager, _) = makeCoordinator(safeModeLevel: .readOnly)
        tabManager.addTab(databaseName: "testdb")

        var truncates: Set<String> = ["users"]
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        let errorMessage = tabManager.tabs.first?.errorMessage
        #expect(errorMessage != nil)
        #expect(errorMessage?.contains("read-only") == true)
        #expect(truncates.contains("users"))
    }

    @Test("saveChanges with no tab selected and read-only does not crash")
    func noTabSelected_readOnly_doesNotCrash() {
        let (coordinator, _, changeManager) = makeCoordinator(safeModeLevel: .readOnly)
        changeManager.hasChanges = true

        var truncates: Set<String> = []
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        #expect(changeManager.hasChanges == true)
    }

    @Test("saveChanges with no changes and no pending ops does nothing")
    func noChangesNoPendingOps_noop() {
        let (coordinator, tabManager, _) = makeCoordinator()
        tabManager.addTab(databaseName: "testdb")

        var truncates: Set<String> = []
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        #expect(tabManager.tabs.first?.errorMessage == nil)
        #expect(truncates.isEmpty)
        #expect(deletes.isEmpty)
    }

    // MARK: - Safe Mode Confirmation Path

    @Test("saveChanges with alert level and pending truncates clears inout params immediately")
    func alertLevel_pendingTruncates_clearsParams() {
        let (coordinator, tabManager, _) = makeCoordinator(safeModeLevel: .alert)
        tabManager.addTab(databaseName: "testdb")

        var truncates: Set<String> = ["users"]
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        // Confirmation path clears inout params before returning to prevent double-execution
        #expect(truncates.isEmpty)
    }

    @Test("saveChanges with safeMode level and pending deletes clears inout params")
    func safeModeLevel_pendingDeletes_clearsParams() {
        let (coordinator, tabManager, _) = makeCoordinator(safeModeLevel: .safeMode)
        tabManager.addTab(databaseName: "testdb")

        var truncates: Set<String> = []
        var deletes: Set<String> = ["orders"]
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        #expect(deletes.isEmpty)
    }

    @Test("saveChanges with alert level and no changes does nothing")
    func alertLevel_noChanges_noop() {
        let (coordinator, tabManager, _) = makeCoordinator(safeModeLevel: .alert)
        tabManager.addTab(databaseName: "testdb")

        var truncates: Set<String> = []
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        #expect(tabManager.tabs.first?.errorMessage == nil)
        #expect(truncates.isEmpty)
        #expect(deletes.isEmpty)
    }

    @Test("saveChanges with silent level and pending truncates clears via normal path")
    func silentLevel_pendingTruncates_clearsViaNormalPath() {
        let (coordinator, tabManager, _) = makeCoordinator(safeModeLevel: .silent)
        tabManager.addTab(databaseName: "testdb")

        var truncates: Set<String> = ["users"]
        var deletes: Set<String> = []
        var options: [String: TableOperationOptions] = [:]

        coordinator.saveChanges(
            pendingTruncates: &truncates,
            pendingDeletes: &deletes,
            tableOperationOptions: &options
        )

        // Silent level takes the normal (non-confirmation) path which also clears immediately
        #expect(truncates.isEmpty)
    }

    // MARK: - Row Operations and Safe Mode

    @Test("row operations blocked by readOnly level")
    func rowOperations_blockedByReadOnly() {
        let (coordinator, tabManager, _) = makeCoordinator(safeModeLevel: .readOnly)
        tabManager.addTab(databaseName: "testdb")
        if let index = tabManager.selectedTabIndex {
            tabManager.tabs[index].isEditable = true
            tabManager.tabs[index].tableName = "users"
        }

        var selectedRows: Set<Int> = []
        var editingCell: CellPosition?

        coordinator.addNewRow(selectedRowIndices: &selectedRows, editingCell: &editingCell)
        #expect(selectedRows.isEmpty)
        #expect(editingCell == nil)

        selectedRows = [0]
        coordinator.deleteSelectedRows(indices: Set([0]), selectedRowIndices: &selectedRows)
        #expect(selectedRows == [0])

        selectedRows = []
        coordinator.duplicateSelectedRow(index: 0, selectedRowIndices: &selectedRows, editingCell: &editingCell)
        #expect(selectedRows.isEmpty)
        #expect(editingCell == nil)
    }

    @Test("row operations allowed by alert level")
    func rowOperations_allowedByAlertLevel() {
        let (coordinator, tabManager, _) = makeCoordinator(safeModeLevel: .alert)
        tabManager.addTab(databaseName: "testdb")
        if let index = tabManager.selectedTabIndex {
            tabManager.tabs[index].isEditable = true
            tabManager.tabs[index].tableName = "users"
        }

        var selectedRows: Set<Int> = []
        var editingCell: CellPosition?

        // Alert level doesn't block row staging — only gates at execution time
        coordinator.addNewRow(selectedRowIndices: &selectedRows, editingCell: &editingCell)
        #expect(tabManager.tabs.first?.errorMessage == nil)
    }
}
