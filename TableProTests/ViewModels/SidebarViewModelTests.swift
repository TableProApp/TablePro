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

// MARK: - Helper

/// Creates a SidebarViewModel with controllable state bindings for testing
@MainActor
private func makeSUT(
    tables: [TableInfo] = [],
    selectedTables: Set<TableInfo> = [],
    pendingTruncates: Set<String> = [],
    pendingDeletes: Set<String> = [],
    tableOperationOptions: [String: TableOperationOptions] = [:],
    databaseType: DatabaseType = .mysql
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

    let vm = SidebarViewModel(
        tables: tablesBinding,
        selectedTables: selectedBinding,
        pendingTruncates: truncatesBinding,
        pendingDeletes: deletesBinding,
        tableOperationOptions: optionsBinding,
        databaseType: databaseType,
        connectionId: UUID()
    )

    return (vm, tablesBinding, selectedBinding, truncatesBinding, deletesBinding, optionsBinding)
}

// MARK: - Tests

@Suite("SidebarViewModel")
struct SidebarViewModelTests {

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
