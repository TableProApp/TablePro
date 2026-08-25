//
//  SaveCompletionTests.swift
//  TableProTests
//
//  Tests for the save completion paths in MainContentCoordinator.saveChanges(),
//  verifying that every exit path produces the correct outcome (error message
//  or silent success) and does not leave the coordinator in an inconsistent state.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

/// Enough of a driver for `assemblePendingStatements` to produce SQL. Without one the builder has
/// no adapter, emits nothing, and `saveChanges` bails at "Could not generate SQL for changes."
/// before it reaches the inout parameters the cases below are about.
private final class StubSaveDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

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
        /// A session with a driver, so the statement builder has an adapter to route through.
        DatabaseManager.shared.injectSession(
            ConnectionSession(
                connection: conn,
                driver: PluginDriverAdapter(connection: conn, pluginDriver: StubSaveDriver())
            ),
            for: conn.id
        )
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

        #expect(tabManager.tabs.first?.execution.errorMessage == nil)
    }

    // MARK: - Read-Only Connection

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

        let errorMessage = tabManager.tabs.first?.execution.errorMessage
        #expect(errorMessage != nil)
    }

    // MARK: - Pending Table Operations

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

        #expect(tabManager.tabs.first?.execution.errorMessage == nil)
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

        #expect(tabManager.tabs.first?.execution.errorMessage == nil)
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
            tabManager.tabs[index].tableContext.isEditable = true
            tabManager.tabs[index].tableContext.tableName = "users"
        }

        coordinator.addNewRow()
        #expect(coordinator.selectionState.indices.isEmpty)

        coordinator.selectionState.indices = [0]
        coordinator.deleteSelectedRows(indices: Set([0]))
        #expect(coordinator.selectionState.indices == [0])

        coordinator.selectionState.indices = []
        coordinator.duplicateSelectedRow(index: 0)
        #expect(coordinator.selectionState.indices.isEmpty)
    }

    @Test("row operations allowed by alert level")
    func rowOperations_allowedByAlertLevel() {
        let (coordinator, tabManager, _) = makeCoordinator(safeModeLevel: .alert)
        tabManager.addTab(databaseName: "testdb")
        if let index = tabManager.selectedTabIndex {
            tabManager.tabs[index].tableContext.isEditable = true
            tabManager.tabs[index].tableContext.tableName = "users"
        }

        coordinator.addNewRow()
        #expect(tabManager.tabs.first?.execution.errorMessage == nil)
    }
}
