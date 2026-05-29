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

    struct SchemaObjects: Equatable, Sendable {
        var tables: [TableInfo]
        var routines: [RoutineInfo]
    }

    private(set) var databaseList: [UUID: MetadataLoadState<[DatabaseMetadata]>] = [:]
    private(set) var schemaList: [DatabaseKey: MetadataLoadState<[String]>] = [:]
    private(set) var objects: [ObjectsKey: MetadataLoadState<SchemaObjects>] = [:]

    @ObservationIgnored private let databaseDedup = OnceTask<UUID, [DatabaseMetadata]>()
    @ObservationIgnored private let schemaDedup = OnceTask<DatabaseKey, [String]>()
    @ObservationIgnored private let objectsDedup = OnceTask<ObjectsKey, SchemaObjects>()

    @ObservationIgnored private static let logger = Logger(
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

    func objectsState(connectionId: UUID, database: String, schema: String?) -> MetadataLoadState<SchemaObjects> {
        objects[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)] ?? .idle
    }

    func tables(connectionId: UUID, database: String, schema: String?) -> [TableInfo] {
        objects[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)]?.value?.tables ?? []
    }

    func routines(connectionId: UUID, database: String, schema: String?) -> [RoutineInfo] {
        objects[Self.objectsKey(connectionId: connectionId, database: database, schema: schema)]?.value?.routines ?? []
    }

    // MARK: - Loads

    func loadDatabases(connectionId: UUID, databaseType: DatabaseType) async {
        guard isConnected(connectionId) else { return }
        switch databaseListState(for: connectionId) {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        databaseList[connectionId] = .loading
        let systemNames = Set(PluginManager.shared.systemDatabaseNames(for: databaseType))
        do {
            let list = try await databaseDedup.execute(key: connectionId) { [self] in
                try await withDriver(connectionId: connectionId, database: nil) { driver in
                    try await driver.fetchDatabases().sorted().map {
                        DatabaseMetadata.minimal(name: $0, isSystem: systemNames.contains($0))
                    }
                }
            }
            databaseList[connectionId] = .loaded(list)
        } catch is CancellationError {
            if case .loading = databaseList[connectionId] { databaseList[connectionId] = .idle }
        } catch {
            databaseList[connectionId] = .failed(error.localizedDescription)
            Self.logger.warning("databases load failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
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
            let list = try await schemaDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: connectionId, database: database) { driver in
                    try await driver.fetchSchemas()
                }
            }
            schemaList[key] = .loaded(list)
        } catch is CancellationError {
            if case .loading = schemaList[key] { schemaList[key] = .idle }
        } catch {
            schemaList[key] = .failed(error.localizedDescription)
            Self.logger.warning("schemas load failed db=\(database, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func loadObjects(connectionId: UUID, database: String, schema: String?) async {
        guard isConnected(connectionId) else { return }
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        switch objects[key] ?? .idle {
        case .loaded, .loading: return
        case .idle, .failed: break
        }
        objects[key] = .loading
        let normalizedSchema = key.schema
        do {
            let result = try await objectsDedup.execute(key: key) { [self] in
                try await withDriver(connectionId: connectionId, database: database) { driver in
                    async let tables = driver.fetchTables(schema: normalizedSchema)
                    async let procedures = driver.fetchProcedures(schema: normalizedSchema)
                    async let functions = driver.fetchFunctions(schema: normalizedSchema)
                    return SchemaObjects(
                        tables: try await tables,
                        routines: try await procedures + functions
                    )
                }
            }
            objects[key] = .loaded(result)
        } catch is CancellationError {
            if case .loading = objects[key] { objects[key] = .idle }
        } catch {
            objects[key] = .failed(error.localizedDescription)
            Self.logger.warning(
                "objects load failed db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Refresh

    func refreshDatabases(connectionId: UUID, databaseType: DatabaseType) async {
        await databaseDedup.cancel(key: connectionId)
        databaseList.removeValue(forKey: connectionId)
        await loadDatabases(connectionId: connectionId, databaseType: databaseType)
    }

    func refreshSchemas(connectionId: UUID, database: String) async {
        let key = DatabaseKey(connectionId: connectionId, database: database)
        await schemaDedup.cancel(key: key)
        schemaList.removeValue(forKey: key)
        await loadSchemas(connectionId: connectionId, database: database)
    }

    func refreshObjects(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.objectsKey(connectionId: connectionId, database: database, schema: schema)
        await objectsDedup.cancel(key: key)
        objects.removeValue(forKey: key)
        await loadObjects(connectionId: connectionId, database: database, schema: schema)
    }

    // MARK: - Lifecycle

    func handleReconnect(connectionId: UUID) async {
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
        await resetPending(connectionId: connectionId)
    }

    func handleDisconnect(connectionId: UUID) async {
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
        let schemaKeys = schemaList.keys.filter { $0.connectionId == connectionId }
        let objectKeys = objects.keys.filter { $0.connectionId == connectionId }
        await databaseDedup.cancel(key: connectionId)
        for key in schemaKeys { await schemaDedup.cancel(key: key) }
        for key in objectKeys { await objectsDedup.cancel(key: key) }
        databaseList.removeValue(forKey: connectionId)
        schemaList = schemaList.filter { $0.key.connectionId != connectionId }
        objects = objects.filter { $0.key.connectionId != connectionId }
    }

    // MARK: - Private

    private func resetPending(connectionId: UUID) async {
        let schemaKeys = schemaList.keys.filter { $0.connectionId == connectionId }
        let objectKeys = objects.keys.filter { $0.connectionId == connectionId }

        if isPending(databaseList[connectionId]) {
            await databaseDedup.cancel(key: connectionId)
        }
        for key in schemaKeys where isPending(schemaList[key]) {
            await schemaDedup.cancel(key: key)
        }
        for key in objectKeys where isPending(objects[key]) {
            await objectsDedup.cancel(key: key)
        }

        if isPending(databaseList[connectionId]) { databaseList[connectionId] = .idle }
        for key in schemaKeys where isPending(schemaList[key]) { schemaList[key] = .idle }
        for key in objectKeys where isPending(objects[key]) { objects[key] = .idle }
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
}
