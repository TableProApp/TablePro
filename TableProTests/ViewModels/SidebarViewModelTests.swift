//
//  SidebarViewModelTests.swift
//  TableProTests
//
//  Tests for SidebarViewModel — the extracted business logic from SidebarView.
//

import Foundation
import TableProPluginKit
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

// MARK: - Multi-Section Sidebar

@MainActor
private func makeViewModel(
    connectionId: UUID = UUID(),
    databaseType: DatabaseType = .postgresql
) -> SidebarViewModel {
    var selectedState: Set<TableInfo> = []
    var truncates: Set<String> = []
    var deletes: Set<String> = []
    var options: [String: TableOperationOptions] = [:]
    let selectedBinding = Binding(get: { selectedState }, set: { selectedState = $0 })
    let truncatesBinding = Binding(get: { truncates }, set: { truncates = $0 })
    let deletesBinding = Binding(get: { deletes }, set: { deletes = $0 })
    let optionsBinding = Binding(get: { options }, set: { options = $0 })
    return SidebarViewModel(
        selectedTables: selectedBinding,
        pendingTruncates: truncatesBinding,
        pendingDeletes: deletesBinding,
        tableOperationOptions: optionsBinding,
        databaseType: databaseType,
        connectionId: connectionId
    )
}

@Suite("SidebarViewModel multi-section")
struct SidebarViewModelMultiSectionTests {
    @Test("tables of kind splits by TableType raw value")
    @MainActor
    func splitsTablesByKind() {
        let vm = makeViewModel()
        let userTable = TestFixtures.makeTableInfo(name: "users", type: .table)
        let profileView = TestFixtures.makeTableInfo(name: "profiles", type: .view)
        let mixed = [userTable, profileView]

        let tablesOnly = vm.tables(of: .table, from: mixed)
        let viewsOnly = vm.tables(of: .view, from: mixed)
        let matviews = vm.tables(of: .materializedView, from: mixed)

        #expect(tablesOnly.map(\.name) == ["users"])
        #expect(viewsOnly.map(\.name) == ["profiles"])
        #expect(matviews.isEmpty)
    }

    @Test("system tables fall into the table bucket")
    @MainActor
    func systemTablesBucketAsTables() {
        let vm = makeViewModel()
        let sysTable = TestFixtures.makeTableInfo(name: "pg_stat_user_tables", type: .systemTable)

        let tablesOnly = vm.tables(of: .table, from: [sysTable])
        let viewsOnly = vm.tables(of: .view, from: [sysTable])

        #expect(tablesOnly.map(\.name) == ["pg_stat_user_tables"])
        #expect(viewsOnly.isEmpty)
    }

    @Test("routine kinds return empty when querying tables(of:)")
    @MainActor
    func routinesEmptyInTablesOf() {
        let vm = makeViewModel()
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)

        #expect(vm.tables(of: .procedure, from: [table]).isEmpty)
        #expect(vm.tables(of: .function, from: [table]).isEmpty)
    }

    @Test("filteredTables(of:) honors search across kinds")
    @MainActor
    func filteredTablesAcrossKinds() {
        let vm = makeViewModel()
        let users = TestFixtures.makeTableInfo(name: "users", type: .table)
        let userView = TestFixtures.makeTableInfo(name: "user_profile_view", type: .view)
        let orders = TestFixtures.makeTableInfo(name: "orders", type: .table)
        let mixed = [users, userView, orders]
        vm.searchText = "user"

        let tableMatches = vm.filteredTables(of: .table, from: mixed)
        let viewMatches = vm.filteredTables(of: .view, from: mixed)

        #expect(tableMatches.map(\.name) == ["users"])
        #expect(viewMatches.map(\.name) == ["user_profile_view"])
    }

    @Test("filteredRoutines filters by name across kinds")
    @MainActor
    func filteredRoutinesByKind() {
        let vm = makeViewModel()
        let getUser = RoutineInfo(name: "get_user_by_id", schema: "public", kind: .procedure, signature: nil)
        let calcAge = RoutineInfo(name: "calculate_age", schema: "public", kind: .function, signature: nil)
        let mixed = [getUser, calcAge]

        let procs = vm.filteredRoutines(of: .procedure, from: mixed)
        let funcs = vm.filteredRoutines(of: .function, from: mixed)

        #expect(procs.map(\.name) == ["get_user_by_id"])
        #expect(funcs.map(\.name) == ["calculate_age"])
    }

    @Test("filteredRoutines search matches name case insensitively")
    @MainActor
    func filteredRoutinesSearch() {
        let vm = makeViewModel()
        let getUser = RoutineInfo(name: "GET_USER_BY_ID", schema: nil, kind: .procedure, signature: nil)
        let other = RoutineInfo(name: "log_event", schema: nil, kind: .procedure, signature: nil)
        vm.searchText = "user"

        let procs = vm.filteredRoutines(of: .procedure, from: [getUser, other])

        #expect(procs.map(\.name) == ["GET_USER_BY_ID"])
    }

    @Test("effectiveExpanded honors stored state when search empty")
    @MainActor
    func effectiveExpandedRespectsStored() {
        let vm = makeViewModel()
        vm.expanded[.view] = false

        #expect(vm.effectiveExpanded(kind: .view, hasMatches: false) == false)
        #expect(vm.effectiveExpanded(kind: .table, hasMatches: false) == true)
    }

    @Test("effectiveExpanded auto-expands when search has matches")
    @MainActor
    func effectiveExpandedAutoExpandsOnSearch() {
        let vm = makeViewModel()
        vm.expanded[.procedure] = false
        vm.searchText = "user"

        let result = vm.effectiveExpanded(kind: .procedure, hasMatches: true)

        #expect(result == true)
    }

    @Test("effectiveExpanded stays collapsed when search has no matches")
    @MainActor
    func effectiveExpandedStaysCollapsedWithoutMatches() {
        let vm = makeViewModel()
        vm.expanded[.function] = false
        vm.searchText = "nonexistent"

        let result = vm.effectiveExpanded(kind: .function, hasMatches: false)

        #expect(result == false)
    }

    @Test("sectionShouldRender always shows tables")
    @MainActor
    func tablesAlwaysShown() {
        let vm = makeViewModel()
        let empty: PluginCapabilities = []

        #expect(vm.sectionShouldRender(kind: .table, itemCount: 0, capabilities: empty))
        #expect(vm.sectionShouldRender(kind: .table, itemCount: 5, capabilities: empty))
    }

    @Test("sectionShouldRender hides matview when capability missing")
    @MainActor
    func hidesMatviewWithoutCapability() {
        let vm = makeViewModel()
        let result = vm.sectionShouldRender(
            kind: .materializedView,
            itemCount: 10,
            capabilities: []
        )
        #expect(result == false)
    }

    @Test("sectionShouldRender shows matview when capability present and items exist")
    @MainActor
    func showsMatviewWithCapability() {
        let vm = makeViewModel()
        let result = vm.sectionShouldRender(
            kind: .materializedView,
            itemCount: 3,
            capabilities: [.materializedViews]
        )
        #expect(result == true)
    }

    @Test("sectionShouldRender hides matview when no items even with capability")
    @MainActor
    func hidesEmptyMatviewWithCapability() {
        let vm = makeViewModel()
        let result = vm.sectionShouldRender(
            kind: .materializedView,
            itemCount: 0,
            capabilities: [.materializedViews]
        )
        #expect(result == false)
    }

    @Test("default expansion is true for tables only")
    @MainActor
    func defaultExpansionTablesOnly() {
        let vm = makeViewModel()

        #expect(vm.expanded[.table] == true)
        #expect(vm.expanded[.view] == false)
        #expect(vm.expanded[.materializedView] == false)
        #expect(vm.expanded[.foreignTable] == false)
        #expect(vm.expanded[.procedure] == false)
        #expect(vm.expanded[.function] == false)
    }

    @Test("expansion writes persist to per-kind UserDefaults keys")
    @MainActor
    func expansionWritesPersist() {
        let connectionId = UUID()
        let vm = makeViewModel(connectionId: connectionId)
        let key = SidebarPersistenceKey.expanded(connectionId: connectionId, kind: .procedure)
        UserDefaults.standard.removeObject(forKey: key)

        vm.expanded[.procedure] = true

        #expect(UserDefaults.standard.bool(forKey: key) == true)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("expansion seeds .table from legacy per-connection key on first init")
    @MainActor
    func legacyMigrationFromPerConnectionKey() {
        let connectionId = UUID()
        let perKindKey = SidebarPersistenceKey.expanded(connectionId: connectionId, kind: .table)
        let legacyKey = SidebarPersistenceKey.tablesExpanded(connectionId: connectionId)
        UserDefaults.standard.removeObject(forKey: perKindKey)
        UserDefaults.standard.set(false, forKey: legacyKey)

        let vm = makeViewModel(connectionId: connectionId)

        #expect(vm.expanded[.table] == false)
        UserDefaults.standard.removeObject(forKey: perKindKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    @Test("expansion seeds .table from global legacy key when no per-connection key set")
    @MainActor
    func legacyMigrationFromGlobalKey() {
        let connectionId = UUID()
        let perKindKey = SidebarPersistenceKey.expanded(connectionId: connectionId, kind: .table)
        let perConnLegacy = SidebarPersistenceKey.tablesExpanded(connectionId: connectionId)
        UserDefaults.standard.removeObject(forKey: perKindKey)
        UserDefaults.standard.removeObject(forKey: perConnLegacy)
        UserDefaults.standard.set(false, forKey: SidebarPersistenceKey.legacyTablesExpanded)

        let vm = makeViewModel(connectionId: connectionId)

        #expect(vm.expanded[.table] == false)
        UserDefaults.standard.removeObject(forKey: perKindKey)
        UserDefaults.standard.removeObject(forKey: SidebarPersistenceKey.legacyTablesExpanded)
    }
}
