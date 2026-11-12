//
//  DatabaseTreeMetadataService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

/// A list a change overtakes is marked stale and keeps its rows; the next reader on screen reads it
/// again, once per change. Refetching every list ever loaded on each change was work nobody asked for.
@MainActor
final class DatabaseTreeMetadataService: ObservableObject, CatalogChangeTarget {
    static let shared = DatabaseTreeMetadataService()

    struct DatabaseKey: Hashable, Sendable {
        let connectionId: UUID
        let database: String
    }

    struct ObjectsKey: Hashable, Sendable {
        let connectionId: UUID
        let database: String
        let schema: String?
    }

    struct PartitionsKey: Hashable, Sendable {
        let connectionId: UUID
        let database: String
        let schema: String?
        let table: String
    }

    struct TableDetailsKey: Hashable, Sendable {
        let connectionId: UUID
        let database: String
        let schema: String?
        let table: String
        let kind: TableDetailKind
    }

    /// Carries the revision it started under, so a read after a change never joins a fetch that
    /// began before it.
    struct ListFetchKey<Key: Hashable & Sendable>: Hashable, Sendable {
        let key: Key
        let revision: Int
    }

    /// `retrying` names the schemas a second read asks for, and is empty for a whole listing.
    struct AllSchemaTablesLoadKey: Hashable, Sendable {
        let database: DatabaseKey
        let selection: CatalogTableListing.SchemaSelection
        let revision: Int
        let retrying: Set<String>
    }

    private struct ListCommitState<Key: Hashable> {
        var fence = CommitFence<Key>()
        var freshness = CatalogFreshness<Key>()
    }

    private struct TreeList<Key: Hashable & Sendable, Value: Sendable & Equatable> {
        let state: ReferenceWritableKeyPath<DatabaseTreeMetadataService, [Key: MetadataLoadState<Value>]>
        let commit: ReferenceWritableKeyPath<DatabaseTreeMetadataService, ListCommitState<Key>>
        let dedup: OnceTask<ListFetchKey<Key>, Value>
        let label: String
        // What a read uses while nothing is on screen; a reread of rows already shown always goes bulk.
        let workload: MetadataConnectionPool.Workload
    }

    private typealias ListFetch<Value> = @Sendable (MetadataConnectionPool.Workload) async throws -> Value

    @Published private(set) var databaseList: [UUID: MetadataLoadState<[DatabaseMetadata]>] = [:]
    @Published private(set) var schemaList: [DatabaseKey: MetadataLoadState<[String]>] = [:]
    @Published private(set) var tablesState: [ObjectsKey: MetadataLoadState<[TableInfo]>] = [:]
    @Published private(set) var routinesState: [ObjectsKey: MetadataLoadState<[RoutineInfo]>] = [:]
    @Published private(set) var triggersState: [ObjectsKey: MetadataLoadState<[TriggerInfo]>] = [:]
    @Published private(set) var typesState: [ObjectsKey: MetadataLoadState<[UserDefinedTypeInfo]>] = [:]
    @Published private(set) var partitionsState: [PartitionsKey: MetadataLoadState<[PartitionInfo]>] = [:]
    @Published private(set) var tableDetailsState: [TableDetailsKey: MetadataLoadState<TableDetailList>] = [:]
    @Published private(set) var allSchemaTablesState: [DatabaseKey: MetadataLoadState<CatalogTableListing.Result>] = [:]
    @Published private(set) var listsRevisions: [UUID: Int] = [:]

    private let databaseDedup = OnceTask<UUID, [DatabaseMetadata]>()
    private let schemaDedup = OnceTask<ListFetchKey<DatabaseKey>, [String]>()
    private let tablesDedup = OnceTask<ListFetchKey<ObjectsKey>, [TableInfo]>()
    private let routinesDedup = OnceTask<ListFetchKey<ObjectsKey>, [RoutineInfo]>()
    private let triggersDedup = OnceTask<ListFetchKey<ObjectsKey>, [TriggerInfo]>()
    private let typesDedup = OnceTask<ListFetchKey<ObjectsKey>, [UserDefinedTypeInfo]>()
    private let partitionsDedup = OnceTask<ListFetchKey<PartitionsKey>, [PartitionInfo]>()
    private let tableDetailsDedup = OnceTask<ListFetchKey<TableDetailsKey>, TableDetailList>()
    private let allSchemaTablesDedup = OnceTask<AllSchemaTablesLoadKey, CatalogTableListing.Result>()

    private var databaseListFence = CommitFence<UUID>()
    private var schemaListCommit = ListCommitState<DatabaseKey>()
    private var tablesCommit = ListCommitState<ObjectsKey>()
    private var routinesCommit = ListCommitState<ObjectsKey>()
    private var triggersCommit = ListCommitState<ObjectsKey>()
    private var typesCommit = ListCommitState<ObjectsKey>()
    private var partitionsCommit = ListCommitState<PartitionsKey>()
    private var tableDetailsCommit = ListCommitState<TableDetailsKey>()
    private var allSchemaTablesFence = CommitFence<DatabaseKey>()
    private var allSchemaTablesFreshness = CatalogFreshness<DatabaseKey>()
    private var allSchemaTablesRequested: [DatabaseKey: CatalogTableListing.SchemaSelection] = [:]
    private var allSchemaTablesCovered: [DatabaseKey: CatalogTableListing.SchemaSelection] = [:]

    nonisolated private static let logger = Logger(
        subsystem: "com.TablePro", category: "SidebarTree"
    )

    private init() {}

    private var schemaLists: TreeList<DatabaseKey, [String]> {
        TreeList(state: \.schemaList, commit: \.schemaListCommit, dedup: schemaDedup, label: "schemas", workload: .interactive)
    }

    private var tableLists: TreeList<ObjectsKey, [TableInfo]> {
        TreeList(state: \.tablesState, commit: \.tablesCommit, dedup: tablesDedup, label: "tables", workload: .interactive)
    }

    private var routineLists: TreeList<ObjectsKey, [RoutineInfo]> {
        TreeList(state: \.routinesState, commit: \.routinesCommit, dedup: routinesDedup, label: "routines", workload: .bulk)
    }

    private var triggerLists: TreeList<ObjectsKey, [TriggerInfo]> {
        TreeList(state: \.triggersState, commit: \.triggersCommit, dedup: triggersDedup, label: "triggers", workload: .bulk)
    }

    private var typeLists: TreeList<ObjectsKey, [UserDefinedTypeInfo]> {
        TreeList(state: \.typesState, commit: \.typesCommit, dedup: typesDedup, label: "types", workload: .bulk)
    }

    private var partitionLists: TreeList<PartitionsKey, [PartitionInfo]> {
        TreeList(state: \.partitionsState, commit: \.partitionsCommit, dedup: partitionsDedup, label: "partitions", workload: .interactive)
    }

    private var tableDetailLists: TreeList<TableDetailsKey, TableDetailList> {
        TreeList(state: \.tableDetailsState, commit: \.tableDetailsCommit, dedup: tableDetailsDedup, label: "table details", workload: .interactive)
    }

    // MARK: - Reads

    func databaseListState(for connectionId: UUID) -> MetadataLoadState<[DatabaseMetadata]> {
        databaseList[connectionId] ?? .idle
    }

    func databases(for connectionId: UUID) -> [DatabaseMetadata] {
        databaseList[connectionId]?.value ?? []
    }

    func schemaListState(connectionId: UUID, database: String) -> MetadataLoadState<[String]> {
        schemaList[DatabaseKey(connectionId: connectionId, database: database)] ?? .idle
    }

    func schemas(connectionId: UUID, database: String) -> [String] {
        schemaList[DatabaseKey(connectionId: connectionId, database: database)]?.value ?? []
    }

    func tablesLoadState(connectionId: UUID, database: String, schema: String?) -> MetadataLoadState<[TableInfo]> {
        tablesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)] ?? .idle
    }

    func routinesLoadState(connectionId: UUID, database: String, schema: String?) -> MetadataLoadState<[RoutineInfo]> {
        routinesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)] ?? .idle
    }

    func tables(connectionId: UUID, database: String, schema: String?) -> [TableInfo] {
        tablesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)]?.value ?? []
    }

    func routines(connectionId: UUID, database: String, schema: String?) -> [RoutineInfo] {
        routinesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)]?.value ?? []
    }

    func triggersLoadState(connectionId: UUID, database: String, schema: String?) -> MetadataLoadState<[TriggerInfo]> {
        triggersState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)] ?? .idle
    }

    func triggers(connectionId: UUID, database: String, schema: String?) -> [TriggerInfo] {
        triggersState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)]?.value ?? []
    }

    func typesLoadState(
        connectionId: UUID, database: String, schema: String?
    ) -> MetadataLoadState<[UserDefinedTypeInfo]> {
        typesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)] ?? .idle
    }

    func userDefinedTypes(connectionId: UUID, database: String, schema: String?) -> [UserDefinedTypeInfo] {
        typesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)]?.value ?? []
    }

    func partitionsLoadState(
        connectionId: UUID, database: String, schema: String?, table: String
    ) -> MetadataLoadState<[PartitionInfo]> {
        let key = Self.partitionsKey(connectionId: connectionId, database: database, schema: schema, table: table)
        return partitionsState[key] ?? .idle
    }

    func tableDetailsLoadState(
        connectionId: UUID, database: String, schema: String?, table: String, kind: TableDetailKind
    ) -> MetadataLoadState<TableDetailList> {
        let key = Self.tableDetailsKey(connectionId: connectionId, database: database, schema: schema, table: table, kind: kind)
        return tableDetailsState[key] ?? .idle
    }

    func allSchemaTablesLoadState(
        connectionId: UUID, database: String
    ) -> MetadataLoadState<CatalogTableListing.Result> {
        allSchemaTablesState[DatabaseKey(connectionId: connectionId, database: database)] ?? .idle
    }

    /// Engines whose tables live in schemas the sidebar does not list until they are opened. The
    /// rest list a whole database in the one table list they already load.
    nonisolated static func listsTablesPerSchema(_ strategy: GroupingStrategy) -> Bool {
        switch strategy {
        case .bySchema, .hierarchicalSchema: return true
        case .flat, .byDatabase: return false
        }
    }

    // MARK: - Freshness

    /// Readers redraw on every change, so these do no I/O. A read that failed is not asked for
    /// again until the next change, or every redraw would repeat it.
    func schemaListNeedsFetch(connectionId: UUID, database: String) -> Bool {
        isConnected(connectionId)
            && schemaListCommit.freshness.needsFetch(DatabaseKey(connectionId: connectionId, database: database))
    }

    func tablesNeedFetch(connectionId: UUID, database: String, schema: String?) -> Bool {
        isConnected(connectionId)
            && tablesCommit.freshness.needsFetch(Self.objectsKey(connectionId: connectionId, database: database, schema: schema))
    }

    func isTablesCurrent(connectionId: UUID, database: String, schema: String?) -> Bool {
        isConnected(connectionId)
            && tablesCommit.freshness.isCurrent(Self.objectsKey(connectionId: connectionId, database: database, schema: schema))
    }

    func isRoutinesCurrent(connectionId: UUID, database: String, schema: String?) -> Bool {
        isConnected(connectionId)
            && routinesCommit.freshness.isCurrent(Self.objectsKey(connectionId: connectionId, database: database, schema: schema))
    }

    func isTriggersCurrent(connectionId: UUID, database: String, schema: String?) -> Bool {
        isConnected(connectionId)
            && triggersCommit.freshness.isCurrent(Self.objectsKey(connectionId: connectionId, database: database, schema: schema))
    }

    func isTypesCurrent(connectionId: UUID, database: String, schema: String?) -> Bool {
        isConnected(connectionId)
            && typesCommit.freshness.isCurrent(Self.objectsKey(connectionId: connectionId, database: database, schema: schema))
    }

    func objectsNeedFetch(connectionId: UUID, database: String, schema: String?) -> Bool {
        guard isConnected(connectionId) else { return false }
        return !objectKindsNeedingFetch(Self.objectsKey(connectionId: connectionId, database: database, schema: schema))
            .isEmpty
    }

    func partitionsNeedFetch(connectionId: UUID, database: String, schema: String?, table: String) -> Bool {
        isConnected(connectionId) && partitionsCommit.freshness.needsFetch(
            Self.partitionsKey(connectionId: connectionId, database: database, schema: schema, table: table)
        )
    }

    func tableDetailsNeedFetch(
        connectionId: UUID, database: String, schema: String?, table: String, kind: TableDetailKind
    ) -> Bool {
        isConnected(connectionId) && tableDetailsCommit.freshness.needsFetch(
            Self.tableDetailsKey(connectionId: connectionId, database: database, schema: schema, table: table, kind: kind)
        )
    }

    func listsRevision(for connectionId: UUID) -> Int {
        listsRevisions[connectionId] ?? 0
    }

    /// Values stay as they are; only the revisions move.
    func markStale(_ plan: CatalogTreeRefreshPlan, connectionId: UUID) {
        var marked = false
        for key in plan.schemaLists {
            schemaListCommit.freshness.markChanged(key)
            marked = true
        }
        for key in plan.tables {
            tablesCommit.freshness.markChanged(key)
            marked = true
        }
        for key in plan.partitions {
            partitionsCommit.freshness.markChanged(key)
            marked = true
        }
        for key in plan.tableDetails {
            tableDetailsCommit.freshness.markChanged(key)
            marked = true
        }
        for key in plan.routines {
            routinesCommit.freshness.markChanged(key)
            marked = true
        }
        for key in plan.triggers {
            triggersCommit.freshness.markChanged(key)
            marked = true
        }
        for key in plan.types {
            typesCommit.freshness.markChanged(key)
            marked = true
        }
        guard marked else { return }
        listsRevisions[connectionId, default: 0] &+= 1
    }

    private func objectKindsNeedingFetch(_ key: ObjectsKey) -> SQLCatalogObjectKinds {
        var kinds: SQLCatalogObjectKinds = []
        if tablesCommit.freshness.needsFetch(key) { kinds.insert(.tables) }
        if routinesCommit.freshness.needsFetch(key) { kinds.insert(.routines) }
        if browsesTriggers(key.connectionId), triggersCommit.freshness.needsFetch(key) { kinds.insert(.triggers) }
        if browsesUserDefinedTypes(key.connectionId), typesCommit.freshness.needsFetch(key) { kinds.insert(.types) }
        return kinds
    }

    // MARK: - All-schema tables

    /// Read when next asked for, never on a catalog change itself: a COMMIT is one too, and relisting
    /// every schema on each would pay for a listing nobody asked for.
    func loadAllSchemaTables(
        connectionId: UUID,
        database: String,
        selection: CatalogTableListing.SchemaSelection = .all
    ) async {
        guard isConnected(connectionId) else { return }
        let key = DatabaseKey(connectionId: connectionId, database: database)
        selectAllSchemaTables(selection, connectionId: connectionId, database: database)
        if allSchemaTablesFreshness.isCurrent(key) {
            await retryUnlistedSchemas(key, selection: selection)
            return
        }
        let revision = allSchemaTablesFreshness.revision(for: key)
        switch allSchemaTablesState[key] ?? .idle {
        case .loaded, .loading: break
        case .idle, .failed: allSchemaTablesState[key] = .loading
        }
        let token = allSchemaTablesFence.token(for: key)
        let outcome: MetadataFetchOutcome<CatalogTableListing.Result>
        do {
            let listing = try await allSchemaTablesDedup.execute(
                key: AllSchemaTablesLoadKey(database: key, selection: selection, revision: revision, retrying: [])
            ) { [self] in
                try await fetchAllSchemaTables(key, selection: selection)
            }
            outcome = .fetched(listing)
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
            Self.logger.warning(
                "all-schema tables load failed db=\(database, privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
        }
        // `commit` alone lets an older selection's listing land first and put hidden schemas back.
        guard allSchemaTablesFence.isCurrent(token, for: key), allSchemaTablesRequested[key] == selection else { return }
        let current = allSchemaTablesState[key] ?? .idle
        guard case .fetched(let listing) = outcome else {
            allSchemaTablesState[key] = current.settled(by: outcome, discardingValue: false)
            return
        }
        guard allSchemaTablesFreshness.commit(revision, for: key) else { return }
        allSchemaTablesState[key] = .loaded(listing.keepingRows(from: current.value))
        allSchemaTablesCovered[key] = selection
    }

    /// Narrows the held rows at once; they answer only for what both selections keep until the new
    /// listing lands, so widening hides nothing. A current listing covering the selection needs no read.
    func selectAllSchemaTables(_ selection: CatalogTableListing.SchemaSelection, connectionId: UUID, database: String) {
        let key = DatabaseKey(connectionId: connectionId, database: database)
        guard let previous = allSchemaTablesRequested[key] else {
            allSchemaTablesRequested[key] = selection
            return
        }
        guard previous != selection else { return }
        allSchemaTablesRequested[key] = selection
        let covered = allSchemaTablesCovered[key]
        let stillAnswers = covered.map { $0.intersection(selection) == selection } ?? false
        if !(stillAnswers && allSchemaTablesFreshness.isCurrent(key)) {
            allSchemaTablesFreshness.markChanged(key)
        }
        if let covered {
            allSchemaTablesCovered[key] = covered.intersection(selection)
        }
        if case .loaded(let listing) = allSchemaTablesState[key] {
            allSchemaTablesState[key] = .loaded(listing.restricted(to: selection))
        } else {
            objectWillChange.send()
        }
    }

    /// The selection the held rows answer for. Nil while nothing is held.
    func allSchemaTablesSelection(connectionId: UUID, database: String) -> CatalogTableListing.SchemaSelection? {
        allSchemaTablesCovered[DatabaseKey(connectionId: connectionId, database: database)]
    }

    func requestedAllSchemaTablesSelection(
        connectionId: UUID, database: String
    ) -> CatalogTableListing.SchemaSelection? {
        allSchemaTablesRequested[DatabaseKey(connectionId: connectionId, database: database)]
    }

    /// Only the schemas a listing could not read are asked for again: relisting the whole database
    /// would repeat a per-schema listing for a schema the role may never be able to read.
    private func retryUnlistedSchemas(_ key: DatabaseKey, selection: CatalogTableListing.SchemaSelection) async {
        guard let listing = allSchemaTablesState[key]?.value, !listing.unlistedSchemas.isEmpty else { return }
        let schemas = listing.unlistedSchemas
        let revision = allSchemaTablesFreshness.revision(for: key)
        let token = allSchemaTablesFence.token(for: key)
        let retry: CatalogTableListing.Result
        do {
            retry = try await allSchemaTablesDedup.execute(
                key: AllSchemaTablesLoadKey(database: key, selection: selection, revision: revision, retrying: schemas)
            ) { [self] in
                try await fetchSchemaTables(key, schemas: schemas)
            }
        } catch {
            return
        }
        guard allSchemaTablesFence.isCurrent(token, for: key),
              allSchemaTablesFreshness.revision(for: key) == revision,
              allSchemaTablesRequested[key] == selection,
              let current = allSchemaTablesState[key]?.value else { return }
        allSchemaTablesState[key] = .loaded(current.merging(retry, retried: schemas))
    }

    func markAllSchemaTablesChanged(_ keys: some Sequence<DatabaseKey>) {
        var changed = false
        for key in keys {
            allSchemaTablesFreshness.markChanged(key)
            changed = true
        }
        if changed {
            objectWillChange.send()
        }
    }

    /// Moves with each catalog change and each selection the held rows cannot answer.
    func allSchemaTablesRevision(connectionId: UUID, database: String) -> Int {
        allSchemaTablesFreshness.revision(for: DatabaseKey(connectionId: connectionId, database: database))
    }

    func isAllSchemaTablesCurrent(connectionId: UUID, database: String) -> Bool {
        isConnected(connectionId)
            && allSchemaTablesFreshness.isCurrent(DatabaseKey(connectionId: connectionId, database: database))
    }

    /// System schemas stay out, as they stay out of the tree until Show System is on.
    private func fetchAllSchemaTables(
        _ key: DatabaseKey,
        selection: CatalogTableListing.SchemaSelection
    ) async throws -> CatalogTableListing.Result {
        guard let session = DatabaseManager.shared.session(for: key.connectionId) else {
            throw DatabaseError.notConnected
        }
        let systemSchemas = Set(PluginManager.shared.systemSchemaNames(for: session.connection.type))
        return try await CatalogTableListing.tables(
            in: try listingScope(key), selection: selection, excludingSchemas: systemSchemas
        )
    }

    private func fetchSchemaTables(_ key: DatabaseKey, schemas: Set<String>) async throws -> CatalogTableListing.Result {
        try await CatalogTableListing.tables(inSchemas: schemas.sorted(), scope: try listingScope(key))
    }

    private func listingScope(_ key: DatabaseKey) throws -> DatabaseScope {
        guard let scope = DatabaseManager.shared.resolvedScope(
            database: key.database, schema: nil, for: key.connectionId
        ) else {
            throw DatabaseError.notConnected
        }
        return scope
    }

    // MARK: - Loads

    func loadDatabases(connectionId: UUID, databaseType: DatabaseType) async {
        guard isConnected(connectionId) else { return }
        switch databaseListState(for: connectionId) {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        databaseList[connectionId] = .loading
        let token = databaseListFence.token(for: connectionId)
        do {
            let list = try await fetchDatabaseList(connectionId: connectionId, databaseType: databaseType)
            guard databaseListFence.isCurrent(token, for: connectionId) else { return }
            databaseList[connectionId] = .loaded(list)
        } catch is CancellationError {
            guard databaseListFence.isCurrent(token, for: connectionId) else { return }
            if case .loading = databaseList[connectionId] { databaseList[connectionId] = .idle }
        } catch {
            guard databaseListFence.isCurrent(token, for: connectionId) else { return }
            databaseList[connectionId] = .failed(error.localizedDescription)
            Self.logger.warning("databases load failed connId=\(connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)")
        }
    }

    private func fetchDatabaseList(
        connectionId: UUID,
        databaseType: DatabaseType,
        workload: MetadataConnectionPool.Workload = .interactive
    ) async throws -> [DatabaseMetadata] {
        let systemNames = Set(PluginManager.shared.systemDatabaseNames(for: databaseType))
        return try await databaseDedup.execute(key: connectionId) { [self] in
            try await withDriver(connectionId: connectionId, database: nil, workload: workload) { driver in
                try await driver.fetchDatabases().sorted().map {
                    DatabaseMetadata.minimal(name: $0, isSystem: systemNames.contains($0))
                }
            }
        }
    }

    /// Each `load` reads unless the list is current, joins a read already running at the same
    /// revision, and keeps the rows on screen while it reads.
    func loadSchemas(connectionId: UUID, database: String) async {
        let key = DatabaseKey(connectionId: connectionId, database: database)
        await read(key, connectionId: connectionId, in: schemaLists, fetch: schemaListFetch(key))
    }

    func loadTables(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        await read(key, connectionId: connectionId, in: tableLists, fetch: tableListFetch(key))
    }

    func loadRoutines(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        await read(key, connectionId: connectionId, in: routineLists, fetch: routineListFetch(key))
    }

    func loadTriggers(connectionId: UUID, database: String, schema: String?) async {
        guard browsesTriggers(connectionId) else { return }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        await read(key, connectionId: connectionId, in: triggerLists, fetch: triggerListFetch(key))
    }

    func loadUserDefinedTypes(connectionId: UUID, database: String, schema: String?) async {
        guard browsesUserDefinedTypes(connectionId) else { return }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        await read(key, connectionId: connectionId, in: typeLists, fetch: typeListFetch(key))
    }

    func loadPartitions(connectionId: UUID, database: String, schema: String?, table: String) async {
        let key = Self.partitionsKey(connectionId: connectionId, database: database, schema: schema, table: table)
        await read(key, connectionId: connectionId, in: partitionLists, fetch: partitionListFetch(key))
    }

    /// One kind for one table: a group reads its own list and nothing beside it.
    func loadTableDetails(
        connectionId: UUID, database: String, schema: String?, table: String, kind: TableDetailKind
    ) async {
        let key = Self.tableDetailsKey(connectionId: connectionId, database: database, schema: schema, table: table, kind: kind)
        await read(key, connectionId: connectionId, in: tableDetailLists, fetch: tableDetailFetch(key))
    }

    /// Reads only the kinds that need it, so a container whose tables alone a change overtook reads
    /// its tables alone.
    func loadObjects(connectionId: UUID, database: String, schema: String?) async {
        guard isConnected(connectionId) else { return }
        let kinds = objectKindsNeedingFetch(Self.objectsKey(connectionId: connectionId, database: database, schema: schema))
        await withTaskGroup(of: Void.self) { group in
            if kinds.contains(.tables) {
                group.addTask { await self.loadTables(connectionId: connectionId, database: database, schema: schema) }
            }
            if kinds.contains(.routines) {
                group.addTask { await self.loadRoutines(connectionId: connectionId, database: database, schema: schema) }
            }
            if kinds.contains(.triggers) {
                group.addTask { await self.loadTriggers(connectionId: connectionId, database: database, schema: schema) }
            }
            if kinds.contains(.types) {
                group.addTask {
                    await self.loadUserDefinedTypes(connectionId: connectionId, database: database, schema: schema)
                }
            }
        }
    }

    // MARK: - Refresh

    /// Fetches first and commits over the old list, so a refresh never empties the tree
    /// and a failed refresh keeps the databases already on screen.
    func refreshDatabases(connectionId: UUID, databaseType: DatabaseType) async {
        let token = databaseListFence.supersede(connectionId)
        await databaseDedup.cancel(key: connectionId)
        guard databaseListFence.isCurrent(token, for: connectionId) else { return }
        guard case .loaded = databaseListState(for: connectionId) else {
            databaseList.removeValue(forKey: connectionId)
            await loadDatabases(connectionId: connectionId, databaseType: databaseType)
            return
        }
        guard isConnected(connectionId) else { return }
        do {
            let list = try await fetchDatabaseList(connectionId: connectionId, databaseType: databaseType, workload: .bulk)
            guard databaseListFence.isCurrent(token, for: connectionId) else { return }
            databaseList[connectionId] = .loaded(list)
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "databases refresh failed connId=\(connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    func refreshSchemas(connectionId: UUID, database: String) async {
        let key = DatabaseKey(connectionId: connectionId, database: database)
        await reread(key, connectionId: connectionId, in: schemaLists, fetch: schemaListFetch(key))
    }

    /// The schema's trigger list alone beside the tables: the table refresh already reads every detail
    /// list, the per-table Triggers among them, and reading one twice at once cancels the first read.
    func refreshObjects(connectionId: UUID, database: String, schema: String?) async {
        async let tables = refreshTableObjects(connectionId: connectionId, database: database, schema: schema)
        async let routines = refreshRoutineObjects(connectionId: connectionId, database: database, schema: schema)
        async let triggers = rereadTriggers(
            Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        )
        async let types = refreshUserDefinedTypeObjects(
            connectionId: connectionId, database: database, schema: schema
        )
        _ = await (tables, routines, triggers, types)
    }

    /// A row refreshes only the fetch its kind comes from. Partitions and a table's detail lists ride
    /// with the tables, because their rows are drawn as children of a table. Each says whether a newer
    /// read overtook it, for a reader that needs that read's rows rather than the ones the list kept
    /// meanwhile.
    @discardableResult
    func refreshTableObjects(connectionId: UUID, database: String, schema: String?) async -> Bool {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        async let tables = rereadTables(key)
        async let partitions: Void = refreshPartitions(under: key)
        async let details: Void = refreshTableDetails(under: key)
        let (overtaken, _, _) = await (tables, partitions, details)
        return overtaken
    }

    @discardableResult
    func refreshRoutineObjects(connectionId: UUID, database: String, schema: String?) async -> Bool {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        return await reread(key, connectionId: connectionId, in: routineLists, fetch: routineListFetch(key))
    }

    /// A table's Triggers group lists the same triggers one table at a time, so it reads again with
    /// the schema's list rather than staying stale beside it.
    @discardableResult
    func refreshTriggerObjects(connectionId: UUID, database: String, schema: String?) async -> Bool {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        async let triggers = rereadTriggers(key)
        async let details: Void = refreshTableDetails(under: key, kinds: [.triggers])
        let (overtaken, _) = await (triggers, details)
        return overtaken
    }

    /// The hierarchical layout reloads a schema through `SchemaService`, which holds no detail list,
    /// so its Refresh reads the schema's detail lists here.
    func refreshTableDetails(connectionId: UUID, database: String, schema: String?) async {
        await refreshTableDetails(under: Self.objectsKey(connectionId: connectionId, database: database, schema: schema))
    }

    @discardableResult
    func refreshUserDefinedTypeObjects(connectionId: UUID, database: String, schema: String?) async -> Bool {
        guard browsesUserDefinedTypes(connectionId) else { return false }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        return await reread(key, connectionId: connectionId, in: typeLists, fetch: typeListFetch(key))
    }

    private func rereadTables(_ key: ObjectsKey) async -> Bool {
        await reread(key, connectionId: key.connectionId, in: tableLists, fetch: tableListFetch(key))
    }

    private func rereadTriggers(_ key: ObjectsKey) async -> Bool {
        guard browsesTriggers(key.connectionId) else { return false }
        return await reread(key, connectionId: key.connectionId, in: triggerLists, fetch: triggerListFetch(key))
    }

    /// A list that is not loaded is dropped and read by its next reader rather than now.
    private func refreshPartitions(under key: ObjectsKey) async {
        for partitionKey in partitionKeys(matching: key) {
            guard case .loaded = partitionsState[partitionKey] ?? .idle else {
                partitionsCommit.fence.supersede(partitionKey)
                partitionsCommit.freshness.markChanged(partitionKey)
                partitionsState.removeValue(forKey: partitionKey)
                await partitionsDedup.cancel { $0.key == partitionKey }
                continue
            }
            await reread(
                partitionKey, connectionId: partitionKey.connectionId,
                in: partitionLists, fetch: partitionListFetch(partitionKey)
            )
        }
    }

    /// The rule partitions follow: a loaded list reads again over its rows, and one that never
    /// loaded is dropped for its next reader.
    private func refreshTableDetails(
        under key: ObjectsKey, kinds: Set<TableDetailKind> = Set(TableDetailKind.allCases)
    ) async {
        let detailKeys = tableDetailsState.keys.filter {
            $0.connectionId == key.connectionId && $0.database == key.database && $0.schema == key.schema
                && kinds.contains($0.kind)
        }
        for detailKey in detailKeys {
            guard case .loaded = tableDetailsState[detailKey] ?? .idle else {
                tableDetailsCommit.fence.supersede(detailKey)
                tableDetailsCommit.freshness.markChanged(detailKey)
                tableDetailsState.removeValue(forKey: detailKey)
                await tableDetailsDedup.cancel { $0.key == detailKey }
                continue
            }
            await reread(detailKey, connectionId: detailKey.connectionId, in: tableDetailLists, fetch: tableDetailFetch(detailKey))
        }
    }

    /// Table Details is one option for every window, so turning it off drops every detail list: no
    /// row draws one, and a refresh would read each of them again. Each key is superseded before any
    /// suspension, so a read still running commits nothing, and only reads started before the drop
    /// are cancelled, never one a group opened after the option came back on.
    func dropTableDetails() {
        guard !tableDetailsState.isEmpty else { return }
        var dropped: [TableDetailsKey: Int] = [:]
        for key in tableDetailsState.keys {
            tableDetailsCommit.fence.supersede(key)
            tableDetailsCommit.freshness.markChanged(key)
            dropped[key] = tableDetailsCommit.freshness.revision(for: key)
        }
        tableDetailsState.removeAll()
        Task { [dropped] in
            await tableDetailsDedup.cancel { fetch in
                dropped[fetch.key].map { fetch.revision < $0 } ?? false
            }
        }
    }

    /// A table's identity ignores its partition count, so the equality guard on a table list is blind
    /// to a count that moved; another client adding a partition is exactly that case.
    nonisolated internal static func partitionCountsChanged(
        from previous: MetadataLoadState<[TableInfo]>?,
        to next: MetadataLoadState<[TableInfo]>
    ) -> Bool {
        guard case .loaded(let nextTables) = next else { return false }
        guard case .loaded(let previousTables) = previous else { return true }
        let previousCounts = Dictionary(
            previousTables.map { ($0.id, $0.partitionCount) },
            uniquingKeysWith: { first, _ in first }
        )
        return nextTables.contains { table in
            guard let previous = previousCounts[table.id] else { return true }
            return previous != table.partitionCount
        }
    }

    // MARK: - Read and reread

    private func read<Key: Hashable & Sendable, Value: Sendable & Equatable>(
        _ key: Key,
        connectionId: UUID,
        in list: TreeList<Key, Value>,
        token explicitToken: Int? = nil,
        fetch: @escaping ListFetch<Value>
    ) async {
        guard isConnected(connectionId) else { return }
        let token = explicitToken ?? self[keyPath: list.commit].fence.token(for: key)
        guard self[keyPath: list.commit].fence.isCurrent(token, for: key),
              !self[keyPath: list.commit].freshness.isCurrent(key) else { return }
        let revision = self[keyPath: list.commit].freshness.revision(for: key)
        self[keyPath: list.commit].freshness.noteFetchStarted(revision, for: key)
        // Rows on screen mean nobody waits on this read, so completion goes ahead of it.
        let workload: MetadataConnectionPool.Workload
        switch self[keyPath: list.state][key] ?? .idle {
        case .loaded:
            workload = .bulk
        case .loading:
            workload = list.workload
        case .idle, .failed:
            workload = list.workload
            self[keyPath: list.state][key] = .loading
        }

        let outcome: MetadataFetchOutcome<Value>
        var failure: Error?
        do {
            outcome = .fetched(try await list.dedup.execute(key: ListFetchKey(key: key, revision: revision)) {
                try await fetch(workload)
            })
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(error.localizedDescription)
            failure = error
        }

        // Whoever superseded the key owns it now.
        guard self[keyPath: list.commit].fence.isCurrent(token, for: key) else { return }
        let current = self[keyPath: list.state][key] ?? .idle
        switch outcome {
        case .fetched(let value):
            // A fetch a change overtook still delivers its rows, but the key stays stale.
            guard self[keyPath: list.commit].freshness.commit(revision, for: key) else { return }
            // Always the new value: the models compare by identity, so a type recreated under the
            // same name would otherwise keep its dead OID in a list marked current.
            self[keyPath: list.state][key] = .loaded(value)
        case .failed:
            if let failure {
                let label = list.label
                Self.logger.warning(
                    "\(label, privacy: .public) load failed connId=\(connectionId, privacy: .public) error=\(failure.publicLogShape, privacy: .public)"
                )
            }
            settle(key, in: list, current: current, by: outcome)
        case .cancelled:
            self[keyPath: list.commit].freshness.noteFetchAbandoned(revision, for: key)
            settle(key, in: list, current: current, by: outcome)
        }
    }

    /// Loaded rows survive a failed or cancelled read; only a spinner with nothing behind it changes.
    private func settle<Key: Hashable & Sendable, Value: Sendable & Equatable>(
        _ key: Key,
        in list: TreeList<Key, Value>,
        current: MetadataLoadState<Value>,
        by outcome: MetadataFetchOutcome<Value>
    ) {
        if case .loaded = current { return }
        self[keyPath: list.state][key] = current.settled(by: outcome, discardingValue: false)
    }

    /// Refresh and Retry: supersede before the first suspension, so a fetch still in flight cannot
    /// commit, and a reread superseded meanwhile stops rather than committing under the newer token.
    /// Returns whether it was superseded so.
    @discardableResult
    private func reread<Key: Hashable & Sendable, Value: Sendable & Equatable>(
        _ key: Key,
        connectionId: UUID,
        in list: TreeList<Key, Value>,
        fetch: @escaping ListFetch<Value>
    ) async -> Bool {
        let token = self[keyPath: list.commit].fence.supersede(key)
        self[keyPath: list.commit].freshness.markChanged(key)
        let revision = self[keyPath: list.commit].freshness.revision(for: key)
        await list.dedup.cancel { $0.key == key && $0.revision != revision }
        await read(key, connectionId: connectionId, in: list, token: token, fetch: fetch)
        return !self[keyPath: list.commit].fence.isCurrent(token, for: key)
    }

    private func schemaListFetch(_ key: DatabaseKey) -> ListFetch<[String]> {
        { [self] workload in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: workload) { driver in
                try await driver.fetchSchemas()
            }
        }
    }

    private func tableListFetch(_ key: ObjectsKey) -> ListFetch<[TableInfo]> {
        let schema = key.schema
        return { [self] workload in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: workload) { driver in
                try await driver.fetchTables(schema: schema)
            }
        }
    }

    private func routineListFetch(_ key: ObjectsKey) -> ListFetch<[RoutineInfo]> {
        let schema = key.schema
        return { [self] workload in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: workload) { driver in
                try await driver.fetchRoutines(schema: schema)
            }
        }
    }

    private func triggerListFetch(_ key: ObjectsKey) -> ListFetch<[TriggerInfo]> {
        let schema = key.schema
        return { [self] workload in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: workload) { driver in
                try await driver.fetchAllTriggers(schema: schema)
            }
        }
    }

    private func typeListFetch(_ key: ObjectsKey) -> ListFetch<[UserDefinedTypeInfo]> {
        let schema = key.schema
        return { [self] workload in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: workload) { driver in
                try await driver.fetchUserDefinedTypes(schema: schema)
            }
        }
    }

    private func partitionListFetch(_ key: PartitionsKey) -> ListFetch<[PartitionInfo]> {
        let schema = key.schema
        let table = key.table
        return { [self] workload in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: workload) { driver in
                try await driver.fetchPartitionDetails(table: table, schema: schema)
            }
        }
    }

    private func tableDetailFetch(_ key: TableDetailsKey) -> ListFetch<TableDetailList> {
        let table = key.table
        let schema = key.schema
        let kind = key.kind
        return { [self] workload in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: workload) { driver in
                try await Self.fetchTableDetails(kind, table: table, schema: schema, from: driver)
            }
        }
    }

    nonisolated private static func fetchTableDetails(
        _ kind: TableDetailKind, table: String, schema: String?, from driver: DatabaseDriver
    ) async throws -> TableDetailList {
        switch kind {
        case .columns: return .columns(try await driver.fetchColumns(table: table, schema: schema))
        case .indexes: return .indexes(try await driver.fetchIndexes(table: table, schema: schema))
        case .foreignKeys: return .foreignKeys(try await driver.fetchForeignKeys(table: table, schema: schema))
        case .checks: return .checks(try await driver.fetchCheckConstraints(table: table, schema: schema))
        case .triggers: return .triggers(try await driver.fetchTriggers(table: table, schema: schema))
        }
    }

    // MARK: - Lifecycle

    /// A fetch still running on the replaced driver answers for the old session, so every key is
    /// superseded before anything suspends, and marked stale only after `resetPending`'s awaits, whose
    /// cancels would otherwise take a read started meanwhile and leave the key stale with nothing published.
    ///
    /// The pooled connections are not this service's to close: `DatabaseManager`, which rebuilds the
    /// transport, holds them back, and closing them withdrew an open another database's tab waited on.
    func handleReconnect(connectionId: UUID) async {
        supersedeEveryKey(of: connectionId)
        SchemaForeignKeyStore.shared.invalidate(connectionId: connectionId)
        await resetPending(connectionId: connectionId)
        markListsStale(connectionId: connectionId)
    }

    func handleDisconnect(connectionId: UUID) async {
        supersedeEveryKey(of: connectionId)
        SchemaForeignKeyStore.shared.invalidate(connectionId: connectionId)
        await cancelFetches(of: connectionId)
        schemaListCommit.freshness.removeAll { $0.connectionId == connectionId }
        tablesCommit.freshness.removeAll { $0.connectionId == connectionId }
        routinesCommit.freshness.removeAll { $0.connectionId == connectionId }
        triggersCommit.freshness.removeAll { $0.connectionId == connectionId }
        typesCommit.freshness.removeAll { $0.connectionId == connectionId }
        partitionsCommit.freshness.removeAll { $0.connectionId == connectionId }
        tableDetailsCommit.freshness.removeAll { $0.connectionId == connectionId }
        allSchemaTablesFreshness.removeAll { $0.connectionId == connectionId }
        allSchemaTablesRequested = allSchemaTablesRequested.filter { $0.key.connectionId != connectionId }
        allSchemaTablesCovered = allSchemaTablesCovered.filter { $0.key.connectionId != connectionId }
        listsRevisions.removeValue(forKey: connectionId)
        allSchemaTablesState = allSchemaTablesState.filter { $0.key.connectionId != connectionId }
        databaseList.removeValue(forKey: connectionId)
        schemaList = schemaList.filter { $0.key.connectionId != connectionId }
        tablesState = tablesState.filter { $0.key.connectionId != connectionId }
        routinesState = routinesState.filter { $0.key.connectionId != connectionId }
        triggersState = triggersState.filter { $0.key.connectionId != connectionId }
        typesState = typesState.filter { $0.key.connectionId != connectionId }
        partitionsState = partitionsState.filter { $0.key.connectionId != connectionId }
        tableDetailsState = tableDetailsState.filter { $0.key.connectionId != connectionId }
    }

    // MARK: - Private

    private func supersedeEveryKey(of connectionId: UUID) {
        databaseListFence.supersede(connectionId)
        for key in schemaList.keys where key.connectionId == connectionId {
            schemaListCommit.fence.supersede(key)
        }
        let objectKeys = Self.connectionObjectKeys(
            tableKeys: tablesState.keys,
            routineKeys: routinesState.keys,
            triggerKeys: triggersState.keys,
            typeKeys: typesState.keys,
            connectionId: connectionId
        )
        for key in objectKeys {
            tablesCommit.fence.supersede(key)
            routinesCommit.fence.supersede(key)
            triggersCommit.fence.supersede(key)
            typesCommit.fence.supersede(key)
        }
        for key in connectionPartitionKeys(connectionId) {
            partitionsCommit.fence.supersede(key)
        }
        for key in tableDetailsState.keys where key.connectionId == connectionId {
            tableDetailsCommit.fence.supersede(key)
        }
        for key in allSchemaTablesState.keys where key.connectionId == connectionId {
            allSchemaTablesFence.supersede(key)
        }
    }

    private func cancelFetches(of connectionId: UUID) async {
        await databaseDedup.cancel(key: connectionId)
        await schemaDedup.cancel { $0.key.connectionId == connectionId }
        await tablesDedup.cancel { $0.key.connectionId == connectionId }
        await routinesDedup.cancel { $0.key.connectionId == connectionId }
        await triggersDedup.cancel { $0.key.connectionId == connectionId }
        await typesDedup.cancel { $0.key.connectionId == connectionId }
        await partitionsDedup.cancel { $0.key.connectionId == connectionId }
        await tableDetailsDedup.cancel { $0.key.connectionId == connectionId }
        await allSchemaTablesDedup.cancel { $0.database.connectionId == connectionId }
    }

    /// Every fetch here was superseded, so none can settle its own spinner; each is put back to idle.
    private func resetPending(connectionId: UUID) async {
        await cancelFetches(of: connectionId)
        if isPending(databaseList[connectionId]) { databaseList[connectionId] = .idle }
        idlePending(\.schemaList) { $0.connectionId == connectionId }
        idlePending(\.tablesState) { $0.connectionId == connectionId }
        idlePending(\.routinesState) { $0.connectionId == connectionId }
        idlePending(\.triggersState) { $0.connectionId == connectionId }
        idlePending(\.typesState) { $0.connectionId == connectionId }
        idlePending(\.partitionsState) { $0.connectionId == connectionId }
        idlePending(\.tableDetailsState) { $0.connectionId == connectionId }
        idlePending(\.allSchemaTablesState) { $0.connectionId == connectionId }
    }

    private func idlePending<Key: Hashable, Value>(
        _ state: ReferenceWritableKeyPath<DatabaseTreeMetadataService, [Key: MetadataLoadState<Value>]>,
        where belongs: (Key) -> Bool
    ) {
        let pending = self[keyPath: state].filter { belongs($0.key) && isPending($0.value) }.map(\.key)
        for key in pending {
            self[keyPath: state][key] = .idle
        }
    }

    private func isPending<Value>(_ state: MetadataLoadState<Value>?) -> Bool {
        switch state {
        case .loading, .failed: return true
        case .idle, .loaded, .none: return false
        }
    }

    private func isConnected(_ connectionId: UUID) -> Bool {
        DatabaseManager.shared.session(for: connectionId)?.status == .connected
    }

    /// The capability gates the QUERY, never the display: a driver that returns triggers anyway
    /// still gets its section, since `SidebarObjectKind.visible` lists any kind that has rows.
    private func browsesTriggers(_ connectionId: UUID) -> Bool {
        DatabaseManager.shared.session(for: connectionId)?
            .connection.type.supportsDatabaseTriggerBrowse ?? false
    }

    private func browsesUserDefinedTypes(_ connectionId: UUID) -> Bool {
        DatabaseManager.shared.session(for: connectionId)?
            .connection.type.supportsUserDefinedTypeBrowse ?? false
    }

    /// Always a scoped driver, through `withMetadataDriver`, which alone knows which engines cannot
    /// answer on a second connection. The scope names the database only: a scope per schema took a
    /// pooled connection per expanded schema node.
    private func withDriver<T: Sendable>(
        connectionId: UUID,
        database: String?,
        workload: MetadataConnectionPool.Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let scope = DatabaseManager.shared.resolvedScope(
            database: database, schema: nil, for: connectionId
        ) else {
            throw DatabaseError.notConnected
        }
        return try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: workload, body)
    }

    private static func objectsKey(connectionId: UUID, database: String, schema: String?) -> ObjectsKey {
        let normalized: String? = (schema?.isEmpty == true) ? nil : schema
        return ObjectsKey(connectionId: connectionId, database: database, schema: normalized)
    }

    private static func partitionsKey(
        connectionId: UUID, database: String, schema: String?, table: String
    ) -> PartitionsKey {
        let normalized: String? = (schema?.isEmpty == true) ? nil : schema
        return PartitionsKey(connectionId: connectionId, database: database, schema: normalized, table: table)
    }

    private static func tableDetailsKey(
        connectionId: UUID, database: String, schema: String?, table: String, kind: TableDetailKind
    ) -> TableDetailsKey {
        let normalized: String? = (schema?.isEmpty == true) ? nil : schema
        return TableDetailsKey(connectionId: connectionId, database: database, schema: normalized, table: table, kind: kind)
    }

    private func partitionKeys(matching key: ObjectsKey) -> [PartitionsKey] {
        partitionsState.keys.filter {
            $0.connectionId == key.connectionId && $0.database == key.database && $0.schema == key.schema
        }
    }

    private func connectionPartitionKeys(_ connectionId: UUID) -> [PartitionsKey] {
        partitionsState.keys.filter { $0.connectionId == connectionId }
    }

    nonisolated static func connectionObjectKeys(
        tableKeys: some Sequence<ObjectsKey>,
        routineKeys: some Sequence<ObjectsKey>,
        triggerKeys: some Sequence<ObjectsKey>,
        typeKeys: some Sequence<ObjectsKey> = [],
        connectionId: UUID
    ) -> [ObjectsKey] {
        Array(Set(tableKeys).union(routineKeys).union(triggerKeys).union(typeKeys))
            .filter { $0.connectionId == connectionId }
    }
}
