//
//  SidebarViewModel.swift
//  TablePro
//

import Combine
import os
import SwiftUI
import TableProPluginKit

@MainActor
final class SidebarViewModel: ObservableObject {
    private var searchTextObservation: AnyCancellable?
    private static let logger = Logger(subsystem: "com.TablePro", category: "SidebarViewModel")
    private static var registry: [UUID: SidebarViewModel] = [:]
    private static let searchDebounceNanoseconds: UInt64 = 150_000_000

    static func shared(
        connectionId: UUID,
        databaseType: DatabaseType,
        selectedTables: Binding<Set<DatabaseTreeTableRef>>,
        pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
        pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
        tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>
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
        selectedTables: Binding<Set<DatabaseTreeTableRef>>,
        pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
        pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
        tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>
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
            kind.isExpandedByDefault
        }
    }

    // MARK: - Published State

    /// The text in the sidebar's filter field, which the field itself writes into
    /// `SharedSidebarState`. This is a window onto that one value rather than a second copy, so a
    /// write here is a write there.
    var searchText: String {
        get { sharedState.searchText }
        set {
            let oldValue = sharedState.searchText
            sharedState.searchText = newValue
            scheduleFilterQueryUpdate(oldValue: oldValue)
        }
    }

    /// Watches the shared state directly instead of being told by a view's `onChange`. The relay
    /// meant a keystroke reached the filter only while a SwiftUI body was evaluating, and the view
    /// that carried it also re-seeded the debounce on every rebuild.
    private func observeSearchText() {
        searchTextObservation = sharedState.onMainActorChange { [weak self] in
            guard let self else { return }
            self.scheduleFilterQueryUpdate(oldValue: self.filterQuery)
        }
    }

    @Published private(set) var filterQuery = "" {
        didSet {
            invalidateFilterCaches()
            requestedListingRevisions.removeAll()
            loadAllSchemaTablesForSearch()
        }
    }

    /// The listing revision each database was last asked for at, so a search asks again after a
    /// catalog change, a reconnect or a database switch, and never twice for the same revision:
    /// a read that failed would otherwise be retried on every change the sidebar observes.
    private var requestedListingRevisions: [String: Int] = [:]
    private var listingDemandObservations: [AnyCancellable] = []

    private var filterDebounceTask: Task<Void, Never>?

    @Published var expanded: ExpansionState {
        didSet { persistExpansion(oldValue: oldValue) }
    }
    @Published var isRedisKeysExpanded: Bool {
        didSet {
            AppStorageEnvironment.shared.defaults.set(
                isRedisKeysExpanded,
                forKey: SidebarPersistenceKey.redisKeysExpanded(connectionId: connectionId)
            )
        }
    }
    @Published var isRecentsExpanded: Bool {
        didSet {
            AppStorageEnvironment.shared.defaults.set(
                isRecentsExpanded,
                forKey: SidebarPersistenceKey.recentsExpanded(connectionId: connectionId)
            )
        }
    }
    @Published var showOperationDialog = false
    @Published var pendingOperationType: TableOperationType?
    @Published var pendingOperationTables: [DatabaseTreeTableRef] = []

    // MARK: - Binding Storage

    @Published private var selectedTablesBinding: Binding<Set<DatabaseTreeTableRef>>
    @Published private var pendingTruncatesBinding: Binding<Set<DatabaseTreeTableRef>>
    @Published private var pendingDeletesBinding: Binding<Set<DatabaseTreeTableRef>>
    @Published private var tableOperationOptionsBinding: Binding<[DatabaseTreeTableRef: TableOperationOptions]>
    let databaseType: DatabaseType

    // MARK: - Dependencies

    private let connectionId: UUID

    /// The single connection-scoped state holder. Search text and the Redis key
    /// tree live here so this view model and the sidebar views share one source.
    let sharedState: SharedSidebarState

    // MARK: - Convenience Accessors

    var selectedTables: Set<DatabaseTreeTableRef> {
        get { selectedTablesBinding.wrappedValue }
        set { selectedTablesBinding.wrappedValue = newValue }
    }

    var pendingTruncates: Set<DatabaseTreeTableRef> {
        get { pendingTruncatesBinding.wrappedValue }
        set { pendingTruncatesBinding.wrappedValue = newValue }
    }

    var pendingDeletes: Set<DatabaseTreeTableRef> {
        get { pendingDeletesBinding.wrappedValue }
        set { pendingDeletesBinding.wrappedValue = newValue }
    }

    var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] {
        get { tableOperationOptionsBinding.wrappedValue }
        set { tableOperationOptionsBinding.wrappedValue = newValue }
    }

    var isTablesExpanded: Bool {
        get { expanded[.table] }
        set { expanded[.table] = newValue }
    }

    // MARK: - Initialization

    init(
        selectedTables: Binding<Set<DatabaseTreeTableRef>>,
        pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
        pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
        tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>,
        databaseType: DatabaseType,
        connectionId: UUID
    ) {
        self.selectedTablesBinding = selectedTables
        self.pendingTruncatesBinding = pendingTruncates
        self.pendingDeletesBinding = pendingDeletes
        self.tableOperationOptionsBinding = tableOperationOptions
        self.databaseType = databaseType
        self.connectionId = connectionId
        self.sharedState = SharedSidebarState.forConnection(connectionId)
        self.expanded = Self.loadInitialExpansion(connectionId: connectionId)
        self.isRedisKeysExpanded = Self.loadExpansion(
            perConnectionKey: SidebarPersistenceKey.redisKeysExpanded(connectionId: connectionId),
            legacyKey: SidebarPersistenceKey.legacyRedisKeysExpanded,
            defaultValue: true
        )
        self.isRecentsExpanded = Self.loadExpansion(
            perConnectionKey: SidebarPersistenceKey.recentsExpanded(connectionId: connectionId),
            defaultValue: true
        )
        /// Seeded once, at creation, from whatever the field already holds. Doing it from a view's
        /// initializer instead ran on every view-graph pass.
        self.filterQuery = self.sharedState.searchText
        observeSearchText()
        observeListingDemand()
    }

    private func observeListingDemand() {
        listingDemandObservations = [
            DatabaseTreeMetadataService.shared.onMainActorChange { [weak self] in self?.loadAllSchemaTablesForSearch() },
            DatabaseManager.shared.onMainActorChange { [weak self] in self?.loadAllSchemaTablesForSearch() }
        ]
    }

    private static func loadInitialExpansion(connectionId: UUID) -> ExpansionState {
        var values: [SidebarObjectKind: Bool] = [:]
        for kind in SidebarObjectKind.allCases {
            values[kind] = loadKindExpansion(connectionId: connectionId, kind: kind)
        }
        return ExpansionState(values: values)
    }

    private static func loadKindExpansion(connectionId: UUID, kind: SidebarObjectKind) -> Bool {
        let defaults = AppStorageEnvironment.shared.defaults
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
        legacyKey: String? = nil,
        defaultValue: Bool
    ) -> Bool {
        let defaults = AppStorageEnvironment.shared.defaults
        if defaults.object(forKey: perConnectionKey) != nil {
            return defaults.bool(forKey: perConnectionKey)
        }
        if let legacyKey, defaults.object(forKey: legacyKey) != nil {
            let seeded = defaults.bool(forKey: legacyKey)
            defaults.set(seeded, forKey: perConnectionKey)
            return seeded
        }
        return defaultValue
    }

    private func persistExpansion(oldValue: ExpansionState) {
        let defaults = AppStorageEnvironment.shared.defaults
        for kind in SidebarObjectKind.allCases where oldValue[kind] != expanded[kind] {
            defaults.set(
                expanded[kind],
                forKey: SidebarPersistenceKey.expanded(connectionId: connectionId, kind: kind)
            )
        }
    }

    // MARK: - Batch Operations

    /// A queued Truncate or Drop carries the row it was raised from, not that row's name.
    /// The queue lives on the connection and outlives a database switch, so a name-keyed entry
    /// was resolved at Save time against whatever the tab in front pointed at by then.
    func batchToggleTruncate(refs: [DatabaseTreeTableRef]? = nil) {
        let targets = refs ?? Array(selectedTables)
        guard !targets.isEmpty else { return }
        /// Unstaging comes first: a queued operation must always be removable, even once the
        /// engine can no longer express it. Validating ahead of this left a Redis truncate stuck
        /// in the queue after a `SELECT` moved the session to another database.
        guard !targets.allSatisfy({ pendingTruncates.contains($0) }) else {
            unstage(targets, from: &pendingTruncatesBinding.wrappedValue)
            return
        }

        /// The last gate before the queue, refusing the whole batch the way both menus now do
        /// rather than truncating the part of a selection that happens to qualify.
        guard TableOperationEligibility.canTruncate(targets) else {
            Self.logger.warning("Refused to stage a truncate against an object that holds no rows of its own")
            return
        }
        if let eligibility = tableOperationEligibility(for: targets),
           !TableOperationEligibility.canTruncate(targets, context: eligibility) {
            Self.logger.warning("Refused to stage a truncate the engine has no statement for")
            return
        }
        pendingOperationType = .truncate
        pendingOperationTables = targets
        showOperationDialog = true
    }

    func batchToggleDelete(refs: [DatabaseTreeTableRef]? = nil) {
        let targets = refs ?? Array(selectedTables)
        guard !targets.isEmpty else { return }
        guard !targets.allSatisfy({ pendingDeletes.contains($0) }) else {
            unstage(targets, from: &pendingDeletesBinding.wrappedValue)
            return
        }

        /// The same last gate Truncate has. Without it a queued drop the engine cannot express
        /// reached Save and was rejected there, after the dialog had already promised it.
        if let eligibility = tableOperationEligibility(for: targets),
           !TableOperationEligibility.canDrop(targets, context: eligibility) {
            Self.logger.warning("Refused to stage a drop the engine has no statement for")
            return
        }
        pendingOperationType = .drop
        pendingOperationTables = targets
        showOperationDialog = true
    }

    /// Nil when there is no driver to ask, which is not the same as "refused": with no session
    /// nothing can run anyway, and answering `.unavailable` there would make the view model
    /// untestable and silently refuse every staging call.
    private func tableOperationEligibility(
        for targets: [DatabaseTreeTableRef]
    ) -> TableOperationEligibility.Context? {
        guard let adapter = DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter else {
            return nil
        }
        return adapter.tableOperationEligibility(for: targets, isReadOnly: false)
    }

    private func unstage(_ targets: [DatabaseTreeTableRef], from queue: inout Set<DatabaseTreeTableRef>) {
        var options = tableOperationOptions
        for ref in targets {
            queue.remove(ref)
            options.removeValue(forKey: ref)
        }
        tableOperationOptions = options
    }

    func cancelPendingOperation() {
        pendingOperationType = nil
        pendingOperationTables = []
    }

    func confirmOperation(options: TableOperationOptions) {
        guard let operationType = pendingOperationType else { return }

        var updatedTruncates = pendingTruncates
        var updatedDeletes = pendingDeletes
        var updatedOptions = tableOperationOptions

        for ref in pendingOperationTables {
            if operationType == .truncate {
                updatedDeletes.remove(ref)
                updatedTruncates.insert(ref)
            } else {
                updatedTruncates.remove(ref)
                updatedDeletes.insert(ref)
            }
            updatedOptions[ref] = options
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
        let names = selectedTables.map { $0.table.name }.sorted()
        ClipboardService.shared.writeText(names.joined(separator: ","))
    }

    // MARK: - Filtering

    private var cachedKindBuckets: [SidebarObjectKind: [TableInfo]] = [:]
    private var cachedKindFingerprint: (count: Int, generation: Int)?

    private var cachedFilteredByKind: [SidebarObjectKind: [TableInfo]] = [:]
    private var cachedFilteredByKindFingerprint: (count: Int, generation: Int, query: String)?

    private var cachedFilteredRoutines: [SidebarObjectKind: [RoutineInfo]] = [:]
    private var cachedFilteredRoutinesFingerprint: (count: Int, generation: Int, query: String)?
    private var cachedFilteredTriggers: [TriggerInfo] = []
    private var cachedFilteredTriggersFingerprint: (count: Int, generation: Int, query: String)?
    private var cachedFilteredUserTypes: [UserDefinedTypeInfo] = []
    private var cachedFilteredUserTypesFingerprint: (count: Int, generation: Int, query: String)?

    private var schemaGeneration: Int {
        SchemaService.shared.generationToken(for: connectionId)
    }

    func tables(of kind: SidebarObjectKind, from tables: [TableInfo]) -> [TableInfo] {
        guard kind.category == .table else { return [] }
        let fingerprint = (count: tables.count, generation: schemaGeneration)
        if cachedKindFingerprint?.count != fingerprint.count
            || cachedKindFingerprint?.generation != fingerprint.generation {
            rebuildKindBuckets(from: tables)
            cachedKindFingerprint = fingerprint
        }
        return cachedKindBuckets[kind] ?? []
    }

    func filteredTables(of kind: SidebarObjectKind, from tables: [TableInfo]) -> [TableInfo] {
        let query = filterQuery
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

    func filteredRecentTables(_ tables: [TableInfo]) -> [TableInfo] {
        let search = SidebarSearch(filterQuery)
        guard !search.isEmpty else { return tables }
        let database = browsedDatabase
        return tables.filter { search.matchesObject(named: $0.name, database: database, schema: $0.schema) }
    }

    func filteredRoutines(of kind: SidebarObjectKind, from routines: [RoutineInfo]) -> [RoutineInfo] {
        let query = filterQuery
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

    func filteredTriggers(from triggers: [TriggerInfo]) -> [TriggerInfo] {
        let query = filterQuery
        let fingerprint = (count: triggers.count, generation: schemaGeneration, query: query)
        if cachedFilteredTriggersFingerprint?.count != fingerprint.count
            || cachedFilteredTriggersFingerprint?.generation != fingerprint.generation
            || cachedFilteredTriggersFingerprint?.query != fingerprint.query {
            cachedFilteredTriggers = DatabaseTreeFilter.filteredTriggers(triggers, searchText: query, database: browsedDatabase)
            cachedFilteredTriggersFingerprint = fingerprint
        }
        return cachedFilteredTriggers
    }

    func filteredUserTypes(from types: [UserDefinedTypeInfo]) -> [UserDefinedTypeInfo] {
        let query = filterQuery
        let fingerprint = (count: types.count, generation: schemaGeneration, query: query)
        if cachedFilteredUserTypesFingerprint?.count != fingerprint.count
            || cachedFilteredUserTypesFingerprint?.generation != fingerprint.generation
            || cachedFilteredUserTypesFingerprint?.query != fingerprint.query {
            cachedFilteredUserTypes = DatabaseTreeFilter.filteredUserTypes(
                types, searchText: query, database: browsedDatabase
            )
            cachedFilteredUserTypesFingerprint = fingerprint
        }
        return cachedFilteredUserTypes
    }

    func effectiveExpanded(kind: SidebarObjectKind, hasMatches: Bool) -> Bool {
        if !filterQuery.isEmpty && hasMatches { return true }
        return expanded[kind]
    }

    /// A qualified search reaches this list only when it names the schema being browsed: the flat
    /// list holds that schema alone, and the other schemas it names are listed below it.
    private func applyQuery(_ query: String, to tables: [TableInfo]) -> [TableInfo] {
        let search = SidebarSearch(query)
        let database = browsedDatabase
        let admitted = tables.filter { search.matchesObject(named: $0.name, database: database, schema: $0.schema) }
        return SidebarNameFilter.ranked(admitted, query: search.nameQuery, name: { $0.name })
    }

    /// Goes through DatabaseTreeFilter so the flat root and the tree share one dedup owner. The
    /// flat root used to rank without deduplicating, so a driver that returned one routine twice
    /// handed NSOutlineView the same node object at several row indices and selection snapped back
    /// to the first of them.
    private func applyRoutineQuery(_ query: String, to routines: [RoutineInfo]) -> [RoutineInfo] {
        DatabaseTreeFilter.filteredRoutines(routines, searchText: query, database: browsedDatabase)
    }

    /// Every object the flat list holds lives in this database, which a qualified search can name.
    private var browsedDatabase: String? {
        DatabaseManager.shared.browseScope(for: connectionId)?.database
    }

    /// A search has to judge schemas nobody has opened, and the all-schema listing is what answers
    /// for them. It is asked for here rather than by the outline, because a flat list with no local
    /// match shows "No Results" in place of the outline, which then never sees the search at all.
    /// Asked for the browsed database and for every database whose schemas the tree already shows,
    /// never for one the user has not opened.
    private func loadAllSchemaTablesForSearch() {
        guard !filterQuery.isEmpty,
              PluginManager.shared.databaseGroupingStrategy(for: databaseType) == .bySchema else { return }
        let service = DatabaseTreeMetadataService.shared
        let connectionId = connectionId
        var databases = Set(
            service.schemaList.compactMap { key, state in
                key.connectionId == connectionId && state.value != nil ? key.database : nil
            }
        )
        if let browsedDatabase, !browsedDatabase.isEmpty {
            databases.insert(browsedDatabase)
        }
        for database in databases where needsListingRequest(database: database, service: service) {
            requestedListingRevisions[database] = service.allSchemaTablesRevision(
                connectionId: connectionId, database: database
            )
            Task { await service.loadAllSchemaTables(connectionId: connectionId, database: database) }
        }
    }

    /// A listing nobody holds is asked for; one in flight is left alone; one loaded or failed is
    /// asked for again only once its revision has moved past the one this search last asked at.
    private func needsListingRequest(database: String, service: DatabaseTreeMetadataService) -> Bool {
        switch service.allSchemaTablesLoadState(connectionId: connectionId, database: database) {
        case .loading:
            return false
        case .idle:
            return true
        case .loaded, .failed:
            let revision = service.allSchemaTablesRevision(connectionId: connectionId, database: database)
            return requestedListingRevisions[database] != revision
        }
    }

    private func rebuildKindBuckets(from tables: [TableInfo]) {
        var buckets: [SidebarObjectKind: [TableInfo]] = [:]
        for kind in SidebarObjectKind.allCases {
            buckets[kind] = []
        }
        for table in tables {
            let kind = SidebarObjectKind.resolve(tableType: table.type)
            buckets[kind, default: []].append(table)
        }
        cachedKindBuckets = buckets
    }

    private func invalidateFilterCaches() {
        cachedFilteredByKind = [:]
        cachedFilteredByKindFingerprint = nil
        cachedFilteredRoutines = [:]
        cachedFilteredRoutinesFingerprint = nil
    }

    /// Clearing the field, or typing the first character into an empty one, changes what the list
    /// shows wholesale, so it applies at once. Editing an existing query only narrows it, which is
    /// worth waiting a moment for.
    private func scheduleFilterQueryUpdate(oldValue: String) {
        guard filterQuery != searchText else { return }
        if searchText.isEmpty || oldValue.isEmpty {
            filterDebounceTask?.cancel()
            filterDebounceTask = nil
            filterQuery = searchText
            return
        }
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.searchDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.filterQuery = self.searchText
        }
    }

    deinit {
        filterDebounceTask?.cancel()
    }
}
