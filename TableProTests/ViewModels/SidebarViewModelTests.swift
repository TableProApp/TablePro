//
//  SidebarViewModelTests.swift
//  TableProTests
//
//  Tests for SidebarViewModel — the extracted business logic from SidebarView.
//

import Foundation
import SwiftUI
import Testing
@testable import TablePro

// MARK: - Mock TableFetcher

private struct MockTableFetcher: TableFetcher {
    var tables: [TableInfo]
    var error: Error?

    func fetchTables(force: Bool) async throws -> [TableInfo] {
        if let error { throw error }
        return tables
    }
}

private enum TestError: Error {
    case fetchFailed
}

// MARK: - Helper

/// Creates a SidebarViewModel with controllable state bindings for testing
@MainActor
private func makeSUT(
    tables: [TableInfo] = [],
    selectedTables: Set<TableInfo> = [],
    pendingTruncates: Set<String> = [],
    pendingDeletes: Set<String> = [],
    tableOperationOptions: [String: TableOperationOptions] = [:],
    databaseType: DatabaseType = .mysql,
    fetcherTables: [TableInfo] = [],
    fetcherError: Error? = nil
) -> (
    vm: SidebarViewModel,
    tables: Binding<[TableInfo]>,
    selectedTables: Binding<Set<TableInfo>>,
    pendingTruncates: Binding<Set<String>>,
    pendingDeletes: Binding<Set<String>>,
    tableOperationOptions: Binding<[String: TableOperationOptions]>
) {
    var tablesState = tables
    var selectedState = selectedTables
    var truncatesState = pendingTruncates
    var deletesState = pendingDeletes
    var optionsState = tableOperationOptions

    let tablesBinding = Binding(get: { tablesState }, set: { tablesState = $0 })
    let selectedBinding = Binding(get: { selectedState }, set: { selectedState = $0 })
    let truncatesBinding = Binding(get: { truncatesState }, set: { truncatesState = $0 })
    let deletesBinding = Binding(get: { deletesState }, set: { deletesState = $0 })
    let optionsBinding = Binding(get: { optionsState }, set: { optionsState = $0 })

    let fetcher = MockTableFetcher(tables: fetcherTables, error: fetcherError)
    let vm = SidebarViewModel(
        tables: tablesBinding,
        selectedTables: selectedBinding,
        pendingTruncates: truncatesBinding,
        pendingDeletes: deletesBinding,
        tableOperationOptions: optionsBinding,
        databaseType: databaseType,
        connectionId: UUID(),
        tableFetcher: fetcher
    )

    return (vm, tablesBinding, selectedBinding, truncatesBinding, deletesBinding, optionsBinding)
}

// MARK: - Tests

@Suite("SidebarViewModel")
struct SidebarViewModelTests {

    // MARK: - Table Loading

    @Test("loadTables sets isLoading and populates tables")
    @MainActor
    func loadTablesPopulatesTables() async throws {
        let fetchedTables = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        let (vm, tablesBinding, _, _, _, _) = makeSUT(fetcherTables: fetchedTables)

        vm.loadTables()
        // Wait for async task to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(tablesBinding.wrappedValue.count == 2)
        #expect(!vm.isLoading)
        #expect(vm.errorMessage == nil)
    }

    @Test("loadTables handles fetch error gracefully")
    @MainActor
    func loadTablesHandlesError() async throws {
        let (vm, _, _, _, _, _) = makeSUT(fetcherError: TestError.fetchFailed)

        vm.loadTables()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!vm.isLoading)
        #expect(vm.errorMessage != nil)
    }

    @Test("loadTables guards against concurrent loads")
    @MainActor
    func loadTablesGuardsConcurrent() {
        let (vm, _, _, _, _, _) = makeSUT(fetcherTables: [TestFixtures.makeTableInfo(name: "t1")])

        vm.loadTables()
        // Second call while first is loading should be a no-op
        #expect(vm.isLoading)
        vm.loadTables() // Should not crash or double-load
    }

    // MARK: - Stale Cleanup

    @Test("removes stale selections after refresh")
    @MainActor
    func removesStaleSelections() async throws {
        let oldTable = TestFixtures.makeTableInfo(name: "old_table")
        let newTable = TestFixtures.makeTableInfo(name: "new_table")

        let (vm, _, selectedBinding, _, _, _) = makeSUT(
            tables: [oldTable],
            selectedTables: [oldTable],
            fetcherTables: [newTable]
        )

        vm.loadTables()
        try await Task.sleep(nanoseconds: 100_000_000)

        // old_table was removed from fetched results, so selection should be cleared
        let selectedNames = selectedBinding.wrappedValue.map(\.name)
        #expect(!selectedNames.contains("old_table"))
    }

    @Test("removes stale pending deletes")
    @MainActor
    func removesStaleDeletes() async throws {
        let (vm, _, _, _, deletesBinding, optionsBinding) = makeSUT(
            pendingDeletes: ["gone_table"],
            tableOperationOptions: ["gone_table": TableOperationOptions()],
            fetcherTables: [TestFixtures.makeTableInfo(name: "users")]
        )

        vm.loadTables()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!deletesBinding.wrappedValue.contains("gone_table"))
        #expect(optionsBinding.wrappedValue["gone_table"] == nil)
    }

    @Test("removes stale pending truncates")
    @MainActor
    func removesStaletruncates() async throws {
        let (vm, _, _, truncatesBinding, _, optionsBinding) = makeSUT(
            pendingTruncates: ["gone_table"],
            tableOperationOptions: ["gone_table": TableOperationOptions()],
            fetcherTables: [TestFixtures.makeTableInfo(name: "users")]
        )

        vm.loadTables()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!truncatesBinding.wrappedValue.contains("gone_table"))
        #expect(optionsBinding.wrappedValue["gone_table"] == nil)
    }

    // MARK: - Selection Restoration

    @Test("preserves selection when table still exists after refresh")
    @MainActor
    func preservesSelectionAfterRefresh() async throws {
        let usersTable = TestFixtures.makeTableInfo(name: "users")
        let fetchedUsers = TestFixtures.makeTableInfo(name: "users")

        let (vm, _, selectedBinding, _, _, _) = makeSUT(
            tables: [usersTable],
            selectedTables: [usersTable],
            fetcherTables: [fetchedUsers]
        )

        vm.loadTables()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Selection should be restored to the "users" table from fetched results
        let selectedNames = selectedBinding.wrappedValue.map(\.name)
        #expect(selectedNames.contains("users"))
    }

    // MARK: - Batch Toggle Truncate

    @Test("batchToggleTruncate shows dialog for new tables")
    @MainActor
    func batchToggleTruncateShowsDialog() {
        let table = TestFixtures.makeTableInfo(name: "users")
        let (vm, _, _, _, _, _) = makeSUT(selectedTables: [table])

        vm.batchToggleTruncate()

        #expect(vm.showOperationDialog)
        #expect(vm.pendingOperationType == .truncate)
        #expect(vm.pendingOperationTables == ["users"])
    }

    @Test("batchToggleTruncate cancels when all already pending")
    @MainActor
    func batchToggleTruncateCancels() {
        let table = TestFixtures.makeTableInfo(name: "users")
        let (vm, _, _, truncatesBinding, _, optionsBinding) = makeSUT(
            selectedTables: [table],
            pendingTruncates: ["users"],
            tableOperationOptions: ["users": TableOperationOptions()]
        )

        vm.batchToggleTruncate()

        #expect(!vm.showOperationDialog)
        #expect(!truncatesBinding.wrappedValue.contains("users"))
        #expect(optionsBinding.wrappedValue["users"] == nil)
    }

    @Test("batchToggleTruncate does nothing when no selection")
    @MainActor
    func batchToggleTruncateNoSelection() {
        let (vm, _, _, _, _, _) = makeSUT()

        vm.batchToggleTruncate()

        #expect(!vm.showOperationDialog)
    }

    // MARK: - Batch Toggle Delete

    @Test("batchToggleDelete shows dialog for new tables")
    @MainActor
    func batchToggleDeleteShowsDialog() {
        let table = TestFixtures.makeTableInfo(name: "orders")
        let (vm, _, _, _, _, _) = makeSUT(selectedTables: [table])

        vm.batchToggleDelete()

        #expect(vm.showOperationDialog)
        #expect(vm.pendingOperationType == .drop)
        #expect(vm.pendingOperationTables == ["orders"])
    }

    @Test("batchToggleDelete cancels when all already pending")
    @MainActor
    func batchToggleDeleteCancels() {
        let table = TestFixtures.makeTableInfo(name: "orders")
        let (vm, _, _, _, deletesBinding, optionsBinding) = makeSUT(
            selectedTables: [table],
            pendingDeletes: ["orders"],
            tableOperationOptions: ["orders": TableOperationOptions()]
        )

        vm.batchToggleDelete()

        #expect(!vm.showOperationDialog)
        #expect(!deletesBinding.wrappedValue.contains("orders"))
        #expect(optionsBinding.wrappedValue["orders"] == nil)
    }

    // MARK: - Confirm Operation

    @Test("confirmOperation truncate moves tables from pendingDeletes to pendingTruncates")
    @MainActor
    func confirmTruncateMovesFromDeletes() {
        let table = TestFixtures.makeTableInfo(name: "users")
        let (vm, _, _, truncatesBinding, deletesBinding, optionsBinding) = makeSUT(
            selectedTables: [table],
            pendingDeletes: ["users"]
        )

        vm.pendingOperationType = .truncate
        vm.pendingOperationTables = ["users"]

        let options = TableOperationOptions(ignoreForeignKeys: true)
        vm.confirmOperation(options: options)

        #expect(truncatesBinding.wrappedValue.contains("users"))
        #expect(!deletesBinding.wrappedValue.contains("users"))
        #expect(optionsBinding.wrappedValue["users"]?.ignoreForeignKeys == true)
    }

    @Test("confirmOperation drop moves tables from pendingTruncates to pendingDeletes")
    @MainActor
    func confirmDropMovesFromTruncates() {
        let table = TestFixtures.makeTableInfo(name: "users")
        let (vm, _, _, truncatesBinding, deletesBinding, optionsBinding) = makeSUT(
            selectedTables: [table],
            pendingTruncates: ["users"]
        )

        vm.pendingOperationType = .drop
        vm.pendingOperationTables = ["users"]

        let options = TableOperationOptions(cascade: true)
        vm.confirmOperation(options: options)

        #expect(!truncatesBinding.wrappedValue.contains("users"))
        #expect(deletesBinding.wrappedValue.contains("users"))
        #expect(optionsBinding.wrappedValue["users"]?.cascade == true)
    }

    @Test("confirmOperation stores options per table")
    @MainActor
    func confirmOperationStoresOptions() {
        let t1 = TestFixtures.makeTableInfo(name: "t1")
        let t2 = TestFixtures.makeTableInfo(name: "t2")
        let (vm, _, _, _, _, optionsBinding) = makeSUT(selectedTables: [t1, t2])

        vm.pendingOperationType = .truncate
        vm.pendingOperationTables = ["t1", "t2"]

        let options = TableOperationOptions(ignoreForeignKeys: true, cascade: true)
        vm.confirmOperation(options: options)

        #expect(optionsBinding.wrappedValue["t1"] == options)
        #expect(optionsBinding.wrappedValue["t2"] == options)
    }

    @Test("confirmOperation resets dialog state after confirm")
    @MainActor
    func confirmOperationResetsDialogState() {
        let table = TestFixtures.makeTableInfo(name: "users")
        let (vm, _, _, _, _, _) = makeSUT(selectedTables: [table])

        vm.pendingOperationType = .truncate
        vm.pendingOperationTables = ["users"]
        vm.showOperationDialog = true

        vm.confirmOperation(options: TableOperationOptions())

        #expect(vm.pendingOperationType == nil)
        #expect(vm.pendingOperationTables.isEmpty)
    }

    // MARK: - Copy Table Names

    @Test("copySelectedTableNames copies sorted comma-separated names")
    @MainActor
    func copyTableNames() {
        let t1 = TestFixtures.makeTableInfo(name: "zebra")
        let t2 = TestFixtures.makeTableInfo(name: "alpha")
        let (vm, _, _, _, _, _) = makeSUT(selectedTables: [t1, t2])

        NSPasteboard.general.clearContents()
        vm.copySelectedTableNames()

        // Verify clipboard contains sorted names
        let clipboard = NSPasteboard.general.string(forType: .string)
        #expect(clipboard == "alpha,zebra")
    }

    @Test("copySelectedTableNames does nothing when no selection")
    @MainActor
    func copyTableNamesNoSelection() {
        let (vm, _, _, _, _, _) = makeSUT()

        // Save current clipboard content
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()

        vm.copySelectedTableNames()

        // Clipboard should still be empty (nothing written)
        let clipboard = NSPasteboard.general.string(forType: .string)
        #expect(clipboard == nil)

        // Restore clipboard
        if let prev = previousClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prev, forType: .string)
        }
    }
}
