//
//  SchemaService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

@MainActor
@Observable
final class SchemaService {
    static let shared = SchemaService()

    private func holder(_ connectionId: UUID) -> SchemaConnectionState {
        SchemaConnectionState.forConnection(connectionId)
    }

    @ObservationIgnored private let loadDedup = OnceTask<UUID, [TableInfo]>()
    @ObservationIgnored private let procedureDedup = OnceTask<UUID, [RoutineInfo]>()
    @ObservationIgnored private let functionDedup = OnceTask<UUID, [RoutineInfo]>()
    @ObservationIgnored private let schemasDedup = OnceTask<UUID, [String]>()
    @ObservationIgnored private let perSchemaDedup = OnceTask<SchemaKey, [TableInfo]>()

    struct SchemaKey: Hashable, Sendable {
        let connectionId: UUID
        let schema: String
    }
    @ObservationIgnored private var schemaChangeCancellable: AnyCancellable?
    @ObservationIgnored private var loadGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var nextLoadGeneration = 0
    @ObservationIgnored private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaService")

    init() {
        schemaChangeCancellable = AppEvents.shared.currentSchemaChanged
            .sink { [weak self] connectionId in
                Task { @MainActor [weak self] in
                    await self?.handleSchemaSwitch(connectionId: connectionId)
                }
            }
    }

    func state(for connectionId: UUID) -> SchemaState {
        holder(connectionId).state
    }

    func tables(for connectionId: UUID) -> [TableInfo] {
        holder(connectionId).tables
    }

    func procedures(for connectionId: UUID) -> [RoutineInfo] {
        holder(connectionId).procedures
    }

    func functions(for connectionId: UUID) -> [RoutineInfo] {
        holder(connectionId).functions
    }

    func routines(for connectionId: UUID) -> [RoutineInfo] {
        procedures(for: connectionId) + functions(for: connectionId)
    }

    func schemas(for connectionId: UUID) -> [String] {
        holder(connectionId).schemasInOrder
    }

    func schemaState(for connectionId: UUID, schema: String) -> SchemaState {
        holder(connectionId).perSchemaState(schema)
    }

    func tables(for connectionId: UUID, schema: String) -> [TableInfo] {
        holder(connectionId).tables(inSchema: schema)
    }

    /// Flat tables plus the union of every loaded per-schema table list. For
    /// hierarchicalSchema plugins the flat list is empty and this is the only
    /// way to see tables across schemas (e.g. for autocomplete).
    func allLoadedTables(for connectionId: UUID) -> [TableInfo] {
        holder(connectionId).allLoadedTables
    }

    func loadSchemaTables(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        if case .loaded = schemaState(for: connectionId, schema: schema) { return }
        holder(connectionId).setPerSchemaState(.loading, schema: schema)
        do {
            let tables = try await perSchemaDedup.execute(key: SchemaKey(connectionId: connectionId, schema: schema)) {
                try await driver.fetchTables(schema: schema)
            }
            holder(connectionId).setPerSchemaState(.loaded(tables), schema: schema)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] per-schema load failed connId=\(connectionId, privacy: .public) schema=\(schema, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            holder(connectionId).setPerSchemaState(.failed(error.localizedDescription), schema: schema)
        }
    }

    func reloadSchemaTables(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        await perSchemaDedup.cancel(key: SchemaKey(connectionId: connectionId, schema: schema))
        holder(connectionId).clearPerSchemaState(schema: schema)
        await loadSchemaTables(connectionId: connectionId, schema: schema, driver: driver)
    }

    func load(connectionId: UUID, driver: DatabaseDriver, connection: DatabaseConnection) async {
        switch state(for: connectionId) {
        case .loaded:
            return
        case .idle, .loading, .failed:
            await runLoad(connectionId: connectionId, driver: driver, connection: connection)
        }
    }

    func reload(connectionId: UUID, driver: DatabaseDriver, connection: DatabaseConnection) async {
        await runLoad(connectionId: connectionId, driver: driver, connection: connection)
    }

    func reloadProcedures(connectionId: UUID, driver: DatabaseDriver) async {
        do {
            let routines = try await procedureDedup.execute(key: connectionId) {
                try await driver.fetchProcedures(schema: nil)
            }
            holder(connectionId).setProcedures(routines)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] procedures reload failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func reloadFunctions(connectionId: UUID, driver: DatabaseDriver) async {
        do {
            let routines = try await functionDedup.execute(key: connectionId) {
                try await driver.fetchFunctions(schema: nil)
            }
            holder(connectionId).setFunctions(routines)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] functions reload failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func invalidate(connectionId: UUID) async {
        await loadDedup.cancel(key: connectionId)
        await procedureDedup.cancel(key: connectionId)
        await functionDedup.cancel(key: connectionId)
        await schemasDedup.cancel(key: connectionId)
        for schema in holder(connectionId).loadedSchemaNames() {
            await perSchemaDedup.cancel(key: SchemaKey(connectionId: connectionId, schema: schema))
        }
        loadGenerations.removeValue(forKey: connectionId)
        holder(connectionId).reset()
    }

    func refresh(connectionId: UUID) async {
        guard let session = DatabaseManager.shared.activeSessions[connectionId],
              let driver = session.driver else {
            markLoadFailed(
                connectionId: connectionId,
                message: String(localized: "The connection is not available. Reconnect and try again.")
            )
            return
        }
        await invalidate(connectionId: connectionId)
        await reload(connectionId: connectionId, driver: driver, connection: session.connection)
    }

    func markLoadFailed(connectionId: UUID, message: String) {
        if case .loaded = state(for: connectionId) { return }
        holder(connectionId).setState(.failed(message))
    }

    private func runLoad(
        connectionId: UUID,
        driver: DatabaseDriver,
        connection: DatabaseConnection
    ) async {
        let generation = beginLoadGeneration(for: connectionId)
        holder(connectionId).setState(.loading)

        let supportsSchemas = PluginManager.shared.supportsSchemaSwitching(for: connection.type)
        if !supportsSchemas {
            holder(connectionId).clearSchemasInOrder()
        }

        let grouping = PluginManager.shared.databaseGroupingStrategy(for: connection.type)
        if grouping == .hierarchicalSchema {
            await runHierarchicalLoad(connectionId: connectionId, driver: driver, generation: generation)
            return
        }

        async let tablesTask: [TableInfo] = loadDedup.execute(key: connectionId) {
            try await driver.fetchTables()
        }
        async let proceduresTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            connectionId: connectionId,
            kind: .procedure,
            dedup: procedureDedup,
            fetch: { try await driver.fetchProcedures(schema: nil) }
        )
        async let functionsTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            connectionId: connectionId,
            kind: .function,
            dedup: functionDedup,
            fetch: { try await driver.fetchFunctions(schema: nil) }
        )
        async let schemasTask: [String]? = supportsSchemas
            ? Self.fetchSchemasSafely(
                connectionId: connectionId,
                dedup: schemasDedup,
                fetch: { try await driver.fetchSchemas() }
            )
            : nil

        do {
            let tables = try await tablesTask
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "tables-loaded") else {
                return
            }
            holder(connectionId).setState(.loaded(tables))

            let loadedProcedures = await proceduresTask
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "procedures-loaded") else {
                return
            }
            holder(connectionId).setProcedures(loadedProcedures)

            let loadedFunctions = await functionsTask
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "functions-loaded") else {
                return
            }
            holder(connectionId).setFunctions(loadedFunctions)

            if let loadedSchemas = await schemasTask {
                guard isCurrentLoadGeneration(generation, for: connectionId, phase: "schemas-loaded") else {
                    return
                }
                holder(connectionId).setSchemasInOrder(loadedSchemas)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "tables-failed") else {
                if loadGenerations[connectionId] == nil, case .loading = state(for: connectionId) {
                    holder(connectionId).setState(.idle)
                }
                return
            }
            Self.logger.warning(
                "[schema] load failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            holder(connectionId).setState(.failed(error.localizedDescription))
        }
    }

    private func runHierarchicalLoad(connectionId: UUID, driver: DatabaseDriver, generation: Int) async {
        async let proceduresTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            connectionId: connectionId,
            kind: .procedure,
            dedup: procedureDedup,
            fetch: { try await driver.fetchProcedures(schema: nil) }
        )
        async let functionsTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            connectionId: connectionId,
            kind: .function,
            dedup: functionDedup,
            fetch: { try await driver.fetchFunctions(schema: nil) }
        )

        let loadedProcedures = await proceduresTask
        let loadedFunctions = await functionsTask

        let loadedSchemas: [String]
        do {
            loadedSchemas = try await schemasDedup.execute(key: connectionId) {
                try await driver.fetchSchemas()
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "hierarchical-failed") else {
                return
            }
            Self.logger.warning(
                "[schema] hierarchical schema list failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            holder(connectionId).setState(.failed(error.localizedDescription))
            return
        }

        guard isCurrentLoadGeneration(generation, for: connectionId, phase: "hierarchical-loaded") else {
            return
        }
        holder(connectionId).setSchemasInOrder(loadedSchemas)
        holder(connectionId).setProcedures(loadedProcedures)
        holder(connectionId).setFunctions(loadedFunctions)
        holder(connectionId).setState(.loaded([]))
    }

    private func beginLoadGeneration(for connectionId: UUID) -> Int {
        nextLoadGeneration += 1
        let generation = nextLoadGeneration
        if case .loading = state(for: connectionId) {
            let previousGeneration = loadGenerations[connectionId] ?? 0
            Self.logger.debug(
                "[schema] superseding in-flight load connId=\(connectionId, privacy: .public) previousGeneration=\(previousGeneration) newGeneration=\(generation)"
            )
        }
        loadGenerations[connectionId] = generation
        return generation
    }

    private func isCurrentLoadGeneration(
        _ generation: Int,
        for connectionId: UUID,
        phase: String
    ) -> Bool {
        guard loadGenerations[connectionId] == generation else {
            let currentGeneration = loadGenerations[connectionId] ?? 0
            Self.logger.debug(
                "[schema] stale load transition ignored connId=\(connectionId, privacy: .public) phase=\(phase, privacy: .public) generation=\(generation) currentGeneration=\(currentGeneration)"
            )
            return false
        }
        return true
    }

    private static func fetchSchemasSafely(
        connectionId: UUID,
        dedup: OnceTask<UUID, [String]>,
        fetch: @Sendable @escaping () async throws -> [String]
    ) async -> [String]? {
        do {
            return try await dedup.execute(key: connectionId, work: fetch)
        } catch is CancellationError {
            return nil
        } catch {
            Self.logger.warning(
                "[schema] fetchSchemas failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func fetchRoutinesSafely(
        connectionId: UUID,
        kind: RoutineInfo.Kind,
        dedup: OnceTask<UUID, [RoutineInfo]>,
        fetch: @Sendable @escaping () async throws -> [RoutineInfo]
    ) async -> [RoutineInfo] {
        do {
            return try await dedup.execute(key: connectionId, work: fetch)
        } catch is CancellationError {
            return []
        } catch {
            logger.warning(
                "[schema] \(kind.rawValue, privacy: .public) load failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private func handleSchemaSwitch(connectionId: UUID) async {
        guard let session = DatabaseManager.shared.activeSessions[connectionId],
              let driver = session.driver else { return }
        let connection = session.connection
        if PluginManager.shared.databaseGroupingStrategy(for: connection.type) == .hierarchicalSchema {
            await invalidate(connectionId: connectionId)
            await reload(connectionId: connectionId, driver: driver, connection: connection)
            return
        }
        await reloadCurrentSchemaContent(connectionId: connectionId, driver: driver)
    }

    private func reloadCurrentSchemaContent(connectionId: UUID, driver: DatabaseDriver) async {
        await loadDedup.cancel(key: connectionId)
        await procedureDedup.cancel(key: connectionId)
        await functionDedup.cancel(key: connectionId)

        holder(connectionId).setState(.loading)

        async let proceduresTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            connectionId: connectionId,
            kind: .procedure,
            dedup: procedureDedup,
            fetch: { try await driver.fetchProcedures(schema: nil) }
        )
        async let functionsTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            connectionId: connectionId,
            kind: .function,
            dedup: functionDedup,
            fetch: { try await driver.fetchFunctions(schema: nil) }
        )

        let loadedProcedures = await proceduresTask
        let loadedFunctions = await functionsTask

        do {
            let tables = try await loadDedup.execute(key: connectionId) {
                try await driver.fetchTables()
            }
            holder(connectionId).setState(.loaded(tables))
            holder(connectionId).setProcedures(loadedProcedures)
            holder(connectionId).setFunctions(loadedFunctions)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] current-schema reload failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            holder(connectionId).setState(.failed(error.localizedDescription))
        }
    }
}
