//
//  SchemaService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

@MainActor
final class SchemaService: ObservableObject {
    static let shared = SchemaService()

    /// The object kinds that are not tables, each behind its own load state so a list that is still
    /// coming, a list that failed and a list that came back empty stay three different answers.
    struct SideObjects: Sendable {
        var routines: MetadataLoadState<[RoutineInfo]> = .idle
        var triggers: MetadataLoadState<[TriggerInfo]> = .idle
        var userDefinedTypes: MetadataLoadState<[UserDefinedTypeInfo]> = .idle
    }

    @Published private(set) var states: [UUID: SchemaState] = [:]
    @Published private(set) var sideObjects: [UUID: SideObjects] = [:]
    @Published private(set) var schemasInOrder: [UUID: [String]] = [:]
    @Published private(set) var perSchemaStates: [SchemaKey: SchemaState] = [:]
    @Published private(set) var perSchemaSideObjects: [SchemaKey: SideObjects] = [:]
    @Published private(set) var generations: [UUID: Int] = [:]
    @Published private(set) var refreshingConnections: Set<UUID> = []
    @Published private(set) var loadedScopes: [UUID: DatabaseScope] = [:]

    func generationToken(for connectionId: UUID) -> Int {
        generations[connectionId] ?? 0
    }

    private func bumpGeneration(_ connectionId: UUID) {
        generations[connectionId, default: 0] &+= 1
    }

    private let loadDedup = OnceTask<LoadKey, [TableInfo]>()
    private let routinesDedup = OnceTask<LoadKey, [RoutineInfo]>()
    private let triggersDedup = OnceTask<LoadKey, [TriggerInfo]>()
    private let typesDedup = OnceTask<LoadKey, [UserDefinedTypeInfo]>()
    private let schemasDedup = OnceTask<LoadKey, [String]>()
    private let perSchemaDedup = OnceTask<SchemaKey, [TableInfo]>()
    private let perSchemaRoutinesDedup = OnceTask<SchemaKey, [RoutineInfo]>()
    private let perSchemaTriggersDedup = OnceTask<SchemaKey, [TriggerInfo]>()
    private let perSchemaTypesDedup = OnceTask<SchemaKey, [UserDefinedTypeInfo]>()

    /// A schema is named inside a database, and an engine that changes database on a live
    /// connection reaches a `PUBLIC` in every one of them.
    struct SchemaKey: Hashable, Sendable {
        let connectionId: UUID
        let database: String
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

    private var loadGenerations: [UUID: Int] = [:]
    private var schemaLoadGenerations: [SchemaKey: Int] = [:]
    private var refreshWaiters: [UUID: [RefreshWaiter]] = [:]
    private var nextLoadGeneration = 0
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaService")

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
        guard case .loaded = state(for: connectionId),
              loadedScopes[connectionId]?.database == scope.database else { return }
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
        hasLoadedContent(catalogKey(connectionId, schema: schema))
    }

    private func hasLoadedContent(_ key: SchemaKey) -> Bool {
        if case .loaded = perSchemaStates[key] { return true }
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
        perSchemaStates[catalogKey(connectionId, schema: schema)] ?? .idle
    }

    /// Every per-schema read answers for the database `schemas(for:)` was listed from, so the
    /// schema rows and the objects under them describe one database even while a switch settles.
    private func catalogKey(_ connectionId: UUID, schema: String) -> SchemaKey {
        SchemaKey(connectionId: connectionId, database: catalogDatabase(connectionId), schema: schema)
    }

    private func catalogDatabase(_ connectionId: UUID) -> String {
        loadedScopes[connectionId]?.database ?? ""
    }

    private func catalogEntries<Value>(_ entries: [SchemaKey: Value], of connectionId: UUID) -> [String: Value] {
        let database = catalogDatabase(connectionId)
        var result: [String: Value] = [:]
        for (key, value) in entries where key.connectionId == connectionId && key.database == database {
            result[key.schema] = value
        }
        return result
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
        let key = catalogKey(connectionId, schema: schema)
        guard hasLoadedContent(key) else { return false }
        let side = perSchemaSideObjects[key] ?? SideObjects()
        return [side.routines.erased, side.triggers.erased, side.userDefinedTypes.erased]
            .allSatisfy { $0 == .loaded || $0 == .idle }
    }

    func routinesLoadState(for connectionId: UUID, schema: String) -> MetadataLoadState<[RoutineInfo]> {
        perSchemaSideObjects[catalogKey(connectionId, schema: schema)]?.routines ?? .idle
    }

    func triggersLoadState(for connectionId: UUID, schema: String) -> MetadataLoadState<[TriggerInfo]> {
        perSchemaSideObjects[catalogKey(connectionId, schema: schema)]?.triggers ?? .idle
    }

    func userDefinedTypesLoadState(
        for connectionId: UUID,
        schema: String
    ) -> MetadataLoadState<[UserDefinedTypeInfo]> {
        perSchemaSideObjects[catalogKey(connectionId, schema: schema)]?.userDefinedTypes ?? .idle
    }

    /// The schemas whose own table list is loaded, empty ones included, which is what a caller
    /// merging another source needs: an empty schema here is an answer, not a gap.
    func schemasWithLoadedTables(for connectionId: UUID) -> Set<String> {
        Set(catalogEntries(perSchemaStates, of: connectionId).compactMap { schema, state in
            guard case .loaded = state else { return nil }
            return schema
        })
    }

    /// Flat tables plus the union of every loaded per-schema table list. For
    /// hierarchicalSchema plugins the flat list is empty and this is the only
    /// way to see tables across schemas (e.g. for autocomplete).
    func allLoadedTables(for connectionId: UUID) -> [TableInfo] {
        var result = tables(for: connectionId)
        var seen = Set(result.map(\.id))
        for state in catalogEntries(perSchemaStates, of: connectionId).values {
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
        guard let scope = schemaRouteScope(connectionId: connectionId, database: database) else { return }
        guard !hasLoadedContent(SchemaKey(scope: scope, schema: schema)) else { return }
        await withSchemaMetadataDriver(scope: scope, schema: schema) { driver in
            await self.loadSchemaObjects(schema: schema, in: scope, driver: driver)
        }
    }

    func reloadSchemaObjects(connectionId: UUID, schema: String, database: String?) async {
        guard let scope = schemaRouteScope(connectionId: connectionId, database: database) else { return }
        await withSchemaMetadataDriver(scope: scope, schema: schema) { driver in
            await self.reloadSchemaObjects(schema: schema, in: scope, driver: driver)
        }
    }

    private func schemaRouteScope(connectionId: UUID, database: String?) -> DatabaseScope? {
        DatabaseManager.shared.resolvedScope(database: database, schema: nil, for: connectionId)
    }

    private func withSchemaMetadataDriver(
        scope: DatabaseScope,
        schema: String,
        _ body: @Sendable @escaping (DatabaseDriver) async -> Void
    ) async {
        do {
            try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk, body)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] per-schema route failed connId=\(scope.connectionId, privacy: .public) schema=\(schema, privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
            commitSchemaTables(.failed(error.localizedDescription), key: SchemaKey(scope: scope, schema: schema))
        }
    }

    /// `scope` names the database `driver` reads, which is the database the objects are kept under.
    func loadSchemaObjects(schema: String, in scope: DatabaseScope, driver: DatabaseDriver) async {
        let key = SchemaKey(scope: scope, schema: schema)
        guard !hasLoadedContent(key) else { return }
        await runSchemaLoad(key, driver: driver)
    }

    func reloadSchemaObjects(schema: String, in scope: DatabaseScope, driver: DatabaseDriver) async {
        let key = SchemaKey(scope: scope, schema: schema)
        schemaLoadGenerations.removeValue(forKey: key)
        await cancelSchemaLoads { $0 == key }
        await runSchemaLoad(key, driver: driver)
    }

    /// Re-fetches every schema of `scope`'s database the user has already expanded, in place.
    /// Without this a non-destructive refresh would leave those lists showing pre-refresh contents.
    func refreshLoadedSchemaObjects(in scope: DatabaseScope, driver: DatabaseDriver) async {
        /// A schema still loading is reloaded too. Its fetch may have begun before the change this
        /// refresh answers, and reloading moves its generation so that fetch cannot commit.
        let loadedSchemas = perSchemaStates.compactMap { key, state -> String? in
            guard key.connectionId == scope.connectionId, key.database == scope.database else { return nil }
            switch state {
            case .loaded, .loading: return key.schema
            case .idle, .failed: return nil
            }
        }
        for schema in loadedSchemas.sorted() {
            await reloadSchemaObjects(schema: schema, in: scope, driver: driver)
        }
    }

    private func runSchemaLoad(_ key: SchemaKey, driver: DatabaseDriver) async {
        let connectionId = key.connectionId
        let schema = key.schema
        nextLoadGeneration += 1
        let generation = nextLoadGeneration
        schemaLoadGenerations[key] = generation
        let kinds = SideKinds(driver.connection.type)

        if !hasLoadedContent(key) {
            setPerSchemaState(.loading, key: key)
        }
        updateSchemaSideObjects(key) { $0 = Self.enteringLoad($0, kinds: kinds) }
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
                "[schema] per-schema load failed connId=\(connectionId, privacy: .public) schema=\(schema, privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
            tablesOutcome = .failed(error.localizedDescription)
        }
        guard schemaLoadGenerations[key] == generation else { return }
        commitSchemaTables(tablesOutcome, key: key)

        let routinesOutcome = await routinesTask
        let triggersOutcome = await triggersTask
        let typesOutcome = await typesTask
        guard schemaLoadGenerations[key] == generation else { return }
        schemaLoadGenerations.removeValue(forKey: key)
        updateSchemaSideObjects(key) { side in
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

    private func commitSchemaTables(_ outcome: MetadataFetchOutcome<[TableInfo]>, key: SchemaKey) {
        switch outcome {
        case .fetched(let tables):
            setPerSchemaState(.loaded(tables), key: key)
        case .failed(let message):
            guard !hasLoadedContent(key) else { return }
            setPerSchemaState(.failed(message), key: key)
        case .cancelled:
            guard case .loading = perSchemaStates[key] else { return }
            setPerSchemaState(.idle, key: key)
        }
    }

    private func setPerSchemaState(_ state: SchemaState, key: SchemaKey) {
        perSchemaStates[key] = state
        bumpGeneration(key.connectionId)
    }

    private func cancelSchemaLoads(where shouldCancel: @escaping @Sendable (SchemaKey) -> Bool) async {
        await perSchemaDedup.cancel(where: shouldCancel)
        await perSchemaRoutinesDedup.cancel(where: shouldCancel)
        await perSchemaTriggersDedup.cancel(where: shouldCancel)
        await perSchemaTypesDedup.cancel(where: shouldCancel)
    }

    /// The per-schema lists of a database the connection has moved off describe nothing it shows,
    /// and a fetch still running for one of them finds its generation gone and commits nothing.
    private func discardSchemaObjects(of connectionId: UUID, outside database: String) async {
        let isOutside: (SchemaKey) -> Bool = { $0.connectionId == connectionId && $0.database != database }
        let discarded = Set(perSchemaStates.keys.filter(isOutside))
            .union(perSchemaSideObjects.keys.filter(isOutside))
            .union(schemaLoadGenerations.keys.filter(isOutside))
        guard !discarded.isEmpty else { return }
        perSchemaStates = perSchemaStates.filter { !discarded.contains($0.key) }
        perSchemaSideObjects = perSchemaSideObjects.filter { !discarded.contains($0.key) }
        schemaLoadGenerations = schemaLoadGenerations.filter { !discarded.contains($0.key) }
        await cancelSchemaLoads { discarded.contains($0) }
    }

    private func updateSideObjects(_ connectionId: UUID, _ change: (inout SideObjects) -> Void) {
        var side = sideObjects[connectionId] ?? SideObjects()
        change(&side)
        sideObjects[connectionId] = side
    }

    private func updateSchemaSideObjects(_ key: SchemaKey, _ change: (inout SideObjects) -> Void) {
        var side = perSchemaSideObjects[key] ?? SideObjects()
        change(&side)
        perSchemaSideObjects[key] = side
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
        perSchemaStates = perSchemaStates.filter { $0.key.connectionId != connectionId }
        perSchemaSideObjects = perSchemaSideObjects.filter { $0.key.connectionId != connectionId }
        generations.removeValue(forKey: connectionId)
        loadedScopes.removeValue(forKey: connectionId)
        resumeRefreshWaiters(connectionId)
    }

    /// Leased rather than handed the session driver, which is wherever a tab's execution last
    /// pinned it. The object list follows the browse cursor, so reading from the shared handle
    /// refreshed the sidebar with a container the user was not browsing.
    func refresh(connectionId: UUID) async {
        guard let session = DatabaseManager.shared.activeSessions[connectionId],
              let scope = DatabaseManager.shared.browseScope(for: connectionId) else {
            markLoadFailed(
                connectionId: connectionId,
                message: String(localized: "The connection is not available. Reconnect and try again."),
                scope: nil
            )
            return
        }
        await prepareForReload(connectionId: connectionId)
        let connection = session.connection
        do {
            try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk) { [self] driver in
                await reload(
                    connectionId: connectionId,
                    driver: driver,
                    connection: connection,
                    scope: scope
                )
            }
        } catch {
            markLoadFailed(connectionId: connectionId, message: error.localizedDescription, scope: scope)
        }
    }

    /// For a load that failed before it could run, so no fetch is left to settle the other object
    /// kinds. When the failed scope is not the one the loaded objects came from, as after a database
    /// switch, every kind reports the failure instead of showing the database being left.
    func markLoadFailed(connectionId: UUID, message: String, scope: DatabaseScope?) {
        let leftLoadedScope = hasLeftLoadedScope(connectionId, for: scope)
        guard settleTablesFailed(connectionId, message: message, leftLoadedScope: leftLoadedScope) else { return }
        if leftLoadedScope {
            updateSideObjects(connectionId) { $0 = Self.failed($0, message: message) }
        }
        bumpGeneration(connectionId)
    }

    /// No recorded scope proves nothing about where the held objects came from: a table fetch that
    /// failed for the database being browsed clears it while that database's routines still load.
    private func hasLeftLoadedScope(_ connectionId: UUID, for scope: DatabaseScope?) -> Bool {
        guard let scope, let loadedScope = loadedScopes[connectionId] else { return false }
        return loadedScope != scope
    }

    /// Returns false when nothing changed, so a refresh that failed over tables it keeps publishes nothing.
    private func settleTablesFailed(_ connectionId: UUID, message: String, leftLoadedScope: Bool) -> Bool {
        let current = state(for: connectionId)
        let next = current.settled(byFailure: message, discardingValue: leftLoadedScope)
        guard next != current || leftLoadedScope else { return false }
        states[connectionId] = next
        if leftLoadedScope {
            loadedScopes.removeValue(forKey: connectionId)
        }
        return true
    }

    /// A kind still idle was never browsed for this connection, so there is no fetch to report as failed.
    private static func failed(_ side: SideObjects, message: String) -> SideObjects {
        var next = side
        next.routines = failed(side.routines, message: message)
        next.triggers = failed(side.triggers, message: message)
        next.userDefinedTypes = failed(side.userDefinedTypes, message: message)
        return next
    }

    private static func failed<Value>(_ state: MetadataLoadState<Value>, message: String) -> MetadataLoadState<Value> {
        if case .idle = state { return .idle }
        return state.settled(by: .failed(message), discardingValue: true)
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
                "[schema] load failed connId=\(connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
            if settleTablesFailed(connectionId, message: error.localizedDescription, leftLoadedScope: scopeChanged) {
                bumpGeneration(connectionId)
            }
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
            await adoptLoadedScope(scope)
        }
        bumpGeneration(connectionId)
    }

    private func adoptLoadedScope(_ scope: DatabaseScope) async {
        loadedScopes[scope.connectionId] = scope
        await discardSchemaObjects(of: scope.connectionId, outside: scope.database)
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
                "[schema] hierarchical schema list failed connId=\(connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
            commitSideObjects(
                connectionId,
                routines: routinesOutcome,
                triggers: triggersOutcome,
                types: typesOutcome,
                discardingValue: scopeChanged
            )
            if settleTablesFailed(connectionId, message: error.localizedDescription, leftLoadedScope: scopeChanged) {
                bumpGeneration(connectionId)
            }
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
            await adoptLoadedScope(scope)
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
                "[schema] fetchSchemas failed connId=\(key.connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
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
                "[schema] \(label, privacy: .public) load failed connId=\(connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
    }
}

extension SchemaService.SchemaKey {
    init(scope: DatabaseScope, schema: String) {
        self.init(connectionId: scope.connectionId, database: scope.database, schema: schema)
    }
}
