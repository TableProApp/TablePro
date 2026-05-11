//
//  SidebarViewModel.swift
//  TablePro
//
//  ViewModel for SidebarView.
//  Handles search filtering and batch operations.
//

import Observation
import SwiftUI

// MARK: - SidebarViewModel

@MainActor @Observable
final class SidebarViewModel {
    // MARK: - Published State

    var searchText = "" {
        didSet { invalidateFilteredTablesCache() }
    }
    var isTablesExpanded: Bool = {
        let key = "sidebar.isTablesExpanded"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return true
    }() {
        didSet { UserDefaults.standard.set(isTablesExpanded, forKey: "sidebar.isTablesExpanded") }
    }
    var isRedisKeysExpanded: Bool = {
        let key = "sidebar.isRedisKeysExpanded"
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        return true
    }() {
        didSet { UserDefaults.standard.set(isRedisKeysExpanded, forKey: "sidebar.isRedisKeysExpanded") }
    }
    var redisKeyTreeViewModel: RedisKeyTreeViewModel?
    var showOperationDialog = false
    var pendingOperationType: TableOperationType?
    var pendingOperationTables: [String] = []

    // MARK: - Binding Storage

    private var selectedTablesBinding: Binding<Set<TableInfo>>
    private var pendingTruncatesBinding: Binding<Set<String>>
    private var pendingDeletesBinding: Binding<Set<String>>
    private var tableOperationOptionsBinding: Binding<[String: TableOperationOptions]>
    let databaseType: DatabaseType

    // MARK: - Dependencies

    private let connectionId: UUID

    // MARK: - Convenience Accessors

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
        selectedTables: Binding<Set<TableInfo>>,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        databaseType: DatabaseType,
        connectionId: UUID
    ) {
        self.selectedTablesBinding = selectedTables
        self.pendingTruncatesBinding = pendingTruncates
        self.pendingDeletesBinding = pendingDeletes
        self.tableOperationOptionsBinding = tableOperationOptions
        self.databaseType = databaseType
        self.connectionId = connectionId
    }

    // MARK: - Batch Operations

    func batchToggleTruncate(tableNames: [String]? = nil) {
        let tablesToToggle = tableNames ?? (selectedTables.isEmpty ? [] : Array(selectedTables.map { $0.name }))
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

    func batchToggleDelete(tableNames: [String]? = nil) {
        let tablesToToggle = tableNames ?? (selectedTables.isEmpty ? [] : Array(selectedTables.map { $0.name }))
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

    // MARK: - Filtering

    @ObservationIgnored private var cachedFilteredTables: [TableInfo]?
    @ObservationIgnored private var cachedFilterInputs: (count: Int, hash: Int, query: String)?

    func filteredTables(from tables: [TableInfo]) -> [TableInfo] {
        let query = searchText
        let fingerprint = (count: tables.count, hash: tables.hashValue, query: query)
        if let cache = cachedFilteredTables,
           let inputs = cachedFilterInputs,
           inputs == fingerprint {
            return cache
        }
        let result: [TableInfo]
        if query.isEmpty {
            result = tables
        } else {
            result = tables.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        cachedFilteredTables = result
        cachedFilterInputs = fingerprint
        return result
    }

    private func invalidateFilteredTablesCache() {
        cachedFilteredTables = nil
        cachedFilterInputs = nil
    }
}
