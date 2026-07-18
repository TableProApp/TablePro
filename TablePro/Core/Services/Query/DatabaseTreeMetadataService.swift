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

    private func holder(_ connectionId: UUID) -> DatabaseTreeConnectionState {
        DatabaseTreeConnectionState.forConnection(connectionId)
    }

    @ObservationIgnored private let databaseDedup = OnceTask<UUID, [DatabaseMetadata]>()
    @ObservationIgnored private let schemaDedup = OnceTask<DatabaseKey, [String]>()
    @ObservationIgnored private let tablesDedup = OnceTask<ObjectsKey, [TableInfo]>()
    @ObservationIgnored private let routinesDedup = OnceTask<ObjectsKey, [RoutineInfo]>()

    @ObservationIgnored private static let logger = Logger(
        subsystem: "com.TablePro", category: "SidebarTree"
    )

    private init() {}

    // MARK: - Reads

    func databaseListState(for connectionId: UUID) -> MetadataLoadState<[DatabaseMetadata]> {
        holder(connectionId).databaseList
    }

    func databases(for connectionId: UUID) -> [DatabaseMetadata] {
        holder(connectionId).databaseList.value ?? []
    }

    func schemaListState(connectionId: UUID, database: String) -> MetadataLoadState<[String]> {
        holder(connectionId).schemaList[DatabaseKey(connectionId: connectionId, database: database)] ?? .idle
    }

    func schemas(connectionId: UUID, database: String) -> [String] {
        holder(connectionId).schemaList[DatabaseKey(connectionId: connectionId, database: database)]?.value ?? []
    }

    func tablesLoadState(connectionId: UUID, database: String, schema: String?) -> MetadataLoadState<[TableInfo]> {
        holder(connectionId).tablesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)] ?? .idle
    }

    func routinesLoadState(connectionId: UUID, database: String, schema: String?) -> MetadataLoadState<[RoutineInfo]> {
        holder(connectionId).routinesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)] ?? .idle
    }

    func tables(connectionId: UUID, database: String, schema: String?) -> [TableInfo] {
        holder(connectionId).tablesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)]?.value ?? []
    }

    func routines(connectionId: UUID, database: String, schema: String?) -> [RoutineInfo] {
        holder(connectionId).routinesState[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)]?.value ?? []
    }

    // MARK: - Loads

    func loadDatabases(connectionId: UUID, databaseType: DatabaseType) async {
        guard isConnected(connectionId) else { return }
        switch databaseListState(for: connectionId) {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        holder(connectionId).setDatabaseList(.loading)
        let systemNames = Set(PluginManager.shared.systemDatabaseNames(for: databaseType))
        do {
            let list = try await databaseDedup.execute(key: connectionId) { [self] in
                try await withDriver(connectionId: connectionId, database: nil) { driver in
                    try await driver.fetchDatabases().sorted().map {
                        DatabaseMetadata.minimal(name: $0, isSystem: systemNames.contains($0))
                    }
                }
            }
            holder(connectionId).setDatabaseList(.loaded(list))
        } catch is CancellationError {
            if case .loading = holder(connectionId).databaseList { holder(connectionId).setDatabaseList(.idle) }
        } catch {
            holder(connectionId).setDatabaseList(.failed(error.localizedDescription))
            Self.logger.warning("databases load failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func loadSchemas(connectionId: UUID, database: String) async {
        guard isConnected(connectionId) else { return }
        let key = DatabaseKey(connectionId: connectionId, database: database)
        switch holder(connectionId).schemaList[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        holder(connectionId).setSchemaList(.loading, key: key)
        do {
            let list = try await schemaDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: connectionId, database: database) { driver in
                    try await driver.fetchSchemas()
                }
            }
            holder(connectionId).setSchemaList(.loaded(list), key: key)
        } catch is CancellationError {
            if case .loading = holder(connectionId).schemaList[key] { holder(connectionId).setSchemaList(.idle, key: key) }
        } catch {
            holder(connectionId).setSchemaList(.failed(error.localizedDescription), key: key)
            Self.logger.warning("schemas load failed db=\(database, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func loadTables(connectionId: UUID, database: String, schema: String?) async {
        guard isConnected(connectionId) else { return }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        switch holder(connectionId).tablesState[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        holder(connectionId).setTablesState(.loading, key: key)
        let normalizedSchema = key.schema
        do {
            let list = try await tablesDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: connectionId, database: database) { driver in
                    try await driver.fetchTables(schema: normalizedSchema)
                }
            }
            holder(connectionId).setTablesState(.loaded(list), key: key)
        } catch is CancellationError {
            if case .loading = holder(connectionId).tablesState[key] { holder(connectionId).setTablesState(.idle, key: key) }
        } catch {
            holder(connectionId).setTablesState(.failed(error.localizedDescription), key: key)
            Self.logger.warning(
                "tables load failed db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func loadRoutines(connectionId: UUID, database: String, schema: String?) async {
        guard isConnected(connectionId) else { return }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        switch holder(connectionId).routinesState[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        holder(connectionId).setRoutinesState(.loading, key: key)
        let normalizedSchema = key.schema
        do {
            let list = try await routinesDedup.execute(key: key) { [self] in
                try await MetadataConnectionPool.shared.withDriver(
                    connectionId: connectionId,
                    database: database,
                    schema: normalizedSchema,
                    workload: .bulk
                ) { driver in
                    let procedures = try await driver.fetchProcedures(schema: normalizedSchema)
                    let functions = try await driver.fetchFunctions(schema: normalizedSchema)
                    return procedures + functions
                }
            }
            holder(connectionId).setRoutinesState(.loaded(list), key: key)
        } catch is CancellationError {
            if case .loading = holder(connectionId).routinesState[key] { holder(connectionId).setRoutinesState(.idle, key: key) }
        } catch {
            holder(connectionId).setRoutinesState(.failed(error.localizedDescription), key: key)
            Self.logger.warning(
                "routines load failed db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Refresh

    func refreshDatabases(connectionId: UUID, databaseType: DatabaseType) async {
        await databaseDedup.cancel(key: connectionId)
        holder(connectionId).setDatabaseList(.idle)
        await loadDatabases(connectionId: connectionId, databaseType: databaseType)
    }

    func refreshSchemas(connectionId: UUID, database: String) async {
        let key = DatabaseKey(connectionId: connectionId, database: database)
        await schemaDedup.cancel(key: key)
        holder(connectionId).removeSchemaList(key: key)
        await loadSchemas(connectionId: connectionId, database: database)
    }

    func refreshObjects(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        await tablesDedup.cancel(key: key)
        await routinesDedup.cancel(key: key)
        holder(connectionId).removeTablesState(key: key)
        holder(connectionId).removeRoutinesState(key: key)
        async let tables = loadTables(connectionId: connectionId, database: database, schema: schema)
        async let routines = loadRoutines(connectionId: connectionId, database: database, schema: schema)
        _ = await (tables, routines)
    }

    func refreshLoadedTables(connectionId: UUID, database: String? = nil) async {
        let keys = holder(connectionId).tablesState.keys.filter { key in
            database == nil || key.database == database
        }
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { @MainActor in
                    await self.reloadTablesInPlace(key)
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
            guard holder(key.connectionId).tablesState[key] != next else { return }
            holder(key.connectionId).setTablesState(next, key: key)
        } catch is CancellationError {
        } catch {
            Self.logger.warning(
                "tables refresh failed db=\(key.database, privacy: .public) schema=\(key.schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Lifecycle

    func handleReconnect(connectionId: UUID) async {
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
        await resetPending(connectionId: connectionId)
    }

    func handleDisconnect(connectionId: UUID) async {
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
        let state = holder(connectionId)
        let schemaKeys = Array(state.schemaList.keys)
        let objectKeys = Self.connectionObjectKeys(
            tableKeys: state.tablesState.keys, routineKeys: state.routinesState.keys, connectionId: connectionId
        )
        await databaseDedup.cancel(key: connectionId)
        for key in schemaKeys { await schemaDedup.cancel(key: key) }
        for key in objectKeys {
            await tablesDedup.cancel(key: key)
            await routinesDedup.cancel(key: key)
        }
        state.reset()
        DatabaseTreeConnectionState.removeConnection(connectionId)
    }

    // MARK: - Private

    private func resetPending(connectionId: UUID) async {
        let state = holder(connectionId)
        let schemaKeys = Array(state.schemaList.keys)
        let objectKeys = Self.connectionObjectKeys(
            tableKeys: state.tablesState.keys, routineKeys: state.routinesState.keys, connectionId: connectionId
        )

        if isPending(state.databaseList) {
            await databaseDedup.cancel(key: connectionId)
        }
        for key in schemaKeys where isPending(state.schemaList[key]) {
            await schemaDedup.cancel(key: key)
        }
        for key in objectKeys {
            if isPending(state.tablesState[key]) { await tablesDedup.cancel(key: key) }
            if isPending(state.routinesState[key]) { await routinesDedup.cancel(key: key) }
        }

        if isPending(state.databaseList) { state.setDatabaseList(.idle) }
        for key in schemaKeys where isPending(state.schemaList[key]) { state.setSchemaList(.idle, key: key) }
        for key in objectKeys {
            if isPending(state.tablesState[key]) { state.setTablesState(.idle, key: key) }
            if isPending(state.routinesState[key]) { state.setRoutinesState(.idle, key: key) }
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

    private func withDriver<T: Sendable>(
        connectionId: UUID,
        database: String?,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        let session = DatabaseManager.shared.session(for: connectionId)
        let usesPrimary = database == nil || database == session?.activeDatabase
        if usesPrimary, let driver = session?.driver, driver.status == .connected {
            return try await body(driver)
        }
        guard let database else { throw DatabaseError.notConnected }
        return try await MetadataConnectionPool.shared.withDriver(
            connectionId: connectionId, database: database, body
        )
    }

    private static func objectsKey(connectionId: UUID, database: String, schema: String?) -> ObjectsKey {
        let normalized: String? = (schema?.isEmpty == true) ? nil : schema
        return ObjectsKey(connectionId: connectionId, database: database, schema: normalized)
    }

    nonisolated static func connectionObjectKeys(
        tableKeys: some Sequence<ObjectsKey>,
        routineKeys: some Sequence<ObjectsKey>,
        connectionId: UUID
    ) -> [ObjectsKey] {
        Array(Set(tableKeys).union(routineKeys)).filter { $0.connectionId == connectionId }
    }
}
