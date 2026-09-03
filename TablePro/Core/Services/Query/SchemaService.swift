//
//  SchemaService.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

@MainActor
@Observable
final class SchemaService {
    static let shared = SchemaService()

    private(set) var states: [UUID: SchemaState] = [:]
    private(set) var routines: [UUID: [RoutineInfo]] = [:]
    private(set) var triggers: [UUID: [TriggerInfo]] = [:]
    private(set) var userDefinedTypes: [UUID: [UserDefinedTypeInfo]] = [:]
    private(set) var schemasInOrder: [UUID: [String]] = [:]
    private(set) var perSchemaStates: [UUID: [String: SchemaState]] = [:]
    private(set) var generations: [UUID: Int] = [:]
    private(set) var refreshingConnections: Set<UUID> = []
    private(set) var loadedScopes: [UUID: DatabaseScope] = [:]

    func generationToken(for connectionId: UUID) -> Int {
        generations[connectionId] ?? 0
    }

    private func bumpGeneration(_ connectionId: UUID) {
        generations[connectionId, default: 0] &+= 1
    }

    @ObservationIgnored private let loadDedup = OnceTask<LoadKey, [TableInfo]>()
    @ObservationIgnored private let routinesDedup = OnceTask<UUID, [RoutineInfo]>()
    @ObservationIgnored private let triggersDedup = OnceTask<UUID, [TriggerInfo]>()
    @ObservationIgnored private let typesDedup = OnceTask<UUID, [UserDefinedTypeInfo]>()
    @ObservationIgnored private let schemasDedup = OnceTask<UUID, [String]>()
    @ObservationIgnored private let perSchemaDedup = OnceTask<SchemaKey, [TableInfo]>()

    struct SchemaKey: Hashable, Sendable {
        let connectionId: UUID
        let schema: String
    }

    /// Two windows browsing the same scope share one fetch; two windows browsing different
    /// scopes must not, or the second stamps the first's tables with its own scope.
    struct LoadKey: Hashable, Sendable {
        let connectionId: UUID
        let scope: DatabaseScope?
    }

    private struct RefreshWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    @ObservationIgnored private var loadGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var refreshWaiters: [UUID: [RefreshWaiter]] = [:]
    @ObservationIgnored private var nextLoadGeneration = 0
    @ObservationIgnored nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaService")

    func state(for connectionId: UUID) -> SchemaState {
        states[connectionId] ?? .idle
    }

    func isRefreshing(connectionId: UUID) -> Bool {
        refreshingConnections.contains(connectionId)
    }

    func loadedScope(for connectionId: UUID) -> DatabaseScope? {
        loadedScopes[connectionId]
    }

    /// Records that what is loaded already covers `scope`, without refetching it.
    ///
    /// Only for a scope change that cannot invalidate the catalog: on an engine that groups by
    /// hierarchical schema, moving the session's default schema leaves the schema list and every
    /// per-schema object list, each keyed by an explicit schema, exactly as they were. Without
    /// this the recorded scope keeps naming the schema the session left, and the next reader
    /// compares the two and runs the full reload the caller just avoided.
    func noteScopeCovered(_ scope: DatabaseScope, for connectionId: UUID) {
        guard case .loaded = state(for: connectionId) else { return }
        loadedScopes[connectionId] = scope
    }

    func waitForRefresh(connectionId: UUID) async {
        while refreshingConnections.contains(connectionId), !Task.isCancelled {
            let waiterId = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard refreshingConnections.contains(connectionId), !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    refreshWaiters[connectionId, default: []]
                        .append(RefreshWaiter(id: waiterId, continuation: continuation))
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resumeRefreshWaiter(connectionId, id: waiterId)
                }
            }
        }
    }

    func hasLoadedContent(for connectionId: UUID) -> Bool {
        if case .loaded = state(for: connectionId) { return true }
        return false
    }

    func hasLoadedContent(for connectionId: UUID, schema: String) -> Bool {
        if case .loaded = schemaState(for: connectionId, schema: schema) { return true }
        return false
    }

    func tables(for connectionId: UUID) -> [TableInfo] {
        if case .loaded(let tables) = state(for: connectionId) {
            return tables
        }
        return []
    }

    func routines(for connectionId: UUID) -> [RoutineInfo] {
        routines[connectionId] ?? []
    }

    func procedures(for connectionId: UUID) -> [RoutineInfo] {
        routines(for: connectionId).filter { $0.kind == .procedure }
    }

    func functions(for connectionId: UUID) -> [RoutineInfo] {
        routines(for: connectionId).filter { $0.kind == .function }
    }

    func triggers(for connectionId: UUID) -> [TriggerInfo] {
        triggers[connectionId] ?? []
    }

    func userDefinedTypes(for connectionId: UUID) -> [UserDefinedTypeInfo] {
        userDefinedTypes[connectionId] ?? []
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

    /// Flat tables plus the union of every loaded per-schema table list. For
    /// hierarchicalSchema plugins the flat list is empty and this is the only
    /// way to see tables across schemas (e.g. for autocomplete).
    func allLoadedTables(for connectionId: UUID) -> [TableInfo] {
        var result = tables(for: connectionId)
        var seen = Set(result.map(\.id))
        for state in (perSchemaStates[connectionId] ?? [:]).values {
            guard case .loaded(let schemaTables) = state else { continue }
            for table in schemaTables where seen.insert(table.id).inserted {
                result.append(table)
            }
        }
        return result
    }

    func loadSchemaTables(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        if case .loaded = schemaState(for: connectionId, schema: schema) { return }
        await runSchemaLoad(connectionId: connectionId, schema: schema, driver: driver)
    }

    func reloadSchemaTables(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        await perSchemaDedup.cancel(key: SchemaKey(connectionId: connectionId, schema: schema))
        await runSchemaLoad(connectionId: connectionId, schema: schema, driver: driver)
    }

    /// Re-fetches every schema the user has already expanded, in place. Without this a
    /// non-destructive refresh would leave those lists showing pre-refresh contents.
    func refreshLoadedSchemaTables(connectionId: UUID, driver: DatabaseDriver) async {
        let loadedSchemas = (perSchemaStates[connectionId] ?? [:]).compactMap { schema, state -> String? in
            guard case .loaded = state else { return nil }
            return schema
        }
        for schema in loadedSchemas {
            await reloadSchemaTables(connectionId: connectionId, schema: schema, driver: driver)
        }
    }

    private func runSchemaLoad(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        if !hasLoadedContent(for: connectionId, schema: schema) {
            setPerSchemaState(.loading, connectionId: connectionId, schema: schema)
        }
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
            guard !hasLoadedContent(for: connectionId, schema: schema) else { return }
            setPerSchemaState(.failed(error.localizedDescription), connectionId: connectionId, schema: schema)
        }
    }

    private func setPerSchemaState(_ state: SchemaState, connectionId: UUID, schema: String) {
        var inner = perSchemaStates[connectionId] ?? [:]
        inner[schema] = state
        perSchemaStates[connectionId] = inner
        bumpGeneration(connectionId)
    }

    func load(
        connectionId: UUID,
        driver: DatabaseDriver,
        connection: DatabaseConnection,
        scope: DatabaseScope? = nil
    ) async {
        switch state(for: connectionId) {
        case .loaded where scope == nil || loadedScopes[connectionId] == scope:
            return
        case .idle, .loading, .failed, .loaded:
            await runLoad(connectionId: connectionId, driver: driver, connection: connection, scope: scope)
        }
    }

    func reload(
        connectionId: UUID,
        driver: DatabaseDriver,
        connection: DatabaseConnection,
        scope: DatabaseScope? = nil
    ) async {
        await runLoad(connectionId: connectionId, driver: driver, connection: connection, scope: scope)
    }

    /// Returns false when the stored list is still the one from before the call, so a caller that
    /// is about to record what its refresh covered can tell a real reload from a swallowed error.
    @discardableResult
    func reloadRoutines(connectionId: UUID, driver: DatabaseDriver) async -> Bool {
        do {
            let loaded = try await routinesDedup.execute(key: connectionId) {
                try await driver.fetchRoutines(schema: nil)
            }
            routines[connectionId] = loaded
            bumpGeneration(connectionId)
            return true
        } catch is CancellationError {
            return false
        } catch {
            Self.logger.warning(
                "[schema] routines reload failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    @discardableResult
    func reloadTriggers(connectionId: UUID, driver: DatabaseDriver) async -> Bool {
        do {
            let loaded = try await triggersDedup.execute(key: connectionId) {
                try await driver.fetchAllTriggers(schema: nil)
            }
            triggers[connectionId] = loaded
            bumpGeneration(connectionId)
            return true
        } catch is CancellationError {
            return false
        } catch {
            Self.logger.warning(
                "[schema] triggers reload failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    @discardableResult
    func reloadUserDefinedTypes(connectionId: UUID, driver: DatabaseDriver) async -> Bool {
        do {
            let loaded = try await typesDedup.execute(key: connectionId) {
                try await driver.fetchUserDefinedTypes(schema: nil)
            }
            userDefinedTypes[connectionId] = loaded
            bumpGeneration(connectionId)
            return true
        } catch is CancellationError {
            return false
        } catch {
            Self.logger.warning(
                "[schema] types reload failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Cancels in-flight fetches while keeping cached content on screen, so a
    /// refresh never blanks a sidebar that already has valid data.
    func prepareForReload(connectionId: UUID) async {
        await cancelInFlightLoads(connectionId: connectionId)
    }

    private func cancelInFlightLoads(connectionId: UUID) async {
        await loadDedup.cancel { $0.connectionId == connectionId }
        await routinesDedup.cancel(key: connectionId)
        await triggersDedup.cancel(key: connectionId)
        await typesDedup.cancel(key: connectionId)
        await schemasDedup.cancel(key: connectionId)
        await perSchemaDedup.cancel { $0.connectionId == connectionId }
    }

    func invalidate(connectionId: UUID) async {
        await cancelInFlightLoads(connectionId: connectionId)
        loadGenerations.removeValue(forKey: connectionId)
        refreshingConnections.remove(connectionId)
        states.removeValue(forKey: connectionId)
        routines.removeValue(forKey: connectionId)
        triggers.removeValue(forKey: connectionId)
        userDefinedTypes.removeValue(forKey: connectionId)
        schemasInOrder.removeValue(forKey: connectionId)
        perSchemaStates.removeValue(forKey: connectionId)
        generations.removeValue(forKey: connectionId)
        loadedScopes.removeValue(forKey: connectionId)
        resumeRefreshWaiters(connectionId)
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
        await prepareForReload(connectionId: connectionId)
        await reload(
            connectionId: connectionId,
            driver: driver,
            connection: session.connection,
            scope: DatabaseManager.shared.browseScope(for: connectionId)
        )
    }

    func markLoadFailed(connectionId: UUID, message: String) {
        if case .loaded = state(for: connectionId) { return }
        states[connectionId] = .failed(message)
        bumpGeneration(connectionId)
    }

    private func runLoad(
        connectionId: UUID,
        driver: DatabaseDriver,
        connection: DatabaseConnection,
        scope: DatabaseScope?
    ) async {
        let generation = beginLoadGeneration(for: connectionId)
        beginRefresh(connectionId)
        defer { endRefresh(connectionId, generation: generation) }
        if !hasLoadedContent(for: connectionId) {
            states[connectionId] = .loading
        }
        bumpGeneration(connectionId)

        /// Keeping the previous routines is only right for a refresh of the same scope. When the
        /// scope moved, routines fetched from the database being left do not describe the one
        /// being entered, and showing them is worse than showing none.
        let scopeChanged = scope != nil && loadedScopes[connectionId] != scope

        let supportsSchemas = PluginManager.shared.supportsSchemaSwitching(for: connection.type)
        if !supportsSchemas {
            schemasInOrder.removeValue(forKey: connectionId)
        }

        let grouping = PluginManager.shared.databaseGroupingStrategy(for: connection.type)
        if grouping == .hierarchicalSchema {
            await runHierarchicalLoad(
                connectionId: connectionId,
                driver: driver,
                browsesTriggers: connection.type.supportsDatabaseTriggerBrowse,
                browsesTypes: connection.type.supportsUserDefinedTypeBrowse,
                generation: generation,
                scope: scope
            )
            return
        }

        async let tablesTask: [TableInfo] = loadDedup.execute(
            key: LoadKey(connectionId: connectionId, scope: scope)
        ) {
            try await driver.fetchTables()
        }
        async let routinesTask: [RoutineInfo]? = Self.fetchObjectsSafely(
            connectionId: connectionId,
            label: "routines",
            dedup: routinesDedup,
            fetch: { try await driver.fetchRoutines(schema: nil) }
        )
        let browsesTriggers = connection.type.supportsDatabaseTriggerBrowse
        async let triggersTask: [TriggerInfo]? = browsesTriggers
            ? Self.fetchObjectsSafely(
                connectionId: connectionId,
                label: "triggers",
                dedup: triggersDedup,
                fetch: { try await driver.fetchAllTriggers(schema: nil) }
            )
            : nil
        let browsesTypes = connection.type.supportsUserDefinedTypeBrowse
        async let typesTask: [UserDefinedTypeInfo]? = browsesTypes
            ? Self.fetchObjectsSafely(
                connectionId: connectionId,
                label: "types",
                dedup: typesDedup,
                fetch: { try await driver.fetchUserDefinedTypes(schema: nil) }
            )
            : nil
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

            let loadedRoutines = await routinesTask
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "routines-loaded") else {
                return
            }
            if let loadedRoutines {
                routines[connectionId] = loadedRoutines
            } else if scopeChanged {
                routines.removeValue(forKey: connectionId)
            }

            let loadedTriggers = await triggersTask
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "triggers-loaded") else {
                return
            }
            if let loadedTriggers {
                triggers[connectionId] = loadedTriggers
            } else if scopeChanged {
                triggers.removeValue(forKey: connectionId)
            }

            let loadedTypes = await typesTask
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "types-loaded") else {
                return
            }
            if let loadedTypes {
                userDefinedTypes[connectionId] = loadedTypes
            } else if scopeChanged {
                userDefinedTypes.removeValue(forKey: connectionId)
            }

            if let loadedSchemas = await schemasTask {
                guard isCurrentLoadGeneration(generation, for: connectionId, phase: "schemas-loaded") else {
                    return
                }
                schemasInOrder[connectionId] = loadedSchemas
            }
            if let scope {
                loadedScopes[connectionId] = scope
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
            markLoadFailed(connectionId: connectionId, message: error.localizedDescription)
        }
    }

    private func runHierarchicalLoad(
        connectionId: UUID,
        driver: DatabaseDriver,
        browsesTriggers: Bool,
        browsesTypes: Bool,
        generation: Int,
        scope: DatabaseScope?
    ) async {
        let scopeChanged = scope != nil && loadedScopes[connectionId] != scope
        async let routinesTask: [RoutineInfo]? = Self.fetchObjectsSafely(
            connectionId: connectionId,
            label: "routines",
            dedup: routinesDedup,
            fetch: { try await driver.fetchRoutines(schema: nil) }
        )
        async let triggersTask: [TriggerInfo]? = browsesTriggers
            ? Self.fetchObjectsSafely(
                connectionId: connectionId,
                label: "triggers",
                dedup: triggersDedup,
                fetch: { try await driver.fetchAllTriggers(schema: nil) }
            )
            : nil
        async let typesTask: [UserDefinedTypeInfo]? = browsesTypes
            ? Self.fetchObjectsSafely(
                connectionId: connectionId,
                label: "types",
                dedup: typesDedup,
                fetch: { try await driver.fetchUserDefinedTypes(schema: nil) }
            )
            : nil

        let loadedRoutines = await routinesTask
        let loadedTriggers = await triggersTask
        let loadedTypes = await typesTask

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
            markLoadFailed(connectionId: connectionId, message: error.localizedDescription)
            return
        }

        guard isCurrentLoadGeneration(generation, for: connectionId, phase: "hierarchical-loaded") else {
            return
        }
        schemasInOrder[connectionId] = loadedSchemas
        if let loadedRoutines {
            routines[connectionId] = loadedRoutines
        } else if scopeChanged {
            routines.removeValue(forKey: connectionId)
        }
        if let loadedTriggers {
            triggers[connectionId] = loadedTriggers
        } else if scopeChanged {
            triggers.removeValue(forKey: connectionId)
        }
        if let loadedTypes {
            userDefinedTypes[connectionId] = loadedTypes
        } else if scopeChanged {
            userDefinedTypes.removeValue(forKey: connectionId)
        }
        states[connectionId] = .loaded([])
        if let scope {
            loadedScopes[connectionId] = scope
        }
        bumpGeneration(connectionId)
    }

    private func beginRefresh(_ connectionId: UUID) {
        refreshingConnections.insert(connectionId)
    }

    private func endRefresh(_ connectionId: UUID, generation: Int) {
        guard loadGenerations[connectionId] == generation else { return }
        refreshingConnections.remove(connectionId)
        resumeRefreshWaiters(connectionId)
    }

    private func resumeRefreshWaiters(_ connectionId: UUID) {
        let waiters = refreshWaiters.removeValue(forKey: connectionId) ?? []
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    private func resumeRefreshWaiter(_ connectionId: UUID, id: UUID) {
        guard var waiters = refreshWaiters[connectionId],
              let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        refreshWaiters[connectionId] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume()
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

    /// Nil when the fetch did not answer, so the caller keeps what it already had.
    ///
    /// Returning an empty list instead made a refresh that failed indistinguishable from a
    /// database with no routines, and the caller committed it over the loaded one: a single
    /// dropped connection emptied the sidebar's procedures and functions while the refresh
    /// reported success, with nothing scheduled to put them back.
    private static func fetchObjectsSafely<Value: Sendable>(
        connectionId: UUID,
        label: String,
        dedup: OnceTask<UUID, [Value]>,
        fetch: @Sendable @escaping () async throws -> [Value]
    ) async -> [Value]? {
        do {
            return try await dedup.execute(key: connectionId, work: fetch)
        } catch is CancellationError {
            return nil
        } catch {
            logger.warning(
                "[schema] \(label, privacy: .public) load failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
