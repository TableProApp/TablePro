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

    struct TableKey: Hashable, Sendable {
        let connectionId: UUID
        let database: String
        let schema: String?
    }

    enum DatabaseListState: Equatable, Sendable {
        case idle
        case loading
        case loaded([DatabaseMetadata])
        case failed(String)
    }

    enum SchemaListState: Equatable, Sendable {
        case idle
        case loading
        case loaded([String])
        case failed(String)
    }

    private(set) var databaseListStates: [UUID: DatabaseListState] = [:]
    private(set) var schemaListStates: [DatabaseKey: SchemaListState] = [:]
    private(set) var tableStates: [TableKey: SchemaState] = [:]
    private(set) var routineLists: [TableKey: [RoutineInfo]] = [:]

    @ObservationIgnored private let databaseListDedup = OnceTask<UUID, [DatabaseMetadata]>()
    @ObservationIgnored private let schemaListDedup = OnceTask<DatabaseKey, [String]>()
    @ObservationIgnored private let tableDedup = OnceTask<TableKey, [TableInfo]>()
    @ObservationIgnored private let routineDedup = OnceTask<TableKey, [RoutineInfo]>()

    @ObservationIgnored private static let logger = Logger(
        subsystem: "com.TablePro", category: "SidebarTree"
    )

    private init() {}

    func databaseListState(for connectionId: UUID) -> DatabaseListState {
        databaseListStates[connectionId] ?? .idle
    }

    func databases(for connectionId: UUID) -> [DatabaseMetadata] {
        if case .loaded(let list) = databaseListState(for: connectionId) {
            return list
        }
        return []
    }

    func schemaListState(connectionId: UUID, database: String) -> SchemaListState {
        if database == activeDatabase(for: connectionId) {
            let schemas = SchemaService.shared.schemas(for: connectionId)
            if !schemas.isEmpty {
                return .loaded(schemas)
            }
            switch SchemaService.shared.state(for: connectionId) {
            case .idle: return .idle
            case .loading: return .loading
            case .failed(let message): return .failed(message)
            case .loaded: return .loaded(schemas)
            }
        }
        return schemaListStates[DatabaseKey(connectionId: connectionId, database: database)] ?? .idle
    }

    func schemas(connectionId: UUID, database: String) -> [String] {
        if case .loaded(let list) = schemaListState(connectionId: connectionId, database: database) {
            return list
        }
        return []
    }

    func tableState(connectionId: UUID, database: String, schema: String?) -> SchemaState {
        if database == activeDatabase(for: connectionId) {
            if let schema {
                return SchemaService.shared.schemaState(for: connectionId, schema: schema)
            }
            return SchemaService.shared.state(for: connectionId)
        }
        return tableStates[Self.tableKey(
            connectionId: connectionId, database: database, schema: schema
        )] ?? .idle
    }

    func tables(connectionId: UUID, database: String, schema: String?) -> [TableInfo] {
        if database == activeDatabase(for: connectionId) {
            if let schema {
                return SchemaService.shared.tables(for: connectionId, schema: schema)
            }
            return SchemaService.shared.tables(for: connectionId)
        }
        if case .loaded(let list) = tableState(
            connectionId: connectionId, database: database, schema: schema
        ) {
            return list
        }
        return []
    }

    func routines(connectionId: UUID, database: String, schema: String?) -> [RoutineInfo] {
        routineLists[Self.tableKey(connectionId: connectionId, database: database, schema: schema)] ?? []
    }

    func loadDatabaseList(connectionId: UUID, driver: DatabaseDriver, databaseType: DatabaseType) async {
        Self.logger.debug(
            "loadDatabaseList enter connId=\(connectionId, privacy: .public) type=\(databaseType.rawValue, privacy: .public) state=\(Self.label(self.databaseListState(for: connectionId)), privacy: .public) driver=\(driver.status.label, privacy: .public)"
        )
        if case .loaded = databaseListState(for: connectionId) {
            Self.logger.debug("loadDatabaseList skip-loaded connId=\(connectionId, privacy: .public)")
            return
        }
        databaseListStates[connectionId] = .loading
        let systemNames = Set(PluginManager.shared.systemDatabaseNames(for: databaseType))
        do {
            let list = try await databaseListDedup.execute(key: connectionId) {
                let names = try await driver.fetchDatabases()
                return names.sorted().map { name in
                    DatabaseMetadata.minimal(name: name, isSystem: systemNames.contains(name))
                }
            }
            databaseListStates[connectionId] = .loaded(list)
            Self.logger.debug(
                "loadDatabaseList loaded connId=\(connectionId, privacy: .public) count=\(list.count, privacy: .public)"
            )
        } catch is CancellationError {
            Self.logger.debug("loadDatabaseList cancelled connId=\(connectionId, privacy: .public)")
            return
        } catch {
            Self.logger.warning(
                "loadDatabaseList failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            databaseListStates[connectionId] = .failed(error.localizedDescription)
        }
    }

    func reloadDatabaseList(connectionId: UUID, driver: DatabaseDriver, databaseType: DatabaseType) async {
        Self.logger.debug("reloadDatabaseList connId=\(connectionId, privacy: .public)")
        await databaseListDedup.cancel(key: connectionId)
        databaseListStates.removeValue(forKey: connectionId)
        await loadDatabaseList(
            connectionId: connectionId, driver: driver, databaseType: databaseType
        )
    }

    func loadSchemaList(connectionId: UUID, database: String) async {
        let active = activeDatabase(for: connectionId)
        Self.logger.debug(
            "loadSchemaList enter connId=\(connectionId, privacy: .public) db=\(database, privacy: .public) active=\(active ?? "nil", privacy: .public)"
        )
        if database == active {
            Self.logger.debug("loadSchemaList skip-active db=\(database, privacy: .public)")
            return
        }
        if isConnecting(connectionId) {
            Self.logger.debug("loadSchemaList skip-connecting db=\(database, privacy: .public)")
            return
        }
        let key = DatabaseKey(connectionId: connectionId, database: database)
        if case .loaded = schemaListStates[key] {
            Self.logger.debug("loadSchemaList skip-loaded db=\(database, privacy: .public)")
            return
        }
        schemaListStates[key] = .loading
        do {
            let list = try await schemaListDedup.execute(key: key) {
                try await MetadataConnectionPool.shared.withDriver(
                    connectionId: connectionId, database: database
                ) { driver in
                    try await driver.fetchSchemas()
                }
            }
            schemaListStates[key] = .loaded(list)
            Self.logger.debug(
                "loadSchemaList loaded db=\(database, privacy: .public) count=\(list.count, privacy: .public)"
            )
        } catch is CancellationError {
            Self.logger.debug("loadSchemaList cancelled db=\(database, privacy: .public)")
            return
        } catch {
            Self.logger.warning(
                "loadSchemaList failed connId=\(connectionId, privacy: .public) db=\(database, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            schemaListStates[key] = .failed(error.localizedDescription)
        }
    }

    func loadTables(connectionId: UUID, database: String, schema: String?) async {
        let active = activeDatabase(for: connectionId)
        let isActive = database == active
        Self.logger.debug(
            "loadTables enter connId=\(connectionId, privacy: .public) db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) active=\(active ?? "nil", privacy: .public) isActive=\(isActive, privacy: .public) driver=\(self.driverStatusLabel(connectionId), privacy: .public)"
        )
        if isConnecting(connectionId) {
            Self.logger.debug(
                "loadTables skip-connecting db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
            )
            return
        }
        if isActive {
            guard let session = DatabaseManager.shared.session(for: connectionId),
                  let driver = session.driver else {
                Self.logger.debug(
                    "loadTables active-skip-no-driver db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
                )
                return
            }
            if let schema {
                Self.logger.debug(
                    "loadTables active->loadSchemaTables schema=\(schema, privacy: .public) before=\(SchemaService.shared.schemaState(for: connectionId, schema: schema).label, privacy: .public)"
                )
                await SchemaService.shared.loadSchemaTables(
                    connectionId: connectionId, schema: schema, driver: driver
                )
                Self.logger.debug(
                    "loadTables active->loadSchemaTables done schema=\(schema, privacy: .public) after=\(SchemaService.shared.schemaState(for: connectionId, schema: schema).label, privacy: .public)"
                )
            } else if case .idle = SchemaService.shared.state(for: connectionId) {
                Self.logger.debug("loadTables active->SchemaService.load db=\(database, privacy: .public)")
                await SchemaService.shared.load(
                    connectionId: connectionId, driver: driver, connection: session.connection
                )
            }
            await loadRoutines(connectionId: connectionId, database: database, schema: schema)
            return
        }
        let key = Self.tableKey(connectionId: connectionId, database: database, schema: schema)
        if case .loaded = tableStates[key] {
            Self.logger.debug(
                "loadTables nonactive-skip-loaded db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
            )
            await loadRoutines(connectionId: connectionId, database: database, schema: schema)
            return
        }
        tableStates[key] = .loading
        do {
            let normalizedSchema = key.schema
            let list = try await tableDedup.execute(key: key) {
                try await MetadataConnectionPool.shared.withDriver(
                    connectionId: connectionId, database: database
                ) { driver in
                    try await driver.fetchTables(schema: normalizedSchema)
                }
            }
            tableStates[key] = .loaded(list)
            Self.logger.debug(
                "loadTables nonactive-loaded db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) count=\(list.count, privacy: .public)"
            )
        } catch is CancellationError {
            Self.logger.debug(
                "loadTables nonactive-cancelled db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
            )
            return
        } catch {
            Self.logger.warning(
                "loadTables nonactive-failed connId=\(connectionId, privacy: .public) db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            tableStates[key] = .failed(error.localizedDescription)
            return
        }
        await loadRoutines(connectionId: connectionId, database: database, schema: schema)
    }

    func loadRoutines(connectionId: UUID, database: String, schema: String?) async {
        let key = Self.tableKey(connectionId: connectionId, database: database, schema: schema)
        if routineLists[key] != nil {
            Self.logger.debug(
                "loadRoutines skip-loaded db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
            )
            return
        }
        if isConnecting(connectionId) {
            Self.logger.debug(
                "loadRoutines skip-connecting db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
            )
            return
        }
        let normalizedSchema = key.schema
        let isActive = database == activeDatabase(for: connectionId)
        let activeSessionDriver = isActive ? DatabaseManager.shared.session(for: connectionId)?.driver : nil
        if isActive, activeSessionDriver == nil {
            Self.logger.debug(
                "loadRoutines active-skip-no-driver db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
            )
            return
        }
        do {
            let list = try await routineDedup.execute(key: key) {
                if let activeSessionDriver {
                    return try await Self.fetchRoutines(driver: activeSessionDriver, schema: normalizedSchema)
                }
                return try await MetadataConnectionPool.shared.withDriver(
                    connectionId: connectionId, database: database
                ) { driver in
                    try await Self.fetchRoutines(driver: driver, schema: normalizedSchema)
                }
            }
            routineLists[key] = list
            Self.logger.debug(
                "loadRoutines loaded db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) count=\(list.count, privacy: .public)"
            )
        } catch is CancellationError {
            Self.logger.debug(
                "loadRoutines cancelled db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
            )
            return
        } catch {
            Self.logger.warning(
                "loadRoutines failed connId=\(connectionId, privacy: .public) db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            routineLists[key] = []
        }
    }

    private static func fetchRoutines(driver: DatabaseDriver, schema: String?) async throws -> [RoutineInfo] {
        async let procedures = driver.fetchProcedures(schema: schema)
        async let functions = driver.fetchFunctions(schema: schema)
        return try await procedures + functions
    }

    func reloadTables(connectionId: UUID, database: String, schema: String?) async {
        Self.logger.debug(
            "reloadTables connId=\(connectionId, privacy: .public) db=\(database, privacy: .public) schema=\(schema ?? "nil", privacy: .public)"
        )
        let key = Self.tableKey(connectionId: connectionId, database: database, schema: schema)
        await routineDedup.cancel(key: key)
        routineLists.removeValue(forKey: key)
        if database == activeDatabase(for: connectionId) {
            guard let session = DatabaseManager.shared.session(for: connectionId),
                  let driver = session.driver else { return }
            if let schema {
                await SchemaService.shared.reloadSchemaTables(
                    connectionId: connectionId, schema: schema, driver: driver
                )
            } else {
                await SchemaService.shared.reload(
                    connectionId: connectionId, driver: driver, connection: session.connection
                )
            }
            await loadRoutines(connectionId: connectionId, database: database, schema: schema)
            return
        }
        await tableDedup.cancel(key: key)
        tableStates.removeValue(forKey: key)
        await loadTables(connectionId: connectionId, database: database, schema: schema)
    }

    func refreshDatabase(connectionId: UUID, database: String) async {
        Self.logger.debug(
            "refreshDatabase connId=\(connectionId, privacy: .public) db=\(database, privacy: .public)"
        )
        if database == activeDatabase(for: connectionId) {
            await SchemaService.shared.refresh(connectionId: connectionId)
            return
        }
        await invalidateDatabase(connectionId: connectionId, database: database)
    }

    func invalidate(connectionId: UUID) async {
        Self.logger.debug("invalidate connId=\(connectionId, privacy: .public)")
        await databaseListDedup.cancel(key: connectionId)
        databaseListStates.removeValue(forKey: connectionId)
        await invalidatePerDatabaseCaches(connectionId: connectionId)
    }

    func invalidateForReconnect(connectionId: UUID) async {
        Self.logger.debug("invalidateForReconnect connId=\(connectionId, privacy: .public)")
        await invalidatePerDatabaseCaches(connectionId: connectionId)
    }

    private func invalidatePerDatabaseCaches(connectionId: UUID) async {
        let dbKeys = schemaListStates.keys.filter { $0.connectionId == connectionId }
        let tableKeys = tableStates.keys.filter { $0.connectionId == connectionId }
        let routineKeys = routineLists.keys.filter { $0.connectionId == connectionId }
        Self.logger.debug(
            "invalidatePerDatabaseCaches connId=\(connectionId, privacy: .public) schemaLists=\(dbKeys.count, privacy: .public) tableStates=\(tableKeys.count, privacy: .public) routineLists=\(routineKeys.count, privacy: .public)"
        )
        for key in dbKeys {
            await schemaListDedup.cancel(key: key)
            schemaListStates.removeValue(forKey: key)
        }
        for key in tableKeys {
            await tableDedup.cancel(key: key)
            tableStates.removeValue(forKey: key)
        }
        for key in routineKeys {
            await routineDedup.cancel(key: key)
            routineLists.removeValue(forKey: key)
        }

        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
    }

    func invalidateDatabase(connectionId: UUID, database: String) async {
        Self.logger.debug(
            "invalidateDatabase connId=\(connectionId, privacy: .public) db=\(database, privacy: .public)"
        )
        let dbKey = DatabaseKey(connectionId: connectionId, database: database)
        await schemaListDedup.cancel(key: dbKey)
        schemaListStates.removeValue(forKey: dbKey)

        let tableKeys = tableStates.keys.filter {
            $0.connectionId == connectionId && $0.database == database
        }
        for key in tableKeys {
            await tableDedup.cancel(key: key)
            tableStates.removeValue(forKey: key)
        }

        let routineKeys = routineLists.keys.filter {
            $0.connectionId == connectionId && $0.database == database
        }
        for key in routineKeys {
            await routineDedup.cancel(key: key)
            routineLists.removeValue(forKey: key)
        }

        MetadataConnectionPool.shared.invalidate(connectionId: connectionId, database: database)
    }

    private func activeDatabase(for connectionId: UUID) -> String? {
        guard let session = DatabaseManager.shared.session(for: connectionId) else { return nil }
        let value = session.activeDatabase
        return value.isEmpty ? nil : value
    }

    private func isConnecting(_ connectionId: UUID) -> Bool {
        DatabaseManager.shared.session(for: connectionId)?.status == .connecting
    }

    private func driverStatusLabel(_ connectionId: UUID) -> String {
        DatabaseManager.shared.session(for: connectionId)?.driver?.status.label ?? "noDriver"
    }

    private static func label(_ state: DatabaseListState) -> String {
        switch state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded(let list): return "loaded(\(list.count))"
        case .failed: return "failed"
        }
    }

    private static func tableKey(connectionId: UUID, database: String, schema: String?) -> TableKey {
        let normalized: String? = (schema?.isEmpty == true) ? nil : schema
        return TableKey(connectionId: connectionId, database: database, schema: normalized)
    }
}

extension SchemaState {
    var label: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded(let tables): return "loaded(\(tables.count))"
        case .failed: return "failed"
        }
    }
}

extension ConnectionStatus {
    var label: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error: return "error"
        }
    }
}
