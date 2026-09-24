//
//  DatabaseTreeMetadataService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

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

    /// Keyed by the revision it was started under as well as the database, so a read that arrives
    /// after a catalog change starts its own fetch instead of joining one that began before it.
    /// `retrying` names the schemas a second read asks for, and is empty for a whole listing.
    struct AllSchemaTablesLoadKey: Hashable, Sendable {
        let database: DatabaseKey
        let revision: Int
        let retrying: Set<String>
    }

    @Published private(set) var databaseList: [UUID: MetadataLoadState<[DatabaseMetadata]>] = [:]
    @Published private(set) var schemaList: [DatabaseKey: MetadataLoadState<[String]>] = [:]
    @Published private(set) var tablesState: [ObjectsKey: MetadataLoadState<[TableInfo]>] = [:]
    @Published private(set) var routinesState: [ObjectsKey: MetadataLoadState<[RoutineInfo]>] = [:]
    @Published private(set) var triggersState: [ObjectsKey: MetadataLoadState<[TriggerInfo]>] = [:]
    @Published private(set) var typesState: [ObjectsKey: MetadataLoadState<[UserDefinedTypeInfo]>] = [:]
    @Published private(set) var partitionsState: [PartitionsKey: MetadataLoadState<[PartitionInfo]>] = [:]
    @Published private(set) var allSchemaTablesState: [DatabaseKey: MetadataLoadState<CatalogTableListing.Result>] = [:]

    private let databaseDedup = OnceTask<UUID, [DatabaseMetadata]>()
    private let schemaDedup = OnceTask<DatabaseKey, [String]>()
    private let tablesDedup = OnceTask<ObjectsKey, [TableInfo]>()
    private let routinesDedup = OnceTask<ObjectsKey, [RoutineInfo]>()
    private let triggersDedup = OnceTask<ObjectsKey, [TriggerInfo]>()
    private let typesDedup = OnceTask<ObjectsKey, [UserDefinedTypeInfo]>()
    private let partitionsDedup = OnceTask<PartitionsKey, [PartitionInfo]>()
    private let allSchemaTablesDedup = OnceTask<AllSchemaTablesLoadKey, CatalogTableListing.Result>()

    private var databaseListFence = CommitFence<UUID>()
    private var schemaListFence = CommitFence<DatabaseKey>()
    private var tablesFence = CommitFence<ObjectsKey>()
    private var routinesFence = CommitFence<ObjectsKey>()
    private var triggersFence = CommitFence<ObjectsKey>()
    private var typesFence = CommitFence<ObjectsKey>()
    private var partitionsFence = CommitFence<PartitionsKey>()
    private var allSchemaTablesFence = CommitFence<DatabaseKey>()
    private var allSchemaTablesFreshness = CatalogFreshness<DatabaseKey>()

    nonisolated private static let logger = Logger(
        subsystem: "com.TablePro", category: "SidebarTree"
    )

    private init() {}

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

    // MARK: - All-schema tables

    /// Every schema's tables in one database, for the searches that have to judge a schema nobody
    /// has expanded. Unlike the lists the tree draws, it refreshes when it is next read rather than
    /// on every catalog change: a COMMIT reports a catalog change too, and relisting every schema
    /// of the database on each one would pay for a listing nobody asked for.
    func loadAllSchemaTables(connectionId: UUID, database: String) async {
        guard isConnected(connectionId) else { return }
        let key = DatabaseKey(connectionId: connectionId, database: database)
        if allSchemaTablesFreshness.isCurrent(key) {
            await retryUnlistedSchemas(key)
            return
        }
        let revision = allSchemaTablesFreshness.revision(for: key)
        allSchemaTablesState[key] = (allSchemaTablesState[key] ?? .idle).enteringLoad
        let token = allSchemaTablesFence.token(for: key)
        let outcome: MetadataFetchOutcome<CatalogTableListing.Result>
        do {
            let listing = try await allSchemaTablesDedup.execute(
                key: AllSchemaTablesLoadKey(database: key, revision: revision, retrying: [])
            ) { [self] in
                try await fetchAllSchemaTables(key)
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
        guard allSchemaTablesFence.isCurrent(token, for: key) else { return }
        let current = allSchemaTablesState[key] ?? .idle
        guard case .fetched(let listing) = outcome else {
            allSchemaTablesState[key] = current.settled(by: outcome, discardingValue: false)
            return
        }
        guard allSchemaTablesFreshness.commit(revision, for: key) else { return }
        allSchemaTablesState[key] = .loaded(listing.keepingRows(from: current.value))
    }

    /// A listing that could not read some schemas stays current for the rest, and only those are
    /// asked for again on the next read. Relisting the whole database each time would repeat a
    /// schema-by-schema listing for the one schema the role may never be able to read.
    private func retryUnlistedSchemas(_ key: DatabaseKey) async {
        guard let listing = allSchemaTablesState[key]?.value, !listing.unlistedSchemas.isEmpty else { return }
        let schemas = listing.unlistedSchemas
        let revision = allSchemaTablesFreshness.revision(for: key)
        let token = allSchemaTablesFence.token(for: key)
        let retry: CatalogTableListing.Result
        do {
            retry = try await allSchemaTablesDedup.execute(
                key: AllSchemaTablesLoadKey(database: key, revision: revision, retrying: schemas)
            ) { [self] in
                try await fetchSchemaTables(key, schemas: schemas)
            }
        } catch {
            return
        }
        guard allSchemaTablesFence.isCurrent(token, for: key),
              allSchemaTablesFreshness.revision(for: key) == revision,
              let current = allSchemaTablesState[key]?.value else { return }
        allSchemaTablesState[key] = .loaded(current.merging(retry, retried: schemas))
    }

    /// Announced, so a search holding the listing on screen can ask for it again rather than keep
    /// matching against rows a catalog change has overtaken.
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

    /// Moves with every catalog change that reaches the database, so a caller that asked for the
    /// listing at one revision knows to ask again at the next and not before.
    func allSchemaTablesRevision(connectionId: UUID, database: String) -> Int {
        allSchemaTablesFreshness.revision(for: DatabaseKey(connectionId: connectionId, database: database))
    }

    /// System schemas stay out, as they stay out of the tree until Show System is on.
    private func fetchAllSchemaTables(_ key: DatabaseKey) async throws -> CatalogTableListing.Result {
        guard let session = DatabaseManager.shared.session(for: key.connectionId) else {
            throw DatabaseError.notConnected
        }
        let systemSchemas = Set(PluginManager.shared.systemSchemaNames(for: session.connection.type))
        return try await CatalogTableListing.tables(in: try listingScope(key), excludingSchemas: systemSchemas)
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

    private func fetchDatabaseList(connectionId: UUID, databaseType: DatabaseType) async throws -> [DatabaseMetadata] {
        let systemNames = Set(PluginManager.shared.systemDatabaseNames(for: databaseType))
        return try await databaseDedup.execute(key: connectionId) { [self] in
            try await withDriver(connectionId: connectionId, database: nil) { driver in
                try await driver.fetchDatabases().sorted().map {
                    DatabaseMetadata.minimal(name: $0, isSystem: systemNames.contains($0))
                }
            }
        }
    }

    func loadSchemas(connectionId: UUID, database: String) async {
        guard isConnected(connectionId) else { return }
        let key = DatabaseKey(connectionId: connectionId, database: database)
        switch schemaList[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        schemaList[key] = .loading
        let token = schemaListFence.token(for: key)
        do {
            let list = try await fetchSchemaList(connectionId: connectionId, database: database, key: key)
            guard schemaListFence.isCurrent(token, for: key) else { return }
            schemaList[key] = .loaded(list)
        } catch is CancellationError {
            guard schemaListFence.isCurrent(token, for: key) else { return }
            if case .loading = schemaList[key] { schemaList[key] = .idle }
        } catch {
            guard schemaListFence.isCurrent(token, for: key) else { return }
            schemaList[key] = .failed(error.localizedDescription)
            Self.logger.warning("schemas load failed db=\(database, privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)")
        }
    }

    private func fetchSchemaList(connectionId: UUID, database: String, key: DatabaseKey) async throws -> [String] {
        try await schemaDedup.execute(key: key) { [self] in
            try await withDriver(connectionId: connectionId, database: database) { driver in
                try await driver.fetchSchemas()
            }
        }
    }

    func loadTables(connectionId: UUID, database: String, schema: String?) async {
        guard isConnected(connectionId) else { return }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        switch tablesState[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        tablesState[key] = .loading
        let token = tablesFence.token(for: key)
        do {
            let list = try await fetchTableList(key)
            guard tablesFence.isCurrent(token, for: key) else { return }
            tablesState[key] = .loaded(list)
        } catch is CancellationError {
            guard tablesFence.isCurrent(token, for: key) else { return }
            if case .loading = tablesState[key] { tablesState[key] = .idle }
        } catch {
            guard tablesFence.isCurrent(token, for: key) else { return }
            tablesState[key] = .failed(error.localizedDescription)
            Self.logger.warning(
                "tables load failed db=\(database, privacy: .private(mask: .hash)) schema=\(schema ?? "nil", privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    func loadRoutines(connectionId: UUID, database: String, schema: String?) async {
        guard isConnected(connectionId) else { return }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        switch routinesState[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        routinesState[key] = .loading
        let token = routinesFence.token(for: key)
        do {
            let list = try await fetchRoutineList(key)
            guard routinesFence.isCurrent(token, for: key) else { return }
            routinesState[key] = .loaded(list)
        } catch is CancellationError {
            guard routinesFence.isCurrent(token, for: key) else { return }
            if case .loading = routinesState[key] { routinesState[key] = .idle }
        } catch {
            guard routinesFence.isCurrent(token, for: key) else { return }
            routinesState[key] = .failed(error.localizedDescription)
            Self.logger.warning(
                "routines load failed db=\(database, privacy: .private(mask: .hash)) schema=\(schema ?? "nil", privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    private func fetchTableList(_ key: ObjectsKey) async throws -> [TableInfo] {
        let schema = key.schema
        return try await tablesDedup.execute(key: key) { [self] in
            try await withDriver(connectionId: key.connectionId, database: key.database) { driver in
                try await driver.fetchTables(schema: schema)
            }
        }
    }

    func loadTriggers(connectionId: UUID, database: String, schema: String?) async {
        guard isConnected(connectionId), browsesTriggers(connectionId) else { return }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        switch triggersState[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        triggersState[key] = .loading
        let token = triggersFence.token(for: key)
        do {
            let list = try await fetchTriggerList(key)
            guard triggersFence.isCurrent(token, for: key) else { return }
            triggersState[key] = .loaded(list)
        } catch is CancellationError {
            guard triggersFence.isCurrent(token, for: key) else { return }
            if case .loading = triggersState[key] { triggersState[key] = .idle }
        } catch {
            guard triggersFence.isCurrent(token, for: key) else { return }
            triggersState[key] = .failed(error.localizedDescription)
            Self.logger.warning(
                "triggers load failed db=\(database, privacy: .private(mask: .hash)) schema=\(schema ?? "nil", privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    private func fetchRoutineList(_ key: ObjectsKey) async throws -> [RoutineInfo] {
        let schema = key.schema
        return try await routinesDedup.execute(key: key) { [self] in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: .bulk) { driver in
                try await driver.fetchRoutines(schema: schema)
            }
        }
    }

    private func fetchTriggerList(_ key: ObjectsKey) async throws -> [TriggerInfo] {
        let schema = key.schema
        return try await triggersDedup.execute(key: key) { [self] in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: .bulk) { driver in
                try await driver.fetchAllTriggers(schema: schema)
            }
        }
    }

    func loadUserDefinedTypes(connectionId: UUID, database: String, schema: String?) async {
        guard isConnected(connectionId), browsesUserDefinedTypes(connectionId) else { return }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        switch typesState[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        typesState[key] = .loading
        let token = typesFence.token(for: key)
        do {
            let list = try await fetchTypeList(key)
            guard typesFence.isCurrent(token, for: key) else { return }
            typesState[key] = .loaded(list)
        } catch is CancellationError {
            guard typesFence.isCurrent(token, for: key) else { return }
            if case .loading = typesState[key] { typesState[key] = .idle }
        } catch {
            guard typesFence.isCurrent(token, for: key) else { return }
            typesState[key] = .failed(error.localizedDescription)
            Self.logger.warning(
                "types load failed db=\(database, privacy: .private(mask: .hash)) schema=\(schema ?? "nil", privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    private func fetchTypeList(_ key: ObjectsKey) async throws -> [UserDefinedTypeInfo] {
        let schema = key.schema
        return try await typesDedup.execute(key: key) { [self] in
            try await withDriver(connectionId: key.connectionId, database: key.database, workload: .bulk) { driver in
                try await driver.fetchUserDefinedTypes(schema: schema)
            }
        }
    }

    func loadPartitions(connectionId: UUID, database: String, schema: String?, table: String) async {
        guard isConnected(connectionId) else { return }
        let key = Self.partitionsKey(connectionId: connectionId, database: database, schema: schema, table: table)
        switch partitionsState[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        partitionsState[key] = .loading
        let normalizedSchema = key.schema
        let token = partitionsFence.token(for: key)
        do {
            let list = try await partitionsDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: connectionId, database: database) { driver in
                    try await driver.fetchPartitionDetails(table: table, schema: normalizedSchema)
                }
            }
            guard partitionsFence.isCurrent(token, for: key) else { return }
            partitionsState[key] = .loaded(list)
        } catch is CancellationError {
            guard partitionsFence.isCurrent(token, for: key) else { return }
            if case .loading = partitionsState[key] { partitionsState[key] = .idle }
        } catch {
            guard partitionsFence.isCurrent(token, for: key) else { return }
            partitionsState[key] = .failed(error.localizedDescription)
            Self.logger.warning(
                "partitions load failed db=\(database, privacy: .private(mask: .hash)) table=\(table, privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
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
            let list = try await fetchDatabaseList(connectionId: connectionId, databaseType: databaseType)
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
        let token = schemaListFence.supersede(key)
        await schemaDedup.cancel(key: key)
        guard schemaListFence.isCurrent(token, for: key) else { return }
        guard case .loaded = schemaList[key] ?? .idle else {
            schemaList.removeValue(forKey: key)
            await loadSchemas(connectionId: connectionId, database: database)
            return
        }
        guard isConnected(connectionId) else { return }
        do {
            let list = try await fetchSchemaList(connectionId: connectionId, database: database, key: key)
            guard schemaListFence.isCurrent(token, for: key) else { return }
            schemaList[key] = .loaded(list)
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "schemas refresh failed db=\(database, privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    func refreshObjects(connectionId: UUID, database: String, schema: String?) async {
        async let tables: Void = refreshTableObjects(connectionId: connectionId, database: database, schema: schema)
        async let routines: Void = refreshRoutineObjects(connectionId: connectionId, database: database, schema: schema)
        async let triggers: Void = refreshTriggerObjects(connectionId: connectionId, database: database, schema: schema)
        async let types: Void = refreshUserDefinedTypeObjects(
            connectionId: connectionId, database: database, schema: schema
        )
        _ = await (tables, routines, triggers, types)
    }

    /// Tables, routines, triggers and types are four separate fetches behind four separate states,
    /// so a row that stands for one kind refreshes only the fetch its kind comes from. Partitions
    /// ride with the tables, because a partition row is drawn as a child of the table it belongs to.
    func refreshTableObjects(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        let token = tablesFence.supersede(key)
        await tablesDedup.cancel(key: key)
        async let tables: Void = refreshTables(key, token: token)
        async let partitions: Void = refreshPartitions(under: key)
        _ = await (tables, partitions)
    }

    /// Each refresh supersedes its key before its first suspension and carries the token it issued,
    /// so a fetch that returns while the cancellation is still in flight cannot commit, and a refresh
    /// that was itself superseded meanwhile stops rather than committing under the newer token.
    func refreshRoutineObjects(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        let token = routinesFence.supersede(key)
        await routinesDedup.cancel(key: key)
        await refreshRoutines(key, token: token)
    }

    func refreshTriggerObjects(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        let token = triggersFence.supersede(key)
        await triggersDedup.cancel(key: key)
        await refreshTriggers(key, token: token)
    }

    func refreshUserDefinedTypeObjects(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        let token = typesFence.supersede(key)
        await typesDedup.cancel(key: key)
        await refreshUserDefinedTypes(key, token: token)
    }

    private func refreshUserDefinedTypes(_ key: ObjectsKey, token: Int) async {
        guard typesFence.isCurrent(token, for: key) else { return }
        guard case .loaded = typesState[key] ?? .idle else {
            typesState.removeValue(forKey: key)
            await loadUserDefinedTypes(connectionId: key.connectionId, database: key.database, schema: key.schema)
            return
        }
        guard isConnected(key.connectionId) else { return }
        do {
            let list = try await fetchTypeList(key)
            guard typesFence.isCurrent(token, for: key) else { return }
            typesState[key] = .loaded(list)
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "types refresh failed db=\(key.database, privacy: .public) schema=\(key.schema ?? "nil", privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    private func refreshTables(_ key: ObjectsKey, token: Int) async {
        guard tablesFence.isCurrent(token, for: key) else { return }
        guard case .loaded = tablesState[key] ?? .idle else {
            tablesState.removeValue(forKey: key)
            await loadTables(connectionId: key.connectionId, database: key.database, schema: key.schema)
            return
        }
        guard isConnected(key.connectionId) else { return }
        do {
            let list = try await fetchTableList(key)
            guard tablesFence.isCurrent(token, for: key) else { return }
            tablesState[key] = .loaded(list)
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "tables refresh failed db=\(key.database, privacy: .public) schema=\(key.schema ?? "nil", privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    private func refreshRoutines(_ key: ObjectsKey, token: Int) async {
        guard routinesFence.isCurrent(token, for: key) else { return }
        guard case .loaded = routinesState[key] ?? .idle else {
            routinesState.removeValue(forKey: key)
            await loadRoutines(connectionId: key.connectionId, database: key.database, schema: key.schema)
            return
        }
        guard isConnected(key.connectionId) else { return }
        do {
            let list = try await fetchRoutineList(key)
            guard routinesFence.isCurrent(token, for: key) else { return }
            routinesState[key] = .loaded(list)
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "routines refresh failed db=\(key.database, privacy: .public) schema=\(key.schema ?? "nil", privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    private func refreshTriggers(_ key: ObjectsKey, token: Int) async {
        guard triggersFence.isCurrent(token, for: key) else { return }
        guard case .loaded = triggersState[key] ?? .idle else {
            triggersState.removeValue(forKey: key)
            await loadTriggers(connectionId: key.connectionId, database: key.database, schema: key.schema)
            return
        }
        guard isConnected(key.connectionId) else { return }
        do {
            let list = try await fetchTriggerList(key)
            guard triggersFence.isCurrent(token, for: key) else { return }
            triggersState[key] = .loaded(list)
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "triggers refresh failed db=\(key.database, privacy: .public) schema=\(key.schema ?? "nil", privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    private func refreshPartitions(under key: ObjectsKey) async {
        for partitionKey in partitionKeys(matching: key) {
            guard case .loaded = partitionsState[partitionKey] ?? .idle else {
                partitionsFence.supersede(partitionKey)
                await partitionsDedup.cancel(key: partitionKey)
                partitionsState.removeValue(forKey: partitionKey)
                continue
            }
            await reloadPartitionsInPlace(partitionKey)
        }
    }

    func refreshLoadedTables(connectionId: UUID, database: String? = nil) async {
        let keys = tablesState.keys.filter { key in
            key.connectionId == connectionId && (database == nil || key.database == database)
        }
        let loadedPartitionKeys = partitionsState.keys.filter { key in
            key.connectionId == connectionId && (database == nil || key.database == database)
        }
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask {
                    await self.reloadTablesInPlace(key)
                }
            }
            for key in loadedPartitionKeys {
                group.addTask {
                    await self.reloadPartitionsInPlace(key)
                }
            }
        }
    }

    private func reloadTablesInPlace(_ key: ObjectsKey) async {
        guard isConnected(key.connectionId) else { return }
        let token = tablesFence.supersede(key)
        await tablesDedup.cancel(key: key)
        do {
            let list = try await tablesDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: key.connectionId, database: key.database) { driver in
                    try await driver.fetchTables(schema: key.schema)
                }
            }
            guard tablesFence.isCurrent(token, for: key) else { return }
            let next: MetadataLoadState<[TableInfo]> = .loaded(list)
            guard tablesState[key] != next || Self.partitionCountsChanged(from: tablesState[key], to: next)
            else { return }
            tablesState[key] = next
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "tables refresh failed db=\(key.database, privacy: .public) schema=\(key.schema ?? "nil", privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    /// A table's identity deliberately ignores its partition count, because the same table with one
    /// more partition is the same table. That makes the equality guard above blind to a count that
    /// moved on its own, which is exactly what a refresh after another client added a partition
    /// brings back, so the counts are compared separately.
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

    /// One loaded partition list, reloaded in place. The catalog-change path names its keys
    /// directly, because a partition list does not follow its parent's table list.
    internal func refreshPartitions(_ key: PartitionsKey) async {
        await reloadPartitionsInPlace(key)
    }

    private func reloadPartitionsInPlace(_ key: PartitionsKey) async {
        guard isConnected(key.connectionId) else { return }
        let token = partitionsFence.supersede(key)
        await partitionsDedup.cancel(key: key)
        do {
            let list = try await partitionsDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: key.connectionId, database: key.database) { driver in
                    try await driver.fetchPartitionDetails(table: key.table, schema: key.schema)
                }
            }
            guard partitionsFence.isCurrent(token, for: key) else { return }
            let next: MetadataLoadState<[PartitionInfo]> = .loaded(list)
            guard partitionsState[key] != next else { return }
            partitionsState[key] = next
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "partitions refresh failed db=\(key.database, privacy: .public) table=\(key.table, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
        }
    }

    // MARK: - Lifecycle

    /// A fetch still running on the driver the reconnect replaced answers for the old session, so
    /// every key of the connection is superseded before anything suspends and none of those fetches
    /// may commit. What is already on screen stays until the new session's own loads replace it.
    ///
    /// The pooled connections are not this service's to close. They stand on the transport rather
    /// than on the session driver, and `DatabaseManager`, which rebuilds the transport, holds them
    /// back while it does. Closing them on every reconnect withdrew an open a table tab on another
    /// database was waiting on, and that tab then showed nothing and no error.
    func handleReconnect(connectionId: UUID) async {
        supersedeEveryKey(of: connectionId)
        SchemaForeignKeyStore.shared.invalidate(connectionId: connectionId)
        markAllSchemaTablesChanged(allSchemaTablesState.keys.filter { $0.connectionId == connectionId })
        await resetPending(connectionId: connectionId)
    }

    func handleDisconnect(connectionId: UUID) async {
        supersedeEveryKey(of: connectionId)
        SchemaForeignKeyStore.shared.invalidate(connectionId: connectionId)
        let schemaKeys = schemaList.keys.filter { $0.connectionId == connectionId }
        let objectKeys = Self.connectionObjectKeys(
            tableKeys: tablesState.keys,
            routineKeys: routinesState.keys,
            triggerKeys: triggersState.keys,
            typeKeys: typesState.keys,
            connectionId: connectionId
        )
        await databaseDedup.cancel(key: connectionId)
        for key in schemaKeys { await schemaDedup.cancel(key: key) }
        for key in objectKeys {
            await tablesDedup.cancel(key: key)
            await routinesDedup.cancel(key: key)
            await triggersDedup.cancel(key: key)
            await typesDedup.cancel(key: key)
        }
        for key in connectionPartitionKeys(connectionId) {
            await partitionsDedup.cancel(key: key)
        }
        await allSchemaTablesDedup.cancel { $0.database.connectionId == connectionId }
        allSchemaTablesFreshness.removeAll { $0.connectionId == connectionId }
        allSchemaTablesState = allSchemaTablesState.filter { $0.key.connectionId != connectionId }
        databaseList.removeValue(forKey: connectionId)
        schemaList = schemaList.filter { $0.key.connectionId != connectionId }
        tablesState = tablesState.filter { $0.key.connectionId != connectionId }
        routinesState = routinesState.filter { $0.key.connectionId != connectionId }
        triggersState = triggersState.filter { $0.key.connectionId != connectionId }
        typesState = typesState.filter { $0.key.connectionId != connectionId }
        partitionsState = partitionsState.filter { $0.key.connectionId != connectionId }
    }

    // MARK: - Private

    private func supersedeEveryKey(of connectionId: UUID) {
        databaseListFence.supersede(connectionId)
        for key in schemaList.keys where key.connectionId == connectionId {
            schemaListFence.supersede(key)
        }
        let objectKeys = Self.connectionObjectKeys(
            tableKeys: tablesState.keys,
            routineKeys: routinesState.keys,
            triggerKeys: triggersState.keys,
            typeKeys: typesState.keys,
            connectionId: connectionId
        )
        for key in objectKeys {
            tablesFence.supersede(key)
            routinesFence.supersede(key)
            triggersFence.supersede(key)
            typesFence.supersede(key)
        }
        for key in connectionPartitionKeys(connectionId) {
            partitionsFence.supersede(key)
        }
        for key in allSchemaTablesState.keys where key.connectionId == connectionId {
            allSchemaTablesFence.supersede(key)
        }
    }

    private func resetPending(connectionId: UUID) async {
        let schemaKeys = schemaList.keys.filter { $0.connectionId == connectionId }
        let objectKeys = Self.connectionObjectKeys(
            tableKeys: tablesState.keys,
            routineKeys: routinesState.keys,
            triggerKeys: triggersState.keys,
            typeKeys: typesState.keys,
            connectionId: connectionId
        )

        if isPending(databaseList[connectionId]) {
            await databaseDedup.cancel(key: connectionId)
        }
        for key in schemaKeys where isPending(schemaList[key]) {
            await schemaDedup.cancel(key: key)
        }
        for key in objectKeys {
            if isPending(tablesState[key]) { await tablesDedup.cancel(key: key) }
            if isPending(routinesState[key]) { await routinesDedup.cancel(key: key) }
            if isPending(triggersState[key]) { await triggersDedup.cancel(key: key) }
            if isPending(typesState[key]) { await typesDedup.cancel(key: key) }
        }
        let partitionKeys = connectionPartitionKeys(connectionId)
        for key in partitionKeys where isPending(partitionsState[key]) {
            await partitionsDedup.cancel(key: key)
        }
        let allSchemaKeys = allSchemaTablesState.keys.filter { $0.connectionId == connectionId }
        await allSchemaTablesDedup.cancel { $0.database.connectionId == connectionId }
        for key in allSchemaKeys where isPending(allSchemaTablesState[key]) { allSchemaTablesState[key] = .idle }

        if isPending(databaseList[connectionId]) { databaseList[connectionId] = .idle }
        for key in schemaKeys where isPending(schemaList[key]) { schemaList[key] = .idle }
        for key in objectKeys {
            if isPending(tablesState[key]) { tablesState[key] = .idle }
            if isPending(routinesState[key]) { routinesState[key] = .idle }
            if isPending(triggersState[key]) { triggersState[key] = .idle }
            if isPending(typesState[key]) { typesState[key] = .idle }
        }
        for key in partitionKeys where isPending(partitionsState[key]) { partitionsState[key] = .idle }
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

    /// The capability gates the QUERY, never the display. An engine with no triggers should not
    /// pay a catalog read that can only answer empty, and a driver that returns triggers anyway
    /// still gets its section: `SidebarObjectKind.visible` lists any kind that has rows.
    private func browsesTriggers(_ connectionId: UUID) -> Bool {
        DatabaseManager.shared.session(for: connectionId)?
            .connection.type.supportsDatabaseTriggerBrowse ?? false
    }

    private func browsesUserDefinedTypes(_ connectionId: UUID) -> Bool {
        DatabaseManager.shared.session(for: connectionId)?
            .connection.type.supportsUserDefinedTypeBrowse ?? false
    }

    /// Always routes through a scoped driver. Reusing the session driver when the target
    /// looked like the browsed database used to be safe; it is not now that a tab's
    /// execution moves that driver without writing session state.
    ///
    /// Every read goes through here rather than reaching for `MetadataConnectionPool`
    /// directly, because only `metadataRoute` knows which engines cannot answer a metadata
    /// read on a second connection.
    ///
    /// The scope names the database and never the schema a row belongs to: every fetch here names
    /// its schema itself, and a scope per schema took a pooled connection per schema, one for each
    /// schema node the tree expanded.
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
