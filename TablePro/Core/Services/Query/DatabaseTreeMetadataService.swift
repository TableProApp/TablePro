//
//  DatabaseTreeMetadataService.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

@MainActor
@Observable
final class DatabaseTreeMetadataService {
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

    private(set) var databaseList: [UUID: MetadataLoadState<[DatabaseMetadata]>] = [:]
    private(set) var schemaList: [DatabaseKey: MetadataLoadState<[String]>] = [:]
    private(set) var tablesState: [ObjectsKey: MetadataLoadState<[TableInfo]>] = [:]
    private(set) var routinesState: [ObjectsKey: MetadataLoadState<[RoutineInfo]>] = [:]
    private(set) var partitionsState: [PartitionsKey: MetadataLoadState<[TableInfo]>] = [:]

    @ObservationIgnored private let databaseDedup = OnceTask<UUID, [DatabaseMetadata]>()
    @ObservationIgnored private let schemaDedup = OnceTask<DatabaseKey, [String]>()
    @ObservationIgnored private let tablesDedup = OnceTask<ObjectsKey, [TableInfo]>()
    @ObservationIgnored private let routinesDedup = OnceTask<ObjectsKey, [RoutineInfo]>()
    @ObservationIgnored private let partitionsDedup = OnceTask<PartitionsKey, [TableInfo]>()

    @ObservationIgnored nonisolated private static let logger = Logger(
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

    func partitionsLoadState(
        connectionId: UUID, database: String, schema: String?, table: String
    ) -> MetadataLoadState<[TableInfo]> {
        let key = Self.partitionsKey(connectionId: connectionId, database: database, schema: schema, table: table)
        return partitionsState[key] ?? .idle
    }

    // MARK: - Loads

    func loadDatabases(connectionId: UUID, databaseType: DatabaseType) async {
        guard isConnected(connectionId) else { return }
        switch databaseListState(for: connectionId) {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        databaseList[connectionId] = .loading
        do {
            let list = try await fetchDatabaseList(connectionId: connectionId, databaseType: databaseType)
            databaseList[connectionId] = .loaded(list)
        } catch is CancellationError {
            if case .loading = databaseList[connectionId] { databaseList[connectionId] = .idle }
        } catch {
            databaseList[connectionId] = .failed(error.localizedDescription)
            Self.logger.warning("databases load failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
        do {
            let list = try await fetchSchemaList(connectionId: connectionId, database: database, key: key)
            schemaList[key] = .loaded(list)
        } catch is CancellationError {
            if case .loading = schemaList[key] { schemaList[key] = .idle }
        } catch {
            schemaList[key] = .failed(error.localizedDescription)
            Self.logger.warning("schemas load failed db=\(database, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
        do {
            tablesState[key] = .loaded(try await fetchTableList(key))
        } catch is CancellationError {
            if case .loading = tablesState[key] { tablesState[key] = .idle }
        } catch {
            tablesState[key] = .failed(error.localizedDescription)
            Self.logger.warning(
                "tables load failed db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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
        do {
            routinesState[key] = .loaded(try await fetchRoutineList(key))
        } catch is CancellationError {
            if case .loading = routinesState[key] { routinesState[key] = .idle }
        } catch {
            routinesState[key] = .failed(error.localizedDescription)
            Self.logger.warning(
                "routines load failed db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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

    private func fetchRoutineList(_ key: ObjectsKey) async throws -> [RoutineInfo] {
        let schema = key.schema
        return try await routinesDedup.execute(key: key) { [self] in
            try await withDriver(
                connectionId: key.connectionId,
                database: key.database,
                schema: schema,
                workload: .bulk
            ) { driver in
                let procedures = try await driver.fetchProcedures(schema: schema)
                let functions = try await driver.fetchFunctions(schema: schema)
                return procedures + functions
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
        do {
            let list = try await partitionsDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: connectionId, database: database) { driver in
                    try await driver.fetchPartitions(table: table, schema: normalizedSchema)
                }
            }
            partitionsState[key] = .loaded(list)
        } catch is CancellationError {
            if case .loading = partitionsState[key] { partitionsState[key] = .idle }
        } catch {
            partitionsState[key] = .failed(error.localizedDescription)
            Self.logger.warning(
                "partitions load failed db=\(database, privacy: .public) table=\(table, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Refresh

    /// Fetches first and commits over the old list, so a refresh never empties the tree
    /// and a failed refresh keeps the databases already on screen.
    func refreshDatabases(connectionId: UUID, databaseType: DatabaseType) async {
        await databaseDedup.cancel(key: connectionId)
        guard case .loaded = databaseListState(for: connectionId) else {
            databaseList.removeValue(forKey: connectionId)
            await loadDatabases(connectionId: connectionId, databaseType: databaseType)
            return
        }
        guard isConnected(connectionId) else { return }
        do {
            databaseList[connectionId] = .loaded(
                try await fetchDatabaseList(connectionId: connectionId, databaseType: databaseType)
            )
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "databases refresh failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func refreshSchemas(connectionId: UUID, database: String) async {
        let key = DatabaseKey(connectionId: connectionId, database: database)
        await schemaDedup.cancel(key: key)
        guard case .loaded = schemaList[key] ?? .idle else {
            schemaList.removeValue(forKey: key)
            await loadSchemas(connectionId: connectionId, database: database)
            return
        }
        guard isConnected(connectionId) else { return }
        do {
            schemaList[key] = .loaded(
                try await fetchSchemaList(connectionId: connectionId, database: database, key: key)
            )
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "schemas refresh failed db=\(database, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func refreshObjects(connectionId: UUID, database: String, schema: String?) async {
        async let tables: Void = refreshTableObjects(connectionId: connectionId, database: database, schema: schema)
        async let routines: Void = refreshRoutineObjects(connectionId: connectionId, database: database, schema: schema)
        _ = await (tables, routines)
    }

    /// Tables and routines are two separate fetches behind two separate states, so a row that
    /// stands for one kind refreshes only the fetch its kind comes from. Partitions ride with the
    /// tables, because a partition row is drawn as a child of the table it belongs to.
    func refreshTableObjects(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        await tablesDedup.cancel(key: key)
        async let tables: Void = refreshTables(key)
        async let partitions: Void = refreshPartitions(under: key)
        _ = await (tables, partitions)
    }

    func refreshRoutineObjects(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        await routinesDedup.cancel(key: key)
        await refreshRoutines(key)
    }

    private func refreshTables(_ key: ObjectsKey) async {
        guard case .loaded = tablesState[key] ?? .idle else {
            tablesState.removeValue(forKey: key)
            await loadTables(connectionId: key.connectionId, database: key.database, schema: key.schema)
            return
        }
        guard isConnected(key.connectionId) else { return }
        do {
            tablesState[key] = .loaded(try await fetchTableList(key))
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "tables refresh failed db=\(key.database, privacy: .public) schema=\(key.schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func refreshRoutines(_ key: ObjectsKey) async {
        guard case .loaded = routinesState[key] ?? .idle else {
            routinesState.removeValue(forKey: key)
            await loadRoutines(connectionId: key.connectionId, database: key.database, schema: key.schema)
            return
        }
        guard isConnected(key.connectionId) else { return }
        do {
            routinesState[key] = .loaded(try await fetchRoutineList(key))
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "routines refresh failed db=\(key.database, privacy: .public) schema=\(key.schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func refreshPartitions(under key: ObjectsKey) async {
        for partitionKey in partitionKeys(matching: key) {
            guard case .loaded = partitionsState[partitionKey] ?? .idle else {
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
        await tablesDedup.cancel(key: key)
        do {
            let list = try await tablesDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: key.connectionId, database: key.database) { driver in
                    try await driver.fetchTables(schema: key.schema)
                }
            }
            let next: MetadataLoadState<[TableInfo]> = .loaded(list)
            guard tablesState[key] != next else { return }
            tablesState[key] = next
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "tables refresh failed db=\(key.database, privacy: .public) schema=\(key.schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func reloadPartitionsInPlace(_ key: PartitionsKey) async {
        guard isConnected(key.connectionId) else { return }
        await partitionsDedup.cancel(key: key)
        do {
            let list = try await partitionsDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: key.connectionId, database: key.database) { driver in
                    try await driver.fetchPartitions(table: key.table, schema: key.schema)
                }
            }
            let next: MetadataLoadState<[TableInfo]> = .loaded(list)
            guard partitionsState[key] != next else { return }
            partitionsState[key] = next
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "partitions refresh failed db=\(key.database, privacy: .public) table=\(key.table, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Lifecycle

    func handleReconnect(connectionId: UUID) async {
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
        SchemaForeignKeyStore.shared.invalidate(connectionId: connectionId)
        await resetPending(connectionId: connectionId)
    }

    func handleDisconnect(connectionId: UUID) async {
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
        SchemaForeignKeyStore.shared.invalidate(connectionId: connectionId)
        let schemaKeys = schemaList.keys.filter { $0.connectionId == connectionId }
        let objectKeys = Self.connectionObjectKeys(
            tableKeys: tablesState.keys, routineKeys: routinesState.keys, connectionId: connectionId
        )
        await databaseDedup.cancel(key: connectionId)
        for key in schemaKeys { await schemaDedup.cancel(key: key) }
        for key in objectKeys {
            await tablesDedup.cancel(key: key)
            await routinesDedup.cancel(key: key)
        }
        for key in connectionPartitionKeys(connectionId) {
            await partitionsDedup.cancel(key: key)
        }
        databaseList.removeValue(forKey: connectionId)
        schemaList = schemaList.filter { $0.key.connectionId != connectionId }
        tablesState = tablesState.filter { $0.key.connectionId != connectionId }
        routinesState = routinesState.filter { $0.key.connectionId != connectionId }
        partitionsState = partitionsState.filter { $0.key.connectionId != connectionId }
    }

    // MARK: - Private

    private func resetPending(connectionId: UUID) async {
        let schemaKeys = schemaList.keys.filter { $0.connectionId == connectionId }
        let objectKeys = Self.connectionObjectKeys(
            tableKeys: tablesState.keys, routineKeys: routinesState.keys, connectionId: connectionId
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
        }
        let partitionKeys = connectionPartitionKeys(connectionId)
        for key in partitionKeys where isPending(partitionsState[key]) {
            await partitionsDedup.cancel(key: key)
        }

        if isPending(databaseList[connectionId]) { databaseList[connectionId] = .idle }
        for key in schemaKeys where isPending(schemaList[key]) { schemaList[key] = .idle }
        for key in objectKeys {
            if isPending(tablesState[key]) { tablesState[key] = .idle }
            if isPending(routinesState[key]) { routinesState[key] = .idle }
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

    /// Always routes through a scoped driver. Reusing the session driver when the target
    /// looked like the browsed database used to be safe; it is not now that a tab's
    /// execution moves that driver without writing session state.
    ///
    /// Every read goes through here rather than reaching for `MetadataConnectionPool`
    /// directly, because only `metadataRoute` knows which engines cannot answer a metadata
    /// read on a second connection.
    private func withDriver<T: Sendable>(
        connectionId: UUID,
        database: String?,
        schema: String? = nil,
        workload: MetadataConnectionPool.Workload = .interactive,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        guard let scope = DatabaseManager.shared.resolvedScope(
            database: database, schema: schema, for: connectionId
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
        connectionId: UUID
    ) -> [ObjectsKey] {
        Array(Set(tableKeys).union(routineKeys)).filter { $0.connectionId == connectionId }
    }
}
