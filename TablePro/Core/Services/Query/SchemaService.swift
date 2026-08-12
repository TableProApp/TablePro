//
//  SchemaService.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// The object cache behind the sidebar, autocomplete and the object counts, keyed by the
/// container it was actually read from.
///
/// Keying it by connection alone gave every window of a connection one shared table list,
/// so a window browsing another database overwrote what the other windows were showing.
/// Teardown stays connection-wide: a disconnect takes every scope of the connection with it.
@MainActor
@Observable
final class SchemaService {
    static let shared = SchemaService()

    private(set) var states: [DatabaseScope: SchemaState] = [:]
    private(set) var procedures: [DatabaseScope: [RoutineInfo]] = [:]
    private(set) var functions: [DatabaseScope: [RoutineInfo]] = [:]
    private(set) var schemasInOrder: [DatabaseScope: [String]] = [:]
    private(set) var perSchemaStates: [DatabaseScope: [String: SchemaState]] = [:]
    private(set) var generations: [DatabaseScope: Int] = [:]
    private(set) var refreshingScopes: Set<DatabaseScope> = []

    func generationToken(for scope: DatabaseScope) -> Int {
        generations[scope] ?? 0
    }

    /// A fingerprint for caches a connection shares across its windows. Any scope of the
    /// connection moving has to invalidate them, so this folds every scope's generation in.
    func generationToken(forConnection connectionId: UUID) -> Int {
        generations.reduce(into: 0) { total, entry in
            guard entry.key.connectionId == connectionId else { return }
            total &+= entry.value
        }
    }

    private func bumpGeneration(_ scope: DatabaseScope) {
        generations[scope, default: 0] &+= 1
    }

    @ObservationIgnored private let loadDedup = OnceTask<DatabaseScope, [TableInfo]>()
    @ObservationIgnored private let procedureDedup = OnceTask<DatabaseScope, [RoutineInfo]>()
    @ObservationIgnored private let functionDedup = OnceTask<DatabaseScope, [RoutineInfo]>()
    @ObservationIgnored private let schemasDedup = OnceTask<DatabaseScope, [String]>()
    @ObservationIgnored private let perSchemaDedup = OnceTask<SchemaKey, [TableInfo]>()

    struct SchemaKey: Hashable, Sendable {
        let scope: DatabaseScope
        let schema: String
    }
    @ObservationIgnored private var loadGenerations: [DatabaseScope: Int] = [:]
    @ObservationIgnored private var nextLoadGeneration = 0
    @ObservationIgnored private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaService")

    func state(for scope: DatabaseScope) -> SchemaState {
        states[scope] ?? .idle
    }

    func isRefreshing(scope: DatabaseScope) -> Bool {
        refreshingScopes.contains(scope)
    }

    func hasLoadedContent(for scope: DatabaseScope) -> Bool {
        if case .loaded = state(for: scope) { return true }
        return false
    }

    func hasLoadedContent(for scope: DatabaseScope, schema: String) -> Bool {
        if case .loaded = schemaState(for: scope, schema: schema) { return true }
        return false
    }

    func tables(for scope: DatabaseScope) -> [TableInfo] {
        if case .loaded(let tables) = state(for: scope) {
            return tables
        }
        return []
    }

    func procedures(for scope: DatabaseScope) -> [RoutineInfo] {
        procedures[scope] ?? []
    }

    func functions(for scope: DatabaseScope) -> [RoutineInfo] {
        functions[scope] ?? []
    }

    func routines(for scope: DatabaseScope) -> [RoutineInfo] {
        procedures(for: scope) + functions(for: scope)
    }

    func schemas(for scope: DatabaseScope) -> [String] {
        schemasInOrder[scope] ?? []
    }

    func schemaState(for scope: DatabaseScope, schema: String) -> SchemaState {
        perSchemaStates[scope]?[schema] ?? .idle
    }

    func tables(for scope: DatabaseScope, schema: String) -> [TableInfo] {
        if case .loaded(let tables) = schemaState(for: scope, schema: schema) {
            return tables
        }
        return []
    }

    /// Flat tables plus the union of every loaded per-schema table list. For
    /// hierarchicalSchema plugins the flat list is empty and this is the only
    /// way to see tables across schemas (e.g. for autocomplete).
    func allLoadedTables(for scope: DatabaseScope) -> [TableInfo] {
        var result = tables(for: scope)
        var seen = Set(result.map(\.id))
        for state in (perSchemaStates[scope] ?? [:]).values {
            guard case .loaded(let schemaTables) = state else { continue }
            for table in schemaTables where seen.insert(table.id).inserted {
                result.append(table)
            }
        }
        return result
    }

    func loadSchemaTables(scope: DatabaseScope, schema: String, driver: DatabaseDriver) async {
        if case .loaded = schemaState(for: scope, schema: schema) { return }
        await runSchemaLoad(scope: scope, schema: schema, driver: driver)
    }

    func reloadSchemaTables(scope: DatabaseScope, schema: String, driver: DatabaseDriver) async {
        await perSchemaDedup.cancel(key: SchemaKey(scope: scope, schema: schema))
        await runSchemaLoad(scope: scope, schema: schema, driver: driver)
    }

    /// Re-fetches every schema the user has already expanded, in place. Without this a
    /// non-destructive refresh would leave those lists showing pre-refresh contents.
    func refreshLoadedSchemaTables(scope: DatabaseScope, driver: DatabaseDriver) async {
        let loadedSchemas = (perSchemaStates[scope] ?? [:]).compactMap { schema, state -> String? in
            guard case .loaded = state else { return nil }
            return schema
        }
        for schema in loadedSchemas {
            await reloadSchemaTables(scope: scope, schema: schema, driver: driver)
        }
    }

    private func runSchemaLoad(scope: DatabaseScope, schema: String, driver: DatabaseDriver) async {
        if !hasLoadedContent(for: scope, schema: schema) {
            setPerSchemaState(.loading, scope: scope, schema: schema)
        }
        do {
            let tables = try await perSchemaDedup.execute(key: SchemaKey(scope: scope, schema: schema)) {
                try await driver.fetchTables(schema: schema)
            }
            setPerSchemaState(.loaded(tables), scope: scope, schema: schema)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] per-schema load failed connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) schema=\(schema, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            guard !hasLoadedContent(for: scope, schema: schema) else { return }
            setPerSchemaState(.failed(error.localizedDescription), scope: scope, schema: schema)
        }
    }

    private func setPerSchemaState(_ state: SchemaState, scope: DatabaseScope, schema: String) {
        var inner = perSchemaStates[scope] ?? [:]
        inner[schema] = state
        perSchemaStates[scope] = inner
        bumpGeneration(scope)
    }

    func load(scope: DatabaseScope, driver: DatabaseDriver, connection: DatabaseConnection) async {
        switch state(for: scope) {
        case .loaded:
            return
        case .idle, .loading, .failed:
            await runLoad(scope: scope, driver: driver, connection: connection)
        }
    }

    func reload(scope: DatabaseScope, driver: DatabaseDriver, connection: DatabaseConnection) async {
        await runLoad(scope: scope, driver: driver, connection: connection)
    }

    func reloadProcedures(scope: DatabaseScope, driver: DatabaseDriver) async {
        do {
            let routines = try await procedureDedup.execute(key: scope) {
                try await driver.fetchProcedures(schema: nil)
            }
            procedures[scope] = routines
            bumpGeneration(scope)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] procedures reload failed connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func reloadFunctions(scope: DatabaseScope, driver: DatabaseDriver) async {
        do {
            let routines = try await functionDedup.execute(key: scope) {
                try await driver.fetchFunctions(schema: nil)
            }
            functions[scope] = routines
            bumpGeneration(scope)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] functions reload failed connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Cancels in-flight fetches while keeping cached content on screen, so a
    /// refresh never blanks a sidebar that already has valid data.
    func prepareForReload(scope: DatabaseScope) async {
        await cancelInFlightLoads(scope: scope)
    }

    /// The reconnect path: the driver moves under every scope of the connection at once,
    /// so every in-flight load is stale, not just the one a window is looking at.
    func prepareForReload(connectionId: UUID) async {
        for scope in scopes(for: connectionId) {
            await cancelInFlightLoads(scope: scope)
        }
    }

    private func cancelInFlightLoads(scope: DatabaseScope) async {
        await loadDedup.cancel(key: scope)
        await procedureDedup.cancel(key: scope)
        await functionDedup.cancel(key: scope)
        await schemasDedup.cancel(key: scope)
        if let schemas = perSchemaStates[scope]?.keys {
            for schema in schemas {
                await perSchemaDedup.cancel(key: SchemaKey(scope: scope, schema: schema))
            }
        }
    }

    /// Teardown for a whole connection: a disconnect, or a database switch that recreates
    /// the driver, invalidates every container the connection ever loaded. Clearing only the
    /// scope one window happens to browse would leave the other windows on dead objects.
    func invalidate(connectionId: UUID) async {
        for scope in scopes(for: connectionId) {
            await invalidate(scope: scope)
        }
    }

    func invalidate(scope: DatabaseScope) async {
        await cancelInFlightLoads(scope: scope)
        loadGenerations.removeValue(forKey: scope)
        refreshingScopes.remove(scope)
        states.removeValue(forKey: scope)
        procedures.removeValue(forKey: scope)
        functions.removeValue(forKey: scope)
        schemasInOrder.removeValue(forKey: scope)
        perSchemaStates.removeValue(forKey: scope)
        generations.removeValue(forKey: scope)
    }

    private func scopes(for connectionId: UUID) -> Set<DatabaseScope> {
        var result = Set<DatabaseScope>()
        for key in states.keys where key.connectionId == connectionId { result.insert(key) }
        for key in procedures.keys where key.connectionId == connectionId { result.insert(key) }
        for key in functions.keys where key.connectionId == connectionId { result.insert(key) }
        for key in schemasInOrder.keys where key.connectionId == connectionId { result.insert(key) }
        for key in perSchemaStates.keys where key.connectionId == connectionId { result.insert(key) }
        for key in generations.keys where key.connectionId == connectionId { result.insert(key) }
        for key in refreshingScopes where key.connectionId == connectionId { result.insert(key) }
        for key in loadGenerations.keys where key.connectionId == connectionId { result.insert(key) }
        return result
    }

    func markLoadFailed(scope: DatabaseScope, message: String) {
        if case .loaded = state(for: scope) { return }
        states[scope] = .failed(message)
        bumpGeneration(scope)
    }

    private func runLoad(
        scope: DatabaseScope,
        driver: DatabaseDriver,
        connection: DatabaseConnection
    ) async {
        let generation = beginLoadGeneration(for: scope)
        beginRefresh(scope)
        defer { endRefresh(scope, generation: generation) }
        if !hasLoadedContent(for: scope) {
            states[scope] = .loading
        }
        bumpGeneration(scope)

        let supportsSchemas = PluginManager.shared.supportsSchemaSwitching(for: connection.type)
        if !supportsSchemas {
            schemasInOrder.removeValue(forKey: scope)
        }

        let grouping = PluginManager.shared.databaseGroupingStrategy(for: connection.type)
        if grouping == .hierarchicalSchema {
            await runHierarchicalLoad(scope: scope, driver: driver, generation: generation)
            return
        }

        async let tablesTask: [TableInfo] = loadDedup.execute(key: scope) {
            try await driver.fetchTables()
        }
        async let proceduresTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            scope: scope,
            kind: .procedure,
            dedup: procedureDedup,
            fetch: { try await driver.fetchProcedures(schema: nil) }
        )
        async let functionsTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            scope: scope,
            kind: .function,
            dedup: functionDedup,
            fetch: { try await driver.fetchFunctions(schema: nil) }
        )
        async let schemasTask: [String]? = supportsSchemas
            ? Self.fetchSchemasSafely(
                scope: scope,
                dedup: schemasDedup,
                fetch: { try await driver.fetchSchemas() }
            )
            : nil

        do {
            let tables = try await tablesTask
            guard isCurrentLoadGeneration(generation, for: scope, phase: "tables-loaded") else {
                return
            }
            states[scope] = .loaded(tables)

            let loadedProcedures = await proceduresTask
            guard isCurrentLoadGeneration(generation, for: scope, phase: "procedures-loaded") else {
                return
            }
            procedures[scope] = loadedProcedures

            let loadedFunctions = await functionsTask
            guard isCurrentLoadGeneration(generation, for: scope, phase: "functions-loaded") else {
                return
            }
            functions[scope] = loadedFunctions

            if let loadedSchemas = await schemasTask {
                guard isCurrentLoadGeneration(generation, for: scope, phase: "schemas-loaded") else {
                    return
                }
                schemasInOrder[scope] = loadedSchemas
            }
            bumpGeneration(scope)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLoadGeneration(generation, for: scope, phase: "tables-failed") else {
                if loadGenerations[scope] == nil, case .loading = states[scope] {
                    states[scope] = .idle
                }
                return
            }
            Self.logger.warning(
                "[schema] load failed connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            markLoadFailed(scope: scope, message: error.localizedDescription)
        }
    }

    private func runHierarchicalLoad(scope: DatabaseScope, driver: DatabaseDriver, generation: Int) async {
        async let proceduresTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            scope: scope,
            kind: .procedure,
            dedup: procedureDedup,
            fetch: { try await driver.fetchProcedures(schema: nil) }
        )
        async let functionsTask: [RoutineInfo] = Self.fetchRoutinesSafely(
            scope: scope,
            kind: .function,
            dedup: functionDedup,
            fetch: { try await driver.fetchFunctions(schema: nil) }
        )

        let loadedProcedures = await proceduresTask
        let loadedFunctions = await functionsTask

        let loadedSchemas: [String]
        do {
            loadedSchemas = try await schemasDedup.execute(key: scope) {
                try await driver.fetchSchemas()
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLoadGeneration(generation, for: scope, phase: "hierarchical-failed") else {
                return
            }
            Self.logger.warning(
                "[schema] hierarchical schema list failed connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            markLoadFailed(scope: scope, message: error.localizedDescription)
            return
        }

        guard isCurrentLoadGeneration(generation, for: scope, phase: "hierarchical-loaded") else {
            return
        }
        schemasInOrder[scope] = loadedSchemas
        procedures[scope] = loadedProcedures
        functions[scope] = loadedFunctions
        states[scope] = .loaded([])
        bumpGeneration(scope)
    }

    private func beginRefresh(_ scope: DatabaseScope) {
        refreshingScopes.insert(scope)
    }

    private func endRefresh(_ scope: DatabaseScope, generation: Int) {
        guard loadGenerations[scope] == generation else { return }
        refreshingScopes.remove(scope)
    }

    private func beginLoadGeneration(for scope: DatabaseScope) -> Int {
        nextLoadGeneration += 1
        let generation = nextLoadGeneration
        if case .loading? = states[scope] {
            let previousGeneration = loadGenerations[scope] ?? 0
            Self.logger.debug(
                "[schema] superseding in-flight load connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) previousGeneration=\(previousGeneration) newGeneration=\(generation)"
            )
        }
        loadGenerations[scope] = generation
        return generation
    }

    private func isCurrentLoadGeneration(
        _ generation: Int,
        for scope: DatabaseScope,
        phase: String
    ) -> Bool {
        guard loadGenerations[scope] == generation else {
            let currentGeneration = loadGenerations[scope] ?? 0
            Self.logger.debug(
                "[schema] stale load transition ignored connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) phase=\(phase, privacy: .public) generation=\(generation) currentGeneration=\(currentGeneration)"
            )
            return false
        }
        return true
    }

    private static func fetchSchemasSafely(
        scope: DatabaseScope,
        dedup: OnceTask<DatabaseScope, [String]>,
        fetch: @Sendable @escaping () async throws -> [String]
    ) async -> [String]? {
        do {
            return try await dedup.execute(key: scope, work: fetch)
        } catch is CancellationError {
            return nil
        } catch {
            Self.logger.warning(
                "[schema] fetchSchemas failed connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func fetchRoutinesSafely(
        scope: DatabaseScope,
        kind: RoutineInfo.Kind,
        dedup: OnceTask<DatabaseScope, [RoutineInfo]>,
        fetch: @Sendable @escaping () async throws -> [RoutineInfo]
    ) async -> [RoutineInfo] {
        do {
            return try await dedup.execute(key: scope, work: fetch)
        } catch is CancellationError {
            return []
        } catch {
            logger.warning(
                "[schema] \(kind.rawValue, privacy: .public) load failed connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}
