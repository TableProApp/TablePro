//
//  SidebarViewModel.swift
//  TablePro
//

import Observation
import SwiftUI
import TableProPluginKit

@MainActor @Observable
final class SidebarViewModel {
    private static var registry: [UUID: SidebarViewModel] = [:]

    static func shared(
        connectionId: UUID,
        databaseType: DatabaseType,
        selectedTables: Binding<Set<TableInfo>>,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>
    ) -> SidebarViewModel {
        if let existing = registry[connectionId] {
            existing.updateBindings(
                selectedTables: selectedTables,
                pendingTruncates: pendingTruncates,
                pendingDeletes: pendingDeletes,
                tableOperationOptions: tableOperationOptions
            )
            return existing
        }
        let viewModel = SidebarViewModel(
            selectedTables: selectedTables,
            pendingTruncates: pendingTruncates,
            pendingDeletes: pendingDeletes,
            tableOperationOptions: tableOperationOptions,
            databaseType: databaseType,
            connectionId: connectionId
        )
        registry[connectionId] = viewModel
        return viewModel
    }

    static func removeConnection(_ connectionId: UUID) {
        registry.removeValue(forKey: connectionId)
    }

    func updateBindings(
        selectedTables: Binding<Set<TableInfo>>,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>
    ) {
        selectedTablesBinding = selectedTables
        pendingTruncatesBinding = pendingTruncates
        pendingDeletesBinding = pendingDeletes
        tableOperationOptionsBinding = tableOperationOptions
    }

    // MARK: - Expansion State

    struct ExpansionState: Sendable {
        var values: [SidebarObjectKind: Bool]

        init(values: [SidebarObjectKind: Bool] = [:]) {
            self.values = values
        }

        subscript(kind: SidebarObjectKind) -> Bool {
            get { values[kind] ?? Self.defaultValue(for: kind) }
            set { values[kind] = newValue }
        }

        static func defaultValue(for kind: SidebarObjectKind) -> Bool {
            kind == .table
        }
    }

    // MARK: - Published State

    var searchText = "" {
        didSet { invalidateFilterCaches() }
    }
    var expanded: ExpansionState {
        didSet { persistExpansion(oldValue: oldValue) }
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

    var isTablesExpanded: Bool {
        get { expanded[.table] }
        set { expanded[.table] = newValue }
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
        self.expanded = Self.loadInitialExpansion(connectionId: connectionId)
        self.isRedisKeysExpanded = Self.loadExpansion(
            perConnectionKey: SidebarPersistenceKey.redisKeysExpanded(connectionId: connectionId),
            legacyKey: SidebarPersistenceKey.legacyRedisKeysExpanded,
            defaultValue: true
        )
    }

    private static func loadInitialExpansion(connectionId: UUID) -> ExpansionState {
        var values: [SidebarObjectKind: Bool] = [:]
        for kind in SidebarObjectKind.allCases {
            values[kind] = loadKindExpansion(connectionId: connectionId, kind: kind)
        }
        return ExpansionState(values: values)
    }

    private static func loadKindExpansion(connectionId: UUID, kind: SidebarObjectKind) -> Bool {
        let defaults = UserDefaults.standard
        let perKindKey = SidebarPersistenceKey.expanded(connectionId: connectionId, kind: kind)
        if defaults.object(forKey: perKindKey) != nil {
            return defaults.bool(forKey: perKindKey)
        }
        if kind == .table {
            let legacyPerConnection = SidebarPersistenceKey.tablesExpanded(connectionId: connectionId)
            if defaults.object(forKey: legacyPerConnection) != nil {
                let seeded = defaults.bool(forKey: legacyPerConnection)
                defaults.set(seeded, forKey: perKindKey)
                return seeded
            }
            if defaults.object(forKey: SidebarPersistenceKey.legacyTablesExpanded) != nil {
                let seeded = defaults.bool(forKey: SidebarPersistenceKey.legacyTablesExpanded)
                defaults.set(seeded, forKey: perKindKey)
                return seeded
            }
        }
        return ExpansionState.defaultValue(for: kind)
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

    private func persistExpansion(oldValue: ExpansionState) {
        let defaults = UserDefaults.standard
        for kind in SidebarObjectKind.allCases where oldValue[kind] != expanded[kind] {
            defaults.set(
                expanded[kind],
                forKey: SidebarPersistenceKey.expanded(connectionId: connectionId, kind: kind)
            )
        }
    }

    // MARK: - Capability Gating

    func capabilities(for connectionId: UUID) -> PluginCapabilities {
        guard let adapter = DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter else {
            return []
        }
        return adapter.schemaPluginDriver.capabilities
    }

    func sectionShouldRender(
        kind: SidebarObjectKind,
        itemCount: Int,
        capabilities: PluginCapabilities
    ) -> Bool {
        if kind == .table { return true }
        if let flag = kind.capabilityFlag, !capabilities.contains(flag) { return false }
        if itemCount > 0 { return true }
        return false
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
    @ObservationIgnored private var cachedFilterInputs: (count: Int, generation: Int, query: String)?

    @ObservationIgnored private var cachedKindBuckets: [SidebarObjectKind: [TableInfo]] = [:]
    @ObservationIgnored private var cachedKindFingerprint: (count: Int, generation: Int)?

    @ObservationIgnored private var cachedFilteredByKind: [SidebarObjectKind: [TableInfo]] = [:]
    @ObservationIgnored private var cachedFilteredByKindFingerprint: (count: Int, generation: Int, query: String)?

    @ObservationIgnored private var cachedFilteredRoutines: [SidebarObjectKind: [RoutineInfo]] = [:]
    @ObservationIgnored private var cachedFilteredRoutinesFingerprint: (count: Int, generation: Int, query: String)?

    private var schemaGeneration: Int {
        SchemaService.shared.generationToken(for: connectionId)
    }

    func filteredTables(from tables: [TableInfo]) -> [TableInfo] {
        let query = searchText
        let fingerprint = (count: tables.count, generation: schemaGeneration, query: query)
        if let cache = cachedFilteredTables,
           let inputs = cachedFilterInputs,
           inputs == fingerprint {
            return cache
        }
        let result: [TableInfo]
        if query.isEmpty {
            result = tables
        } else {
            result = tables.filter { FuzzyMatcher.matches(query: query, candidate: $0.name) }
        }
        cachedFilteredTables = result
        cachedFilterInputs = fingerprint
        return result
    }

    func tables(of kind: SidebarObjectKind, from tables: [TableInfo]) -> [TableInfo] {
        guard !kind.isRoutine else { return [] }
        let fingerprint = (count: tables.count, generation: schemaGeneration)
        if cachedKindFingerprint?.count != fingerprint.count
            || cachedKindFingerprint?.generation != fingerprint.generation {
            rebuildKindBuckets(from: tables)
            cachedKindFingerprint = fingerprint
        }
        return cachedKindBuckets[kind] ?? []
    }

    func filteredTables(of kind: SidebarObjectKind, from tables: [TableInfo]) -> [TableInfo] {
        let query = searchText
        let fingerprint = (count: tables.count, generation: schemaGeneration, query: query)
        if cachedFilteredByKindFingerprint?.count != fingerprint.count
            || cachedFilteredByKindFingerprint?.generation != fingerprint.generation
            || cachedFilteredByKindFingerprint?.query != fingerprint.query {
            let bucket = self.tables(of: .table, from: tables)
            let bucketView = self.tables(of: .view, from: tables)
            let bucketMat = self.tables(of: .materializedView, from: tables)
            let bucketForeign = self.tables(of: .foreignTable, from: tables)
            cachedFilteredByKind[.table] = applyQuery(query, to: bucket)
            cachedFilteredByKind[.view] = applyQuery(query, to: bucketView)
            cachedFilteredByKind[.materializedView] = applyQuery(query, to: bucketMat)
            cachedFilteredByKind[.foreignTable] = applyQuery(query, to: bucketForeign)
            cachedFilteredByKindFingerprint = fingerprint
        }
        return cachedFilteredByKind[kind] ?? []
    }

    func filteredRoutines(of kind: SidebarObjectKind, from routines: [RoutineInfo]) -> [RoutineInfo] {
        let query = searchText
        let fingerprint = (count: routines.count, generation: schemaGeneration, query: query)
        if cachedFilteredRoutinesFingerprint?.count != fingerprint.count
            || cachedFilteredRoutinesFingerprint?.generation != fingerprint.generation
            || cachedFilteredRoutinesFingerprint?.query != fingerprint.query {
            let procs = routines.filter { $0.kind == .procedure }
            let funcs = routines.filter { $0.kind == .function }
            cachedFilteredRoutines[.procedure] = applyRoutineQuery(query, to: procs)
            cachedFilteredRoutines[.function] = applyRoutineQuery(query, to: funcs)
            cachedFilteredRoutinesFingerprint = fingerprint
        }
        return cachedFilteredRoutines[kind] ?? []
    }

    func effectiveExpanded(kind: SidebarObjectKind, hasMatches: Bool) -> Bool {
        if !searchText.isEmpty && hasMatches { return true }
        return expanded[kind]
    }

    private func applyQuery(_ query: String, to tables: [TableInfo]) -> [TableInfo] {
        guard !query.isEmpty else { return tables }
        return tables.filter { FuzzyMatcher.matches(query: query, candidate: $0.name) }
    }

    private func applyRoutineQuery(_ query: String, to routines: [RoutineInfo]) -> [RoutineInfo] {
        guard !query.isEmpty else { return routines }
        return routines.filter { FuzzyMatcher.matches(query: query, candidate: $0.name) }
    }

    private func rebuildKindBuckets(from tables: [TableInfo]) {
        var buckets: [SidebarObjectKind: [TableInfo]] = [:]
        for kind in SidebarObjectKind.allCases {
            buckets[kind] = []
        }
        for table in tables {
            let kind = Self.sidebarObjectKind(for: table.type)
            buckets[kind, default: []].append(table)
        }
        cachedKindBuckets = buckets
    }

    private static func sidebarObjectKind(for tableType: TableInfo.TableType) -> SidebarObjectKind {
        switch tableType.rawValue {
        case "VIEW":               return .view
        case "MATERIALIZED VIEW":  return .materializedView
        case "FOREIGN TABLE":      return .foreignTable
        default:                   return .table
        }
    }

    private func invalidateFilterCaches() {
        cachedFilteredTables = nil
        cachedFilterInputs = nil
        cachedFilteredByKind = [:]
        cachedFilteredByKindFingerprint = nil
        cachedFilteredRoutines = [:]
        cachedFilteredRoutinesFingerprint = nil
    }
}
