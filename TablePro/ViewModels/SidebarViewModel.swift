//
//  SidebarViewModel.swift
//  TablePro
//
//  ViewModel for SidebarView.
//  Handles table loading, search filtering, and batch operations.
//

import Observation
import SwiftUI

// MARK: - TableFetcher Protocol

/// Abstraction over table fetching for testability
protocol TableFetcher: Sendable {
    func fetchTables(force: Bool) async throws -> [TableInfo]
}

/// Production implementation that uses DatabaseManager, with optional schema provider cache
struct LiveTableFetcher: TableFetcher {
    let connectionId: UUID
    let schemaProvider: SQLSchemaProvider?

    init(connectionId: UUID, schemaProvider: SQLSchemaProvider? = nil) {
        self.connectionId = connectionId
        self.schemaProvider = schemaProvider
    }

    func fetchTables(force: Bool) async throws -> [TableInfo] {
        if let provider = schemaProvider {
            if force {
                if let fresh = try await provider.fetchFreshTables() { return fresh }
            } else {
                let cached = await provider.getTables()
                if !cached.isEmpty { return cached }
            }
        }
        guard let driver = await DatabaseManager.shared.driver(for: connectionId) else {
            return []
        }
        let fetched = try await driver.fetchTables()
        if let provider = schemaProvider {
            await provider.updateTables(fetched)
        }
        return fetched
    }
}

// MARK: - SidebarViewModel

@MainActor @Observable
final class SidebarViewModel {
    // MARK: - Published State

    var isLoading = false
    var errorMessage: String?
    var debouncedSearchText = ""
    var isTablesExpanded: Bool = {
        let key = "sidebar.isTablesExpanded"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return true
    }() {
        didSet { UserDefaults.standard.set(isTablesExpanded, forKey: "sidebar.isTablesExpanded") }
    }
    var showOperationDialog = false
    var pendingOperationType: TableOperationType?
    var pendingOperationTables: [String] = []

    // MARK: - Internal State

    /// Prevents selection callback during programmatic updates (e.g., refresh)
    var isRestoringSelection = false

    // MARK: - Binding Storage

    private var tablesBinding: Binding<[TableInfo]>
    private var selectedTablesBinding: Binding<Set<TableInfo>>
    private var pendingTruncatesBinding: Binding<Set<String>>
    private var pendingDeletesBinding: Binding<Set<String>>
    private var tableOperationOptionsBinding: Binding<[String: TableOperationOptions]>
    let databaseType: DatabaseType

    // MARK: - Dependencies

    private let connectionId: UUID
    private let tableFetcher: TableFetcher
    private var loadTask: Task<Void, Never>?

    // MARK: - Convenience Accessors

    var tables: [TableInfo] {
        get { tablesBinding.wrappedValue }
        set { tablesBinding.wrappedValue = newValue }
    }

    var selectedTables: Set<TableInfo> {
        get { selectedTablesBinding.wrappedValue }
        set { selectedTablesBinding.wrappedValue = newValue }
    }

    var pendingTruncates: Set<String> {
        get { pendingTruncatesBinding.wrappedValue }
        set { pendingTruncatesBinding.wrappedValue = newValue }
    }

    var pendingDeletes: Set<String> {
        get { pendingDeletesBinding.wrappedValue }
        set { pendingDeletesBinding.wrappedValue = newValue }
    }

    var tableOperationOptions: [String: TableOperationOptions] {
        get { tableOperationOptionsBinding.wrappedValue }
        set { tableOperationOptionsBinding.wrappedValue = newValue }
    }

    // MARK: - Initialization

    init(
        tables: Binding<[TableInfo]>,
        selectedTables: Binding<Set<TableInfo>>,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        databaseType: DatabaseType,
        connectionId: UUID,
        schemaProvider: SQLSchemaProvider? = nil,
        tableFetcher: TableFetcher? = nil
    ) {
        self.tablesBinding = tables
        self.selectedTablesBinding = selectedTables
        self.pendingTruncatesBinding = pendingTruncates
        self.pendingDeletesBinding = pendingDeletes
        self.tableOperationOptionsBinding = tableOperationOptions
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.tableFetcher = tableFetcher ?? LiveTableFetcher(connectionId: connectionId, schemaProvider: schemaProvider)
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard tables.isEmpty else { return }
        Task { @MainActor in
            if DatabaseManager.shared.driver(for: connectionId) != nil {
                loadTables()
            }
        }
    }

    // MARK: - Table Loading

    func loadTables(force: Bool = false) {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            await loadTablesAsync(force: force)
        }
    }

    func forceLoadTables() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        loadTables(force: true)
    }

    private func loadTablesAsync(force: Bool = false) async {
        let previousSelectedName: String? = tables.isEmpty ? nil : selectedTables.first?.name

        do {
            let fetchedTables = try await tableFetcher.fetchTables(force: force)
            tables = fetchedTables

            // Clean up stale entries for tables that no longer exist
            let fetchedNames = Set(fetchedTables.map(\.name))

            let staleSelections = selectedTables.filter { !fetchedNames.contains($0.name) }
            if !staleSelections.isEmpty {
                isRestoringSelection = true
                selectedTables.subtract(staleSelections)
                isRestoringSelection = false
            }

            let stalePendingDeletes = pendingDeletes.subtracting(fetchedNames)
            let stalePendingTruncates = pendingTruncates.subtracting(fetchedNames)
            if !stalePendingDeletes.isEmpty {
                pendingDeletes.subtract(stalePendingDeletes)
                for name in stalePendingDeletes {
                    tableOperationOptions.removeValue(forKey: name)
                }
            }
            if !stalePendingTruncates.isEmpty {
                pendingTruncates.subtract(stalePendingTruncates)
                for name in stalePendingTruncates {
                    tableOperationOptions.removeValue(forKey: name)
                }
            }

            // Only restore selection if it was cleared (prevent reopening tabs)
            if let name = previousSelectedName {
                let currentNames = Set(selectedTables.map { $0.name })
                if !currentNames.contains(name) {
                    // Selection was cleared, restore it without triggering callback
                    isRestoringSelection = true
                    if let restored = fetchedTables.first(where: { $0.name == name }) {
                        selectedTables = [restored]
                    }
                    isRestoringSelection = false
                }
            }
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    // MARK: - Batch Operations

    func batchToggleTruncate() {
        let tablesToToggle = selectedTables.isEmpty ? [] : Array(selectedTables.map { $0.name })
        guard !tablesToToggle.isEmpty else { return }

        // Check if all tables are already pending truncate - if so, remove them
        // Cancellation doesn't require confirmation since it's a safe operation that
        // simply removes the pending state. The stored options are intentionally discarded.
        let allAlreadyPending = tablesToToggle.allSatisfy { pendingTruncates.contains($0) }
        if allAlreadyPending {
            var updated = pendingTruncates
            for name in tablesToToggle {
                updated.remove(name)
                tableOperationOptions.removeValue(forKey: name)
            }
            pendingTruncates = updated
        } else {
            // Show dialog to confirm operation
            pendingOperationType = .truncate
            pendingOperationTables = tablesToToggle
            showOperationDialog = true
        }
    }

    func batchToggleDelete() {
        let tablesToToggle = selectedTables.isEmpty ? [] : Array(selectedTables.map { $0.name })
        guard !tablesToToggle.isEmpty else { return }

        // Check if all tables are already pending delete - if so, remove them
        // Cancellation doesn't require confirmation since it's a safe operation that
        // simply removes the pending state. The stored options are intentionally discarded.
        let allAlreadyPending = tablesToToggle.allSatisfy { pendingDeletes.contains($0) }
        if allAlreadyPending {
            var updated = pendingDeletes
            for name in tablesToToggle {
                updated.remove(name)
                tableOperationOptions.removeValue(forKey: name)
            }
            pendingDeletes = updated
        } else {
            // Show dialog to confirm operation
            pendingOperationType = .drop
            pendingOperationTables = tablesToToggle
            showOperationDialog = true
        }
    }

    func confirmOperation(options: TableOperationOptions) {
        guard let operationType = pendingOperationType else { return }

        var updatedTruncates = pendingTruncates
        var updatedDeletes = pendingDeletes
        var updatedOptions = tableOperationOptions

        for tableName in pendingOperationTables {
            // Remove from opposite set if present
            if operationType == .truncate {
                updatedDeletes.remove(tableName)
                updatedTruncates.insert(tableName)
            } else {
                updatedTruncates.remove(tableName)
                updatedDeletes.insert(tableName)
            }

            // Store options for this table
            updatedOptions[tableName] = options
        }

        pendingTruncates = updatedTruncates
        pendingDeletes = updatedDeletes
        tableOperationOptions = updatedOptions

        // Reset dialog state
        pendingOperationType = nil
        pendingOperationTables = []
    }

    // MARK: - Clipboard

    func copySelectedTableNames() {
        guard !selectedTables.isEmpty else { return }
        let names = selectedTables.map { $0.name }.sorted()
        ClipboardService.shared.writeText(names.joined(separator: ","))
    }
}
