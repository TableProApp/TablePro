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

    /// The object kinds that are not tables, each behind its own load state so a list that is still
    /// coming, a list that failed and a list that came back empty stay three different answers.
    struct SideObjects: Sendable {
        var routines: MetadataLoadState<[RoutineInfo]> = .idle
        var triggers: MetadataLoadState<[TriggerInfo]> = .idle
        var userDefinedTypes: MetadataLoadState<[UserDefinedTypeInfo]> = .idle
    }

    private(set) var states: [UUID: SchemaState] = [:]
    private(set) var sideObjects: [UUID: SideObjects] = [:]
    private(set) var schemasInOrder: [UUID: [String]] = [:]
    private(set) var perSchemaStates: [UUID: [String: SchemaState]] = [:]
    private(set) var perSchemaSideObjects: [UUID: [String: SideObjects]] = [:]
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
    @ObservationIgnored private let routinesDedup = OnceTask<LoadKey, [RoutineInfo]>()
    @ObservationIgnored private let triggersDedup = OnceTask<LoadKey, [TriggerInfo]>()
    @ObservationIgnored private let typesDedup = OnceTask<LoadKey, [UserDefinedTypeInfo]>()
    @ObservationIgnored private let schemasDedup = OnceTask<LoadKey, [String]>()
    @ObservationIgnored private let perSchemaDedup = OnceTask<SchemaKey, [TableInfo]>()
    @ObservationIgnored private let perSchemaRoutinesDedup = OnceTask<SchemaKey, [RoutineInfo]>()
    @ObservationIgnored private let perSchemaTriggersDedup = OnceTask<SchemaKey, [TriggerInfo]>()
    @ObservationIgnored private let perSchemaTypesDedup = OnceTask<SchemaKey, [UserDefinedTypeInfo]>()

    struct SchemaKey: Hashable, Sendable {
        let connectionId: UUID
        let schema: String
    }

    /// Two windows browsing the same scope share one fetch; two windows browsing different
    /// scopes must not, or the second stamps the first's tables with its own scope. Every
    /// object kind is keyed this way, because a routine, trigger, type or schema list fetched
    /// from the database being left describes that database, not the one being entered.
    struct LoadKey: Hashable, Sendable {
        let connectionId: UUID
        let scope: DatabaseScope?
    }

    /// Which side kinds an engine browses at all. A kind it never fetches stays idle, and idle is
    /// not a load in progress.
    private struct SideKinds {
        let triggers: Bool
        let types: Bool

        init(_ type: DatabaseType) {
            triggers = type.supportsDatabaseTriggerBrowse
            types = type.supportsUserDefinedTypeBrowse
        }
    }

    private struct RefreshWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    @ObservationIgnored private var loadGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var schemaLoadGenerations: [SchemaKey: Int] = [:]
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
        routinesLoadState(for: connectionId).value ?? []
    }

    func procedures(for connectionId: UUID) -> [RoutineInfo] {
        routines(for: connectionId).filter { $0.kind == .procedure }
    }

    func functions(for connectionId: UUID) -> [RoutineInfo] {
        routines(for: connectionId).filter { $0.kind == .function }
    }

    func triggers(for connectionId: UUID) -> [TriggerInfo] {
        triggersLoadState(for: connectionId).value ?? []
    }

    func userDefinedTypes(for connectionId: UUID) -> [UserDefinedTypeInfo] {
        userDefinedTypesLoadState(for: connectionId).value ?? []
    }

    func routinesLoadState(for connectionId: UUID) -> MetadataLoadState<[RoutineInfo]> {
        sideObjects[connectionId]?.routines ?? .idle
    }

    func triggersLoadState(for connectionId: UUID) -> MetadataLoadState<[TriggerInfo]> {
        sideObjects[connectionId]?.triggers ?? .idle
    }

    func userDefinedTypesLoadState(for connectionId: UUID) -> MetadataLoadState<[UserDefinedTypeInfo]> {
        sideObjects[connectionId]?.userDefinedTypes ?? .idle
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

    func routines(for connectionId: UUID, schema: String) -> [RoutineInfo] {
        routinesLoadState(for: connectionId, schema: schema).value ?? []
    }

    func triggers(for connectionId: UUID, schema: String) -> [TriggerInfo] {
        triggersLoadState(for: connectionId, schema: schema).value ?? []
    }

    func userDefinedTypes(for connectionId: UUID, schema: String) -> [UserDefinedTypeInfo] {
        userDefinedTypesLoadState(for: connectionId, schema: schema).value ?? []
    }

    /// Whether everything one schema holds has been answered for, which is what a search needs
    /// before it may drop the schema for matching nothing. A kind whose fetch failed has not
    /// answered: the object the search wants may be exactly the one it could not list.
    func isSchemaSettled(for connectionId: UUID, schema: String) -> Bool {
        guard hasLoadedContent(for: connectionId, schema: schema) else { return false }
        let side = perSchemaSideObjects[connectionId]?[schema] ?? SideObjects()
        return [side.routines.erased, side.triggers.erased, side.userDefinedTypes.erased]
            .allSatisfy { $0 == .loaded || $0 == .idle }
    }

    func routinesLoadState(for connectionId: UUID, schema: String) -> MetadataLoadState<[RoutineInfo]> {
        perSchemaSideObjects[connectionId]?[schema]?.routines ?? .idle
    }

    func triggersLoadState(for connectionId: UUID, schema: String) -> MetadataLoadState<[TriggerInfo]> {
        perSchemaSideObjects[connectionId]?[schema]?.triggers ?? .idle
    }

    func userDefinedTypesLoadState(
        for connectionId: UUID,
        schema: String
    ) -> MetadataLoadState<[UserDefinedTypeInfo]> {
        perSchemaSideObjects[connectionId]?[schema]?.userDefinedTypes ?? .idle
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

    /// Per-schema reads go through the metadata route like every other catalog read, so a tab that
    /// moved the session to another database cannot answer for the schema being browsed. The route
    /// is the database's, not the schema's: every fetch names its schema, and a scope per schema
    /// opened a pooled connection per schema, one for every schema a sidebar search walked.
    func loadSchemaObjects(connectionId: UUID, schema: String, database: String?) async {
        if case .loaded = schemaState(for: connectionId, schema: schema) { return }
        await withSchemaMetadataDriver(connectionId: connectionId, schema: schema, database: database) { driver in
            await self.loadSchemaObjects(connectionId: connectionId, schema: schema, driver: driver)
        }
    }

    func reloadSchemaObjects(connectionId: UUID, schema: String, database: String?) async {
        await withSchemaMetadataDriver(connectionId: connectionId, schema: schema, database: database) { driver in
            await self.reloadSchemaObjects(connectionId: connectionId, schema: schema, driver: driver)
        }
    }

    private func withSchemaMetadataDriver(
        connectionId: UUID,
        schema: String,
        database: String?,
        _ body: @Sendable @escaping (DatabaseDriver) async -> Void
    ) async {
        guard let scope = DatabaseManager.shared.resolvedScope(
            database: database,
            schema: nil,
            for: connectionId
        ) else { return }
        do {
            try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk, body)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] per-schema route failed connId=\(connectionId, privacy: .public) schema=\(schema, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            commitSchemaTables(.failed(error.localizedDescription), connectionId: connectionId, schema: schema)
        }
    }

    func loadSchemaObjects(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        if case .loaded = schemaState(for: connectionId, schema: schema) { return }
        await runSchemaLoad(connectionId: connectionId, schema: schema, driver: driver)
    }

    func reloadSchemaObjects(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        let key = SchemaKey(connectionId: connectionId, schema: schema)
        schemaLoadGenerations.removeValue(forKey: key)
        await perSchemaDedup.cancel(key: key)
        await perSchemaRoutinesDedup.cancel(key: key)
        await perSchemaTriggersDedup.cancel(key: key)
        await perSchemaTypesDedup.cancel(key: key)
        await runSchemaLoad(connectionId: connectionId, schema: schema, driver: driver)
    }

    /// Re-fetches every schema the user has already expanded, in place. Without this a
    /// non-destructive refresh would leave those lists showing pre-refresh contents.
    func refreshLoadedSchemaObjects(connectionId: UUID, driver: DatabaseDriver) async {
        let loadedSchemas = (perSchemaStates[connectionId] ?? [:]).compactMap { schema, state -> String? in
            guard case .loaded = state else { return nil }
            return schema
        }
        for schema in loadedSchemas {
            await reloadSchemaObjects(connectionId: connectionId, schema: schema, driver: driver)
        }
    }

    private func runSchemaLoad(connectionId: UUID, schema: String, driver: DatabaseDriver) async {
        let key = SchemaKey(connectionId: connectionId, schema: schema)
        nextLoadGeneration += 1
        let generation = nextLoadGeneration
        schemaLoadGenerations[key] = generation
        let kinds = SideKinds(driver.connection.type)

        if !hasLoadedContent(for: connectionId, schema: schema) {
            setPerSchemaState(.loading, connectionId: connectionId, schema: schema)
        }
        updateSchemaSideObjects(connectionId, schema: schema) { $0 = Self.enteringLoad($0, kinds: kinds) }
        bumpGeneration(connectionId)

        async let tablesTask: [TableInfo] = perSchemaDedup.execute(key: key) {
            try await driver.fetchTables(schema: schema)
        }
        async let routinesTask: MetadataFetchOutcome<[RoutineInfo]> = Self.fetchObjectsSafely(
            key: key,
            connectionId: connectionId,
            label: "schema routines",
            dedup: perSchemaRoutinesDedup,
            fetch: { try await driver.fetchRoutines(schema: schema) }
        )
        async let triggersTask: MetadataFetchOutcome<[TriggerInfo]>? = kinds.triggers
            ? Self.fetchObjectsSafely(
                key: key,
                connectionId: connectionId,
                label: "schema triggers",
                dedup: perSchemaTriggersDedup,
                fetch: { try await driver.fetchAllTriggers(schema: schema) }
            )
            : nil
        async let typesTask: MetadataFetchOutcome<[UserDefinedTypeInfo]>? = kinds.types
            ? Self.fetchObjectsSafely(
                key: key,
                connectionId: connectionId,
                label: "schema types",
                dedup: perSchemaTypesDedup,
                fetch: { try await driver.fetchUserDefinedTypes(schema: schema) }
            )
            : nil

        let tablesOutcome: MetadataFetchOutcome<[TableInfo]>
        do {
            tablesOutcome = .fetched(try await tablesTask)
        } catch is CancellationError {
            tablesOutcome = .cancelled
        } catch {
            Self.logger.warning(
                "[schema] per-schema load failed connId=\(connectionId, privacy: .public) schema=\(schema, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            tablesOutcome = .failed(error.localizedDescription)
        }
        guard schemaLoadGenerations[key] == generation else { return }
        commitSchemaTables(tablesOutcome, connectionId: connectionId, schema: schema)

        let routinesOutcome = await routinesTask
        let triggersOutcome = await triggersTask
        let typesOutcome = await typesTask
        guard schemaLoadGenerations[key] == generation else { return }
        schemaLoadGenerations.removeValue(forKey: key)
        updateSchemaSideObjects(connectionId, schema: schema) { side in
            side = Self.settled(
                side,
                routines: routinesOutcome,
                triggers: triggersOutcome,
                types: typesOutcome,
                discardingValue: false
            )
        }
        bumpGeneration(connectionId)
    }

    private func commitSchemaTables(
        _ outcome: MetadataFetchOutcome<[TableInfo]>,
        connectionId: UUID,
        schema: String
    ) {
        switch outcome {
        case .fetched(let tables):
            setPerSchemaState(.loaded(tables), connectionId: connectionId, schema: schema)
        case .failed(let message):
            guard !hasLoadedContent(for: connectionId, schema: schema) else { return }
            setPerSchemaState(.failed(message), connectionId: connectionId, schema: schema)
        case .cancelled:
            guard case .loading = schemaState(for: connectionId, schema: schema) else { return }
            setPerSchemaState(.idle, connectionId: connectionId, schema: schema)
        }
    }

    private func setPerSchemaState(_ state: SchemaState, connectionId: UUID, schema: String) {
        var inner = perSchemaStates[connectionId] ?? [:]
        inner[schema] = state
        perSchemaStates[connectionId] = inner
        bumpGeneration(connectionId)
    }

    private func updateSideObjects(_ connectionId: UUID, _ change: (inout SideObjects) -> Void) {
        var side = sideObjects[connectionId] ?? SideObjects()
        change(&side)
        sideObjects[connectionId] = side
    }

    private func updateSchemaSideObjects(
        _ connectionId: UUID,
        schema: String,
        _ change: (inout SideObjects) -> Void
    ) {
        var inner = perSchemaSideObjects[connectionId] ?? [:]
        var side = inner[schema] ?? SideObjects()
        change(&side)
        inner[schema] = side
        perSchemaSideObjects[connectionId] = inner
    }

    private func commitSideObjects(
        _ connectionId: UUID,
        routines: MetadataFetchOutcome<[RoutineInfo]>,
        triggers: MetadataFetchOutcome<[TriggerInfo]>?,
        types: MetadataFetchOutcome<[UserDefinedTypeInfo]>?,
        discardingValue: Bool
    ) {
        updateSideObjects(connectionId) { side in
            side = Self.settled(
                side,
                routines: routines,
                triggers: triggers,
                types: types,
                discardingValue: discardingValue
            )
        }
    }

    /// A load cut short by cancellation settles the kinds it put on a spinner, unless a newer load
    /// already owns them. Left alone, a cancel with no reload behind it kept those sections waiting
    /// on a fetch nothing was running.
    private func abandonSideLoads(_ connectionId: UUID, generation: Int) {
        guard loadGenerations[connectionId] == generation else { return }
        updateSideObjects(connectionId) { side in
            side.routines = side.routines.settled(by: .cancelled, discardingValue: false)
            side.triggers = side.triggers.settled(by: .cancelled, discardingValue: false)
            side.userDefinedTypes = side.userDefinedTypes.settled(by: .cancelled, discardingValue: false)
        }
        bumpGeneration(connectionId)
    }

    private static func enteringLoad(_ side: SideObjects, kinds: SideKinds) -> SideObjects {
        var next = side
        next.routines = side.routines.enteringLoad
        if kinds.triggers { next.triggers = side.triggers.enteringLoad }
        if kinds.types { next.userDefinedTypes = side.userDefinedTypes.enteringLoad }
        return next
    }

    /// A kind the engine was not asked for has no outcome. It keeps its state, unless the load
    /// moved to another scope, where whatever it held describes the scope being left.
    private static func settled(
        _ side: SideObjects,
        routines: MetadataFetchOutcome<[RoutineInfo]>,
        triggers: MetadataFetchOutcome<[TriggerInfo]>?,
        types: MetadataFetchOutcome<[UserDefinedTypeInfo]>?,
        discardingValue: Bool
    ) -> SideObjects {
        var next = side
        next.routines = side.routines.settled(by: routines, discardingValue: discardingValue)
        if let triggers {
            next.triggers = side.triggers.settled(by: triggers, discardingValue: discardingValue)
        } else if discardingValue {
            next.triggers = .idle
        }
        if let types {
            next.userDefinedTypes = side.userDefinedTypes.settled(by: types, discardingValue: discardingValue)
        } else if discardingValue {
            next.userDefinedTypes = .idle
        }
        return next
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
    func reloadRoutines(connectionId: UUID, driver: DatabaseDriver, scope: DatabaseScope?) async -> Bool {
        updateSideObjects(connectionId) { $0.routines = $0.routines.enteringLoad }
        bumpGeneration(connectionId)
        let outcome = await Self.fetchObjectsSafely(
            key: LoadKey(connectionId: connectionId, scope: scope),
            connectionId: connectionId,
            label: "routines",
            dedup: routinesDedup,
            fetch: { try await driver.fetchRoutines(schema: nil) }
        )
        updateSideObjects(connectionId) { $0.routines = $0.routines.settled(by: outcome, discardingValue: false) }
        bumpGeneration(connectionId)
        return outcome.didFetch
    }

    @discardableResult
    func reloadTriggers(connectionId: UUID, driver: DatabaseDriver, scope: DatabaseScope?) async -> Bool {
        updateSideObjects(connectionId) { $0.triggers = $0.triggers.enteringLoad }
        bumpGeneration(connectionId)
        let outcome = await Self.fetchObjectsSafely(
            key: LoadKey(connectionId: connectionId, scope: scope),
            connectionId: connectionId,
            label: "triggers",
            dedup: triggersDedup,
            fetch: { try await driver.fetchAllTriggers(schema: nil) }
        )
        updateSideObjects(connectionId) { $0.triggers = $0.triggers.settled(by: outcome, discardingValue: false) }
        bumpGeneration(connectionId)
        return outcome.didFetch
    }

    @discardableResult
    func reloadUserDefinedTypes(connectionId: UUID, driver: DatabaseDriver, scope: DatabaseScope?) async -> Bool {
        updateSideObjects(connectionId) { $0.userDefinedTypes = $0.userDefinedTypes.enteringLoad }
        bumpGeneration(connectionId)
        let outcome = await Self.fetchObjectsSafely(
            key: LoadKey(connectionId: connectionId, scope: scope),
            connectionId: connectionId,
            label: "types",
            dedup: typesDedup,
            fetch: { try await driver.fetchUserDefinedTypes(schema: nil) }
        )
        updateSideObjects(connectionId) {
            $0.userDefinedTypes = $0.userDefinedTypes.settled(by: outcome, discardingValue: false)
        }
        bumpGeneration(connectionId)
        return outcome.didFetch
    }

    /// Cancels in-flight fetches while keeping cached content on screen, so a
    /// refresh never blanks a sidebar that already has valid data.
    func prepareForReload(connectionId: UUID) async {
        await cancelInFlightLoads(connectionId: connectionId)
    }

    private func cancelInFlightLoads(connectionId: UUID) async {
        await loadDedup.cancel { $0.connectionId == connectionId }
        await routinesDedup.cancel { $0.connectionId == connectionId }
        await triggersDedup.cancel { $0.connectionId == connectionId }
        await typesDedup.cancel { $0.connectionId == connectionId }
        await schemasDedup.cancel { $0.connectionId == connectionId }
        await perSchemaDedup.cancel { $0.connectionId == connectionId }
        await perSchemaRoutinesDedup.cancel { $0.connectionId == connectionId }
        await perSchemaTriggersDedup.cancel { $0.connectionId == connectionId }
        await perSchemaTypesDedup.cancel { $0.connectionId == connectionId }
    }

    func invalidate(connectionId: UUID) async {
        await cancelInFlightLoads(connectionId: connectionId)
        loadGenerations.removeValue(forKey: connectionId)
        schemaLoadGenerations = schemaLoadGenerations.filter { $0.key.connectionId != connectionId }
        refreshingConnections.remove(connectionId)
        states.removeValue(forKey: connectionId)
        sideObjects.removeValue(forKey: connectionId)
        schemasInOrder.removeValue(forKey: connectionId)
        perSchemaStates.removeValue(forKey: connectionId)
        perSchemaSideObjects.removeValue(forKey: connectionId)
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
        let kinds = SideKinds(connection.type)
        updateSideObjects(connectionId) { $0 = Self.enteringLoad($0, kinds: kinds) }
        bumpGeneration(connectionId)

        /// Keeping the previous routines is only right for a refresh of the same scope. When the
        /// scope moved, routines fetched from the database being left do not describe the one
        /// being entered, and showing them is worse than showing none.
        let scopeChanged = scope != nil && loadedScopes[connectionId] != scope

        let supportsSchemas = PluginManager.shared.supportsSchemaSwitching(for: connection.type)
        if !supportsSchemas {
            schemasInOrder.removeValue(forKey: connectionId)
        }

        let loadKey = LoadKey(connectionId: connectionId, scope: scope)
        let grouping = PluginManager.shared.databaseGroupingStrategy(for: connection.type)
        if grouping == .hierarchicalSchema {
            await runHierarchicalLoad(
                loadKey: loadKey,
                driver: driver,
                kinds: kinds,
                scopeChanged: scopeChanged,
                generation: generation
            )
            return
        }

        async let tablesTask: [TableInfo] = loadDedup.execute(key: loadKey) {
            try await driver.fetchTables()
        }
        async let routinesTask: MetadataFetchOutcome<[RoutineInfo]> = Self.fetchObjectsSafely(
            key: loadKey,
            connectionId: connectionId,
            label: "routines",
            dedup: routinesDedup,
            fetch: { try await driver.fetchRoutines(schema: nil) }
        )
        async let triggersTask: MetadataFetchOutcome<[TriggerInfo]>? = kinds.triggers
            ? Self.fetchObjectsSafely(
                key: loadKey,
                connectionId: connectionId,
                label: "triggers",
                dedup: triggersDedup,
                fetch: { try await driver.fetchAllTriggers(schema: nil) }
            )
            : nil
        async let typesTask: MetadataFetchOutcome<[UserDefinedTypeInfo]>? = kinds.types
            ? Self.fetchObjectsSafely(
                key: loadKey,
                connectionId: connectionId,
                label: "types",
                dedup: typesDedup,
                fetch: { try await driver.fetchUserDefinedTypes(schema: nil) }
            )
            : nil
        async let schemasTask: [String]? = supportsSchemas
            ? Self.fetchSchemasSafely(
                key: loadKey,
                dedup: schemasDedup,
                fetch: { try await driver.fetchSchemas() }
            )
            : nil

        /// Tables are committed the moment they arrive and the other kinds settle behind them, so a
        /// failed tables fetch still settles routines, triggers and types instead of leaving each
        /// section on a spinner no load is coming to replace.
        var tablesLoaded = false
        do {
            let tables = try await tablesTask
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "tables-loaded") else {
                return
            }
            states[connectionId] = .loaded(tables)
            bumpGeneration(connectionId)
            tablesLoaded = true
        } catch is CancellationError {
            abandonSideLoads(connectionId, generation: generation)
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

        let routinesOutcome = await routinesTask
        let triggersOutcome = await triggersTask
        let typesOutcome = await typesTask
        guard isCurrentLoadGeneration(generation, for: connectionId, phase: "side-objects-loaded") else {
            return
        }
        commitSideObjects(
            connectionId,
            routines: routinesOutcome,
            triggers: triggersOutcome,
            types: typesOutcome,
            discardingValue: scopeChanged
        )

        if let loadedSchemas = await schemasTask {
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "schemas-loaded") else {
                return
            }
            schemasInOrder[connectionId] = loadedSchemas
        }
        if tablesLoaded, let scope {
            loadedScopes[connectionId] = scope
        }
        bumpGeneration(connectionId)
    }

    private func runHierarchicalLoad(
        loadKey: LoadKey,
        driver: DatabaseDriver,
        kinds: SideKinds,
        scopeChanged: Bool,
        generation: Int
    ) async {
        let connectionId = loadKey.connectionId
        let scope = loadKey.scope
        async let routinesTask: MetadataFetchOutcome<[RoutineInfo]> = Self.fetchObjectsSafely(
            key: loadKey,
            connectionId: connectionId,
            label: "routines",
            dedup: routinesDedup,
            fetch: { try await driver.fetchRoutines(schema: nil) }
        )
        async let triggersTask: MetadataFetchOutcome<[TriggerInfo]>? = kinds.triggers
            ? Self.fetchObjectsSafely(
                key: loadKey,
                connectionId: connectionId,
                label: "triggers",
                dedup: triggersDedup,
                fetch: { try await driver.fetchAllTriggers(schema: nil) }
            )
            : nil
        async let typesTask: MetadataFetchOutcome<[UserDefinedTypeInfo]>? = kinds.types
            ? Self.fetchObjectsSafely(
                key: loadKey,
                connectionId: connectionId,
                label: "types",
                dedup: typesDedup,
                fetch: { try await driver.fetchUserDefinedTypes(schema: nil) }
            )
            : nil

        let routinesOutcome = await routinesTask
        let triggersOutcome = await triggersTask
        let typesOutcome = await typesTask

        let loadedSchemas: [String]
        do {
            loadedSchemas = try await schemasDedup.execute(key: loadKey) {
                try await driver.fetchSchemas()
            }
        } catch is CancellationError {
            abandonSideLoads(connectionId, generation: generation)
            return
        } catch {
            guard isCurrentLoadGeneration(generation, for: connectionId, phase: "hierarchical-failed") else {
                return
            }
            Self.logger.warning(
                "[schema] hierarchical schema list failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            commitSideObjects(
                connectionId,
                routines: routinesOutcome,
                triggers: triggersOutcome,
                types: typesOutcome,
                discardingValue: scopeChanged
            )
            markLoadFailed(connectionId: connectionId, message: error.localizedDescription)
            return
        }

        guard isCurrentLoadGeneration(generation, for: connectionId, phase: "hierarchical-loaded") else {
            return
        }
        schemasInOrder[connectionId] = loadedSchemas
        commitSideObjects(
            connectionId,
            routines: routinesOutcome,
            triggers: triggersOutcome,
            types: typesOutcome,
            discardingValue: scopeChanged
        )
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
        key: LoadKey,
        dedup: OnceTask<LoadKey, [String]>,
        fetch: @Sendable @escaping () async throws -> [String]
    ) async -> [String]? {
        do {
            return try await dedup.execute(key: key, work: fetch)
        } catch is CancellationError {
            return nil
        } catch {
            Self.logger.warning(
                "[schema] fetchSchemas failed connId=\(key.connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// A failure comes back as a failure, never as an empty list. An empty list made a refresh that
    /// failed indistinguishable from a database with no routines, and the caller committed it over
    /// the loaded one: a single dropped connection emptied the sidebar's procedures and functions
    /// while the refresh reported success, with nothing scheduled to put them back.
    private static func fetchObjectsSafely<Key: Hashable & Sendable, Value: Sendable>(
        key: Key,
        connectionId: UUID,
        label: String,
        dedup: OnceTask<Key, [Value]>,
        fetch: @Sendable @escaping () async throws -> [Value]
    ) async -> MetadataFetchOutcome<[Value]> {
        do {
            return .fetched(try await dedup.execute(key: key, work: fetch))
        } catch is CancellationError {
            return .cancelled
        } catch {
            logger.warning(
                "[schema] \(label, privacy: .public) load failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
    }
}
