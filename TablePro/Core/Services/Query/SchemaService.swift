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

    private(set) var states: [UUID: SchemaState] = [:]
    private(set) var procedures: [UUID: [RoutineInfo]] = [:]
    private(set) var functions: [UUID: [RoutineInfo]] = [:]
    private(set) var schemasInOrder: [UUID: [String]] = [:]
    private(set) var perSchemaStates: [UUID: [String: SchemaState]] = [:]
    private(set) var generations: [UUID: Int] = [:]

    func generationToken(for connectionId: UUID) -> Int {
        generations[connectionId] ?? 0
    }

    private func bumpGeneration(_ connectionId: UUID) {
        generations[connectionId, default: 0] &+= 1
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
        states[connectionId] ?? .idle
    }

    func tables(for connectionId: UUID) -> [TableInfo] {
        if case .loaded(let tables) = state(for: connectionId) {
            return tables
        }
        return []
    }

    func procedures(for connectionId: UUID) -> [RoutineInfo] {
        procedures[connectionId] ?? []
    }

    func functions(for connectionId: UUID) -> [RoutineInfo] {
        functions[connectionId] ?? []
    }

    func routines(for connectionId: UUID) -> [RoutineInfo] {
        procedures(for: connectionId) + functions(for: connectionId)
    }

    func schemas(for connectionId: UUID) -> [String] {
        schemasInOrder[connectionId] ?? []
    }

    func schemaState(for connectionId: UUID, schema: String) -> SchemaState {
        perSchemaStates[connectionId]?[schema] ?? .idle
    }

    func tables(for connectionId: UUID, schema: String) -> [TableInfo] {
        if case .loaded(let tables) = schemaState(for: connectionId, schema: schema) {
            return tables
        }
        return []
    }

    func loadSchemaTables(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        if case .loaded = schemaState(for: connectionId, schema: schema) { return }
        setPerSchemaState(.loading, connectionId: connectionId, schema: schema)
        do {
            let tables = try await perSchemaDedup.execute(key: SchemaKey(connectionId: connectionId, schema: schema)) {
                try await driver.fetchTables(schema: schema)
            }
            setPerSchemaState(.loaded(tables), connectionId: connectionId, schema: schema)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] per-schema load failed connId=\(connectionId, privacy: .public) schema=\(schema, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            setPerSchemaState(.failed(error.localizedDescription), connectionId: connectionId, schema: schema)
        }
    }

    func reloadSchemaTables(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        await perSchemaDedup.cancel(key: SchemaKey(connectionId: connectionId, schema: schema))
        clearPerSchemaState(connectionId: connectionId, schema: schema)
        await loadSchemaTables(connectionId: connectionId, schema: schema, driver: driver)
    }

    private func setPerSchemaState(_ state: SchemaState, connectionId: UUID, schema: String) {
        var inner = perSchemaStates[connectionId] ?? [:]
        inner[schema] = state
        perSchemaStates[connectionId] = inner
        bumpGeneration(connectionId)
    }

    private func clearPerSchemaState(connectionId: UUID, schema: String) {
        guard var inner = perSchemaStates[connectionId] else { return }
        inner.removeValue(forKey: schema)
        perSchemaStates[connectionId] = inner
        bumpGeneration(connectionId)
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
            procedures[connectionId] = routines
            bumpGeneration(connectionId)
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
            functions[connectionId] = routines
            bumpGeneration(connectionId)
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
        if let schemas = perSchemaStates[connectionId]?.keys {
            for schema in schemas {
                await perSchemaDedup.cancel(key: SchemaKey(connectionId: connectionId, schema: schema))
            }
        }
        loadGenerations.removeValue(forKey: connectionId)
        states.removeValue(forKey: connectionId)
        procedures.removeValue(forKey: connectionId)
        functions.removeValue(forKey: connectionId)
        schemasInOrder.removeValue(forKey: connectionId)
        perSchemaStates.removeValue(forKey: connectionId)
        generations.removeValue(forKey: connectionId)
    }

    func refresh(connectionId: UUID) async {
        guard let session = DatabaseManager.shared.activeSessions[connectionId],
              let driver = session.driver else { return }
        await invalidate(connectionId: connectionId)
        await reload(connectionId: connectionId, driver: driver, connection: session.connection)
    }

    private func runLoad(
        connectionId: UUID,
        driver: DatabaseDriver,
        connection: DatabaseConnection
    ) async {
        let generation = beginLoadGeneration(for: connectionId)
        states[connectionId] = .loading
        bumpGeneration(connectionId)

        let supportsSchemas = PluginManager.shared.supportsSchemaSwitching(for: connection.type)
        if !supportsSchemas {
            schemasInOrder.removeValue(forKey: connectionId)
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
            states[connectionId] = .loaded(tables)

            let loadedProcedures = await proceduresTask
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "procedures-loaded") else {
                return
            }
            procedures[connectionId] = loadedProcedures

            let loadedFunctions = await functionsTask
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "functions-loaded") else {
                return
            }
            functions[connectionId] = loadedFunctions

            if let loadedSchemas = await schemasTask {
                guard isCurrentLoadGeneration(generation, for: connectionId, phase: "schemas-loaded") else {
                    return
                }
                schemasInOrder[connectionId] = loadedSchemas
            }
            bumpGeneration(connectionId)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "tables-failed") else {
                if loadGenerations[connectionId] == nil, case .loading = states[connectionId] {
                    states[connectionId] = .idle
                }
                return
            }
            Self.logger.warning(
                "[schema] load failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            states[connectionId] = .failed(error.localizedDescription)
            bumpGeneration(connectionId)
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
        let loadedSchemas = await Self.fetchSchemasSafely(
            connectionId: connectionId,
            dedup: schemasDedup,
            fetch: { try await driver.fetchSchemas() }
        )

        guard isCurrentLoadGeneration(generation, for: connectionId, phase: "hierarchical-loaded") else {
            return
        }
        if let loadedSchemas {
            schemasInOrder[connectionId] = loadedSchemas
        }
        procedures[connectionId] = loadedProcedures
        functions[connectionId] = loadedFunctions
        states[connectionId] = .loaded([])
        bumpGeneration(connectionId)
    }

    private func beginLoadGeneration(for connectionId: UUID) -> Int {
        nextLoadGeneration += 1
        let generation = nextLoadGeneration
        if case .loading? = states[connectionId] {
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

        states[connectionId] = .loading
        bumpGeneration(connectionId)

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
            states[connectionId] = .loaded(tables)
            procedures[connectionId] = loadedProcedures
            functions[connectionId] = loadedFunctions
            bumpGeneration(connectionId)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] current-schema reload failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            states[connectionId] = .failed(error.localizedDescription)
            bumpGeneration(connectionId)
        }
    }
}
