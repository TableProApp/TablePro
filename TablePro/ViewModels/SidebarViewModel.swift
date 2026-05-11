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
    var isTablesExpanded: Bool {
        didSet {
            UserDefaults.standard.set(
                isTablesExpanded,
                forKey: SidebarPersistenceKey.tablesExpanded(connectionId: connectionId)
            )
        }
    }
    var isRedisKeysExpanded: Bool {
        didSet {
            UserDefaults.standard.set(
                isRedisKeysExpanded,
                forKey: SidebarPersistenceKey.redisKeysExpanded(connectionId: connectionId)
            )
        }
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
        self.isTablesExpanded = Self.loadExpansion(
            perConnectionKey: SidebarPersistenceKey.tablesExpanded(connectionId: connectionId),
            legacyKey: SidebarPersistenceKey.legacyTablesExpanded,
            defaultValue: true
        )
        self.isRedisKeysExpanded = Self.loadExpansion(
            perConnectionKey: SidebarPersistenceKey.redisKeysExpanded(connectionId: connectionId),
            legacyKey: SidebarPersistenceKey.legacyRedisKeysExpanded,
            defaultValue: true
        )
    }

    private static func loadExpansion(
        perConnectionKey: String,
        legacyKey: String,
        defaultValue: Bool
    ) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: perConnectionKey) != nil {
            return defaults.bool(forKey: perConnectionKey)
        }
        if defaults.object(forKey: legacyKey) != nil {
            let seeded = defaults.bool(forKey: legacyKey)
            defaults.set(seeded, forKey: perConnectionKey)
            return seeded
        }
        return defaultValue
    }

    // MARK: - Batch Operations

    func batchToggleTruncate(tableNames: [String]? = nil) {
        let tablesToToggle = tableNames ?? (selectedTables.isEmpty ? [] : Array(selectedTables.map { $0.name }))
        guard !tablesToToggle.isEmpty else { return }

        let allAlreadyPending = tablesToToggle.allSatisfy { pendingTruncates.contains($0) }
        if allAlreadyPending {
            var updated = pendingTruncates
            for name in tablesToToggle {
                updated.remove(name)
                tableOperationOptions.removeValue(forKey: name)
            }
            pendingTruncates = updated
        } else {
            pendingOperationType = .truncate
            pendingOperationTables = tablesToToggle
            showOperationDialog = true
        }
    }

    func batchToggleDelete(tableNames: [String]? = nil) {
        let tablesToToggle = tableNames ?? (selectedTables.isEmpty ? [] : Array(selectedTables.map { $0.name }))
        guard !tablesToToggle.isEmpty else { return }

        let allAlreadyPending = tablesToToggle.allSatisfy { pendingDeletes.contains($0) }
        if allAlreadyPending {
            var updated = pendingDeletes
            for name in tablesToToggle {
                updated.remove(name)
                tableOperationOptions.removeValue(forKey: name)
            }
            pendingDeletes = updated
        } else {
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
            if operationType == .truncate {
                updatedDeletes.remove(tableName)
                updatedTruncates.insert(tableName)
            } else {
                updatedTruncates.remove(tableName)
                updatedDeletes.insert(tableName)
            }
            updatedOptions[tableName] = options
        }

        pendingTruncates = updatedTruncates
        pendingDeletes = updatedDeletes
        tableOperationOptions = updatedOptions

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
