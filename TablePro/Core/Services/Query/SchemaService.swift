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

    @Published private(set) var states: [CatalogKey: SchemaState] = [:]
    @Published private(set) var sideObjects: [CatalogKey: SideObjects] = [:]
    @Published private(set) var schemasInOrder: [CatalogKey: [String]] = [:]
    @Published private(set) var perSchemaStates: [SchemaKey: SchemaState] = [:]
    @Published private(set) var perSchemaSideObjects: [SchemaKey: SideObjects] = [:]
    @Published private(set) var generations: [UUID: Int] = [:]
    @Published private(set) var refreshingConnections: Set<UUID> = []
    @Published private var shownCatalogs: [UUID: ShownCatalog] = [:]

    /// Each database a connection browses keeps its own catalog, so switching back to one shows what
    /// it held instead of fetching it from nothing. An engine grouped by schema lists one schema's
    /// objects, so it keeps one per schema; a hierarchical engine names the schema of every per-schema
    /// list itself, so it keeps one per database like the rest.
    struct CatalogKey: Hashable, Sendable {
        let connectionId: UUID
        let database: String
        let schema: String?
    }

    private struct ShownCatalog: Equatable {
        let key: CatalogKey
        let scope: DatabaseScope
    }

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
    private let perSchemaDedup = OnceTask<SchemaFetchKey, [TableInfo]>()
    private let perSchemaRoutinesDedup = OnceTask<SchemaFetchKey, [RoutineInfo]>()
    private let perSchemaTriggersDedup = OnceTask<SchemaFetchKey, [TriggerInfo]>()
    private let perSchemaTypesDedup = OnceTask<SchemaFetchKey, [UserDefinedTypeInfo]>()

    /// A schema is named inside a database, and an engine that changes database on a live
    /// connection reaches a `PUBLIC` in every one of them.
    struct SchemaKey: Hashable, Sendable {
        let connectionId: UUID
        let database: String
        let schema: String
    }

    /// A read after a catalog change starts a fetch of its own rather than joining one that began
    /// before the change.
    struct SchemaFetchKey: Hashable, Sendable {
        let schemaKey: SchemaKey
        let revision: Int
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

    private var loadGenerations: [CatalogKey: Int] = [:]
    private var refreshGenerations: [UUID: Int] = [:]
    /// The newest switch, or load of the browsed scope, per connection: the only one that may move
    /// what the connection shows.
    private var shownClaims: [UUID: Int] = [:]
    /// Catalogs kept from an earlier visit and shown again, which no load has refreshed since.
    private var unrefreshedCatalogs: Set<CatalogKey> = []
    private var schemaLoadGenerations: [SchemaKey: Int] = [:]
    private var schemaFreshness = CatalogFreshness<SchemaKey>()
    private var refreshWaiters: [UUID: [RefreshWaiter]] = [:]
    private var nextLoadGeneration = 0
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaService")

    func state(for connectionId: UUID) -> SchemaState {
        states[shownKey(connectionId)] ?? .idle
    }

    func isRefreshing(connectionId: UUID) -> Bool {
        refreshingConnections.contains(connectionId)
    }

    func loadedScope(for connectionId: UUID) -> DatabaseScope? {
        guard hasLoadedContent(for: connectionId) else { return nil }
        return shownCatalogs[connectionId]?.scope
    }

    /// False while the catalog on screen is one kept from an earlier visit that no load has refreshed
    /// since: it can still list an object dropped, or lack one created, while the connection was away.
    func isCatalogCurrent(for connectionId: UUID) -> Bool {
        !unrefreshedCatalogs.contains(shownKey(connectionId))
    }

    private func shownKey(_ connectionId: UUID) -> CatalogKey {
        shownCatalogs[connectionId]?.key ?? CatalogKey(connectionId: connectionId, database: "", schema: nil)
    }

    private func catalogKey(for scope: DatabaseScope, type: DatabaseType?) -> CatalogKey {
        let keepsSchema = type.map { PluginManager.shared.databaseGroupingStrategy(for: $0) == .bySchema } ?? false
        return CatalogKey(
            connectionId: scope.connectionId,
            database: scope.database,
            schema: keepsSchema ? scope.schema : nil
        )
    }

    /// A connection with no session has no browse cursor to disagree with.
    private func isBrowsed(_ key: CatalogKey, type: DatabaseType?) -> Bool {
        guard let browseScope = DatabaseManager.shared.browseScope(for: key.connectionId) else { return true }
        return catalogKey(for: browseScope, type: type) == key
    }

    /// Shows the catalog kept for `scope`, in the turn the browse cursor moves there: a database browsed
    /// before shows what it held at once, and one never browsed shows nothing loaded rather than the
    /// previous database's objects under its name. A load still running for the scope left writes that
    /// scope's catalog and moves nothing.
    func show(scope: DatabaseScope, type: DatabaseType) {
        showCatalog(catalogKey(for: scope, type: type), scope: scope)
        bumpGeneration(scope.connectionId)
    }

    @discardableResult
    private func showCatalog(_ key: CatalogKey, scope: DatabaseScope) -> Bool {
        nextLoadGeneration += 1
        shownClaims[key.connectionId] = nextLoadGeneration
        return point(key.connectionId, at: key, scope: scope)
    }

    /// A catalog kept from an earlier visit is not current until a load for it commits. The per-schema
    /// lists of the database left are kept as well, and nothing refreshes them while it is away, so
    /// the first reader after a return reads them again.
    @discardableResult
    private func point(_ connectionId: UUID, at key: CatalogKey, scope: DatabaseScope) -> Bool {
        let shown = ShownCatalog(key: key, scope: scope)
        let previous = shownCatalogs[connectionId]
        guard previous != shown else { return false }
        shownCatalogs[connectionId] = shown
        guard let previous, previous.key != key else { return true }
        if hasLoadedContent(key) {
            unrefreshedCatalogs.insert(key)
        }
        guard previous.key.database != key.database else { return true }
        for schemaKey in perSchemaStates.keys
        where schemaKey.connectionId == connectionId && schemaKey.database == previous.key.database
            && holdsOrIsLoading(schemaKey) {
            schemaFreshness.markChanged(schemaKey)
        }
        return true
    }

    /// A load of the scope the connection browses becomes what it shows: at once when nothing loaded
    /// is on screen, otherwise once it settles, so a refresh keeps the catalog it refreshes on screen.
    private func claimShown(_ key: CatalogKey, scope: DatabaseScope?, generation: Int, type: DatabaseType) {
        guard let scope, isBrowsed(key, type: type) else { return }
        shownClaims[key.connectionId] = generation
        if !hasLoadedContent(for: key.connectionId) {
            point(key.connectionId, at: key, scope: scope)
        }
    }

    /// A load that a switch or a newer load overtook, or one for a scope the connection has since left,
    /// writes its own catalog and moves nothing.
    @discardableResult
    private func adoptShown(_ key: CatalogKey, scope: DatabaseScope?, generation: Int, type: DatabaseType) -> Bool {
        guard let scope, shownClaims[key.connectionId] == generation, isBrowsed(key, type: type) else { return false }
        return point(key.connectionId, at: key, scope: scope)
    }

    /// Drops every catalog kept for `database`, whose entry closed or which the server dropped or
    /// renamed. A load still running for it finds its generation gone and commits nothing.
    func forget(database: String, connectionId: UUID) {
        let isForgotten: (CatalogKey) -> Bool = { $0.connectionId == connectionId && $0.database == database }
        let isForgottenSchema: (SchemaKey) -> Bool = { $0.connectionId == connectionId && $0.database == database }
        states = states.filter { !isForgotten($0.key) }
        sideObjects = sideObjects.filter { !isForgotten($0.key) }
        schemasInOrder = schemasInOrder.filter { !isForgotten($0.key) }
        loadGenerations = loadGenerations.filter { !isForgotten($0.key) }
        unrefreshedCatalogs = unrefreshedCatalogs.filter { !isForgotten($0) }
        perSchemaStates = perSchemaStates.filter { !isForgottenSchema($0.key) }
        perSchemaSideObjects = perSchemaSideObjects.filter { !isForgottenSchema($0.key) }
        schemaLoadGenerations = schemaLoadGenerations.filter { !isForgottenSchema($0.key) }
        schemaFreshness.removeAll(where: isForgottenSchema)
        bumpGeneration(connectionId)
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
              let shown = shownCatalogs[connectionId],
              shown.scope.database == scope.database else { return }
        shownCatalogs[connectionId] = ShownCatalog(key: shown.key, scope: scope)
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

    private func hasLoadedContent(_ key: CatalogKey) -> Bool {
        if case .loaded = states[key] { return true }
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
        sideObjects[shownKey(connectionId)]?.routines ?? .idle
    }

    func triggersLoadState(for connectionId: UUID) -> MetadataLoadState<[TriggerInfo]> {
        sideObjects[shownKey(connectionId)]?.triggers ?? .idle
    }

    func userDefinedTypesLoadState(for connectionId: UUID) -> MetadataLoadState<[UserDefinedTypeInfo]> {
        sideObjects[shownKey(connectionId)]?.userDefinedTypes ?? .idle
    }

    func schemas(for connectionId: UUID) -> [String] {
        schemasInOrder[shownKey(connectionId)] ?? []
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
        shownKey(connectionId).database
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

    /// The loaded schemas read since the last catalog change. A list read before it may still hold
    /// a table that was dropped or lack one that was created, so it cannot say whether one exists.
    func schemasWithCurrentTables(for connectionId: UUID) -> Set<String> {
        schemasWithLoadedTables(for: connectionId).filter { isSchemaCurrent(for: connectionId, schema: $0) }
    }

    func isSchemaCurrent(for connectionId: UUID, schema: String) -> Bool {
        schemaFreshness.isCurrent(catalogKey(connectionId, schema: schema))
    }

    /// Whether a reader showing this schema should fetch it: it was never read, or a catalog change
    /// has overtaken what was, and no fetch has started since.
    func schemaObjectsNeedFetch(for connectionId: UUID, schema: String) -> Bool {
        schemaFreshness.needsFetch(catalogKey(connectionId, schema: schema))
    }

    /// Flat tables plus the union of every loaded per-schema table list. For
    /// hierarchicalSchema plugins the flat list is empty and this is the only
    /// way to see tables across schemas (e.g. for autocomplete).
    func allLoadedTables(for connectionId: UUID) -> [TableInfo] {
        loadedTables(for: connectionId) { _ in true }
    }

    /// `allLoadedTables` without the lists a catalog change has overtaken, for a caller judging
    /// whether an object still exists.
    func currentTables(for connectionId: UUID) -> [TableInfo] {
        loadedTables(for: connectionId) { self.isSchemaCurrent(for: connectionId, schema: $0) }
    }

    private func loadedTables(for connectionId: UUID, inSchemas includes: (String) -> Bool) -> [TableInfo] {
        var result = tables(for: connectionId)
        var seen = Set(result.map(\.id))
        for (schema, state) in catalogEntries(perSchemaStates, of: connectionId) where includes(schema) {
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
        guard !schemaFreshness.isCurrent(SchemaKey(scope: scope, schema: schema)) else { return }
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

    /// The fetch counts as started from the moment it asks for a driver, so a reader redrawing while
    /// the lease is pending does not ask for a second one.
    private func withSchemaMetadataDriver(
        scope: DatabaseScope,
        schema: String,
        _ body: @Sendable @escaping (DatabaseDriver) async -> Void
    ) async {
        let key = SchemaKey(scope: scope, schema: schema)
        let revision = schemaFreshness.revision(for: key)
        schemaFreshness.noteFetchStarted(revision, for: key)
        do {
            try await DatabaseManager.shared.withMetadataDriver(scope: scope, workload: .bulk, body)
        } catch is CancellationError {
            schemaFreshness.noteFetchAbandoned(revision, for: key)
        } catch {
            Self.logger.warning(
                "[schema] per-schema route failed connId=\(scope.connectionId, privacy: .public) schema=\(schema, privacy: .private(mask: .hash)) error=\(error.publicLogShape, privacy: .public)"
            )
            settleSchemaFailure(error.localizedDescription, key: key)
        }
    }

    /// `scope` names the database `driver` reads, which is the database the objects are kept under.
    /// A schema already read since the last catalog change is not read again.
    func loadSchemaObjects(schema: String, in scope: DatabaseScope, driver: DatabaseDriver) async {
        let key = SchemaKey(scope: scope, schema: schema)
        guard !schemaFreshness.isCurrent(key) else { return }
        await runSchemaLoad(key, driver: driver)
    }

    func reloadSchemaObjects(schema: String, in scope: DatabaseScope, driver: DatabaseDriver) async {
        let key = SchemaKey(scope: scope, schema: schema)
        schemaFreshness.markChanged(key)
        await runSchemaLoad(key, driver: driver)
    }

    /// Marks every schema the connection has loaded as overtaken by a catalog change, keeping what
    /// each one shows, and reads again now only `fetchingNow`, the schemas something is about to
    /// judge. Every other schema is read by its next reader: an expanded tree row, or a caller of
    /// `loadSchemaObjects`. Reading them all here re-ran two to four queries per schema on every
    /// COMMIT, for lists nobody was looking at.
    func refreshLoadedSchemaObjects(
        in scope: DatabaseScope,
        fetchingNow schemas: Set<String>,
        driver: DatabaseDriver
    ) async {
        markLoadedSchemaObjectsStale(connectionId: scope.connectionId)
        for schema in schemas.sorted() where holdsOrIsLoading(SchemaKey(scope: scope, schema: schema)) {
            await loadSchemaObjects(schema: schema, in: scope, driver: driver)
        }
    }

    /// A schema still loading is marked too: its fetch may have begun before the change, so what it
    /// brings back is shown but not taken as current.
    func markLoadedSchemaObjectsStale(connectionId: UUID) {
        let marked = perSchemaStates.keys.filter { $0.connectionId == connectionId && holdsOrIsLoading($0) }
        guard !marked.isEmpty else { return }
        for key in marked {
            schemaFreshness.markChanged(key)
        }
        bumpGeneration(connectionId)
    }

    private func holdsOrIsLoading(_ key: SchemaKey) -> Bool {
        switch perSchemaStates[key] {
        case .loaded, .loading: return true
        case .idle, .failed, nil: return false
        }
    }

    private func runSchemaLoad(_ key: SchemaKey, driver: DatabaseDriver) async {
        let connectionId = key.connectionId
        let schema = key.schema
        let revision = schemaFreshness.revision(for: key)
        let fetchKey = SchemaFetchKey(schemaKey: key, revision: revision)
        schemaFreshness.noteFetchStarted(revision, for: key)
        nextLoadGeneration += 1
        let generation = nextLoadGeneration
        schemaLoadGenerations[key] = generation
        let kinds = SideKinds(driver.connection.type)

        if !hasLoadedContent(key) {
            setPerSchemaState(.loading, key: key)
        }
        updateSchemaSideObjects(key) { $0 = Self.enteringLoad($0, kinds: kinds) }
        bumpGeneration(connectionId)
        await cancelSchemaLoads { $0.schemaKey == key && $0.revision != revision }

        async let tablesTask: [TableInfo] = perSchemaDedup.execute(key: fetchKey) {
            try await driver.fetchTables(schema: schema)
        }
        async let routinesTask: MetadataFetchOutcome<[RoutineInfo]> = Self.fetchObjectsSafely(
            key: fetchKey,
            connectionId: connectionId,
            label: "schema routines",
            dedup: perSchemaRoutinesDedup,
            fetch: { try await driver.fetchRoutines(schema: schema) }
        )
        async let triggersTask: MetadataFetchOutcome<[TriggerInfo]>? = kinds.triggers
            ? Self.fetchObjectsSafely(
                key: fetchKey,
                connectionId: connectionId,
                label: "schema triggers",
                dedup: perSchemaTriggersDedup,
                fetch: { try await driver.fetchAllTriggers(schema: schema) }
            )
            : nil
        async let typesTask: MetadataFetchOutcome<[UserDefinedTypeInfo]>? = kinds.types
            ? Self.fetchObjectsSafely(
                key: fetchKey,
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
        commitSchemaTables(tablesOutcome, key: key, revision: revision)

        let routinesOutcome = await routinesTask
        let triggersOutcome = await triggersTask
        let typesOutcome = await typesTask
        guard schemaLoadGenerations[key] == generation else { return }
        schemaLoadGenerations.removeValue(forKey: key)
        updateSchemaSideObjects(key) { side in
            side = Self.settled(side, routines: routinesOutcome, triggers: triggersOutcome, types: typesOutcome)
        }
        bumpGeneration(connectionId)
    }

    private func commitSchemaTables(_ outcome: MetadataFetchOutcome<[TableInfo]>, key: SchemaKey, revision: Int) {
        switch outcome {
        case .fetched(let tables):
            setPerSchemaState(.loaded(tables), key: key)
            _ = schemaFreshness.commit(revision, for: key)
        case .failed(let message):
            settleSchemaFailure(message, key: key)
        case .cancelled:
            schemaFreshness.noteFetchAbandoned(revision, for: key)
            guard case .loading = perSchemaStates[key] else { return }
            setPerSchemaState(.idle, key: key)
        }
    }

    private func settleSchemaFailure(_ message: String, key: SchemaKey) {
        guard !hasLoadedContent(key) else { return }
        setPerSchemaState(.failed(message), key: key)
    }

    private func setPerSchemaState(_ state: SchemaState, key: SchemaKey) {
        perSchemaStates[key] = state
        bumpGeneration(key.connectionId)
    }

    private func cancelSchemaLoads(where shouldCancel: @escaping @Sendable (SchemaFetchKey) -> Bool) async {
        await perSchemaDedup.cancel(where: shouldCancel)
        await perSchemaRoutinesDedup.cancel(where: shouldCancel)
        await perSchemaTriggersDedup.cancel(where: shouldCancel)
        await perSchemaTypesDedup.cancel(where: shouldCancel)
    }

    private func updateSideObjects(_ key: CatalogKey, _ change: (inout SideObjects) -> Void) {
        var side = sideObjects[key] ?? SideObjects()
        change(&side)
        sideObjects[key] = side
    }

    /// The catalog of the scope the reload reads, not of whatever is shown when it starts: a switch
    /// while it waits for a connection would file one database's objects under another.
    private func reloadKey(_ connectionId: UUID, scope: DatabaseScope?, driver: DatabaseDriver) -> CatalogKey {
        guard let scope else { return shownKey(connectionId) }
        return catalogKey(for: scope, type: driver.connection.type)
    }

    /// A reload that lands after `forget` dropped its catalog writes nothing, rather than bringing
    /// back objects of a database whose entry closed.
    private func updateKeptSideObjects(_ key: CatalogKey, _ change: (inout SideObjects) -> Void) {
        guard var side = sideObjects[key] else { return }
        change(&side)
        sideObjects[key] = side
    }

    private func updateSchemaSideObjects(_ key: SchemaKey, _ change: (inout SideObjects) -> Void) {
        var side = perSchemaSideObjects[key] ?? SideObjects()
        change(&side)
        perSchemaSideObjects[key] = side
    }

    private func commitSideObjects(
        _ key: CatalogKey,
        routines: MetadataFetchOutcome<[RoutineInfo]>,
        triggers: MetadataFetchOutcome<[TriggerInfo]>?,
        types: MetadataFetchOutcome<[UserDefinedTypeInfo]>?
    ) {
        updateSideObjects(key) { side in
            side = Self.settled(side, routines: routines, triggers: triggers, types: types)
        }
    }

    /// A load cut short by cancellation settles the kinds it put on a spinner, unless a newer load
    /// already owns them. Left alone, a cancel with no reload behind it kept those sections waiting
    /// on a fetch nothing was running.
    private func abandonLoad(_ key: CatalogKey, generation: Int) {
        guard loadGenerations[key] == generation else { return }
        /// Nothing replaces a `.loading` that a cancelled load leaves behind: the object list shows a
        /// spinner with no Retry, and every caller that loads only what is not loaded or loading
        /// waits on it forever.
        if case .loading = states[key] {
            states[key] = .idle
        }
        updateSideObjects(key) { side in
            side.routines = side.routines.settled(by: .cancelled, discardingValue: false)
            side.triggers = side.triggers.settled(by: .cancelled, discardingValue: false)
            side.userDefinedTypes = side.userDefinedTypes.settled(by: .cancelled, discardingValue: false)
        }
        bumpGeneration(key.connectionId)
    }

    private static func enteringLoad(_ side: SideObjects, kinds: SideKinds) -> SideObjects {
        var next = side
        next.routines = side.routines.enteringLoad
        if kinds.triggers { next.triggers = side.triggers.enteringLoad }
        if kinds.types { next.userDefinedTypes = side.userDefinedTypes.enteringLoad }
        return next
    }

    /// A kind the engine was not asked for has no outcome and keeps its state.
    private static func settled(
        _ side: SideObjects,
        routines: MetadataFetchOutcome<[RoutineInfo]>,
        triggers: MetadataFetchOutcome<[TriggerInfo]>?,
        types: MetadataFetchOutcome<[UserDefinedTypeInfo]>?
    ) -> SideObjects {
        var next = side
        next.routines = side.routines.settled(by: routines, discardingValue: false)
        if let triggers {
            next.triggers = side.triggers.settled(by: triggers, discardingValue: false)
        }
        if let types {
            next.userDefinedTypes = side.userDefinedTypes.settled(by: types, discardingValue: false)
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
        case .loaded where (scope == nil || loadedScope(for: connectionId) == scope)
            && isCatalogCurrent(for: connectionId):
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
        let key = reloadKey(connectionId, scope: scope, driver: driver)
        updateSideObjects(key) { $0.routines = $0.routines.enteringLoad }
        bumpGeneration(connectionId)
        let outcome = await Self.fetchObjectsSafely(
            key: LoadKey(connectionId: connectionId, scope: scope),
            connectionId: connectionId,
            label: "routines",
            dedup: routinesDedup,
            fetch: { try await driver.fetchRoutines(schema: nil) }
        )
        updateKeptSideObjects(key) { $0.routines = $0.routines.settled(by: outcome, discardingValue: false) }
        bumpGeneration(connectionId)
        return outcome.didFetch
    }

    @discardableResult
    func reloadTriggers(connectionId: UUID, driver: DatabaseDriver, scope: DatabaseScope?) async -> Bool {
        let key = reloadKey(connectionId, scope: scope, driver: driver)
        updateSideObjects(key) { $0.triggers = $0.triggers.enteringLoad }
        bumpGeneration(connectionId)
        let outcome = await Self.fetchObjectsSafely(
            key: LoadKey(connectionId: connectionId, scope: scope),
            connectionId: connectionId,
            label: "triggers",
            dedup: triggersDedup,
            fetch: { try await driver.fetchAllTriggers(schema: nil) }
        )
        updateKeptSideObjects(key) { $0.triggers = $0.triggers.settled(by: outcome, discardingValue: false) }
        bumpGeneration(connectionId)
        return outcome.didFetch
    }

    @discardableResult
    func reloadUserDefinedTypes(connectionId: UUID, driver: DatabaseDriver, scope: DatabaseScope?) async -> Bool {
        let key = reloadKey(connectionId, scope: scope, driver: driver)
        updateSideObjects(key) { $0.userDefinedTypes = $0.userDefinedTypes.enteringLoad }
        bumpGeneration(connectionId)
        let outcome = await Self.fetchObjectsSafely(
            key: LoadKey(connectionId: connectionId, scope: scope),
            connectionId: connectionId,
            label: "types",
            dedup: typesDedup,
            fetch: { try await driver.fetchUserDefinedTypes(schema: nil) }
        )
        updateKeptSideObjects(key) {
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
        await cancelSchemaLoads { $0.schemaKey.connectionId == connectionId }
    }

    func invalidate(connectionId: UUID) async {
        await cancelInFlightLoads(connectionId: connectionId)
        loadGenerations = loadGenerations.filter { $0.key.connectionId != connectionId }
        refreshGenerations.removeValue(forKey: connectionId)
        shownClaims.removeValue(forKey: connectionId)
        unrefreshedCatalogs = unrefreshedCatalogs.filter { $0.connectionId != connectionId }
        schemaLoadGenerations = schemaLoadGenerations.filter { $0.key.connectionId != connectionId }
        schemaFreshness.removeAll { $0.connectionId == connectionId }
        refreshingConnections.remove(connectionId)
        states = states.filter { $0.key.connectionId != connectionId }
        sideObjects = sideObjects.filter { $0.key.connectionId != connectionId }
        schemasInOrder = schemasInOrder.filter { $0.key.connectionId != connectionId }
        perSchemaStates = perSchemaStates.filter { $0.key.connectionId != connectionId }
        perSchemaSideObjects = perSchemaSideObjects.filter { $0.key.connectionId != connectionId }
        generations.removeValue(forKey: connectionId)
        shownCatalogs.removeValue(forKey: connectionId)
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
    /// kinds. When that leaves no tables, each kind the engine lists with nothing loaded reports the
    /// failure too, because an empty section that has not failed reads as one still loading.
    func markLoadFailed(connectionId: UUID, message: String, scope: DatabaseScope?) {
        let type = DatabaseManager.shared.session(for: connectionId)?.connection.type
        var key = shownKey(connectionId)
        var moved = false
        if let scope {
            key = catalogKey(for: scope, type: type)
            if isBrowsed(key, type: type) {
                moved = showCatalog(key, scope: scope)
            }
        }
        if settleTablesFailed(key, message: message) {
            let kinds = type.map(SideKinds.init)
            updateSideObjects(key) { side in
                side = Self.settled(
                    side,
                    routines: .failed(message),
                    triggers: kinds?.triggers == true ? .failed(message) : nil,
                    types: kinds?.types == true ? .failed(message) : nil
                )
            }
        } else if !moved {
            return
        }
        bumpGeneration(connectionId)
    }

    /// Returns false when nothing changed, so a refresh that failed over tables it keeps publishes nothing.
    private func settleTablesFailed(_ key: CatalogKey, message: String) -> Bool {
        let current = states[key] ?? .idle
        let next = current.settled(byFailure: message, discardingValue: false)
        guard next != current else { return false }
        states[key] = next
        return true
    }

    private func runLoad(
        connectionId: UUID,
        driver: DatabaseDriver,
        connection: DatabaseConnection,
        scope: DatabaseScope?
    ) async {
        let type = connection.type
        let key = scope.map { catalogKey(for: $0, type: type) } ?? shownKey(connectionId)
        let generation = beginLoadGeneration(for: key)
        beginRefresh(connectionId, generation: generation)
        defer { endRefresh(connectionId, generation: generation) }
        claimShown(key, scope: scope, generation: generation, type: type)
        if !hasLoadedContent(key) {
            states[key] = .loading
        }
        let kinds = SideKinds(type)
        updateSideObjects(key) { $0 = Self.enteringLoad($0, kinds: kinds) }
        bumpGeneration(connectionId)

        let supportsSchemas = PluginManager.shared.supportsSchemaSwitching(for: type)
        if !supportsSchemas {
            schemasInOrder.removeValue(forKey: key)
        }

        let loadKey = LoadKey(connectionId: connectionId, scope: scope)
        let grouping = PluginManager.shared.databaseGroupingStrategy(for: type)
        if grouping == .hierarchicalSchema {
            await runHierarchicalLoad(
                key: key,
                loadKey: loadKey,
                driver: driver,
                kinds: kinds,
                generation: generation,
                type: type
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
        do {
            let tables = try await tablesTask
            guard isCurrentLoadGeneration(generation, for: key, phase: "tables-loaded") else {
                return
            }
            adoptShown(key, scope: scope, generation: generation, type: type)
            states[key] = .loaded(tables)
            unrefreshedCatalogs.remove(key)
            bumpGeneration(connectionId)
        } catch is CancellationError {
            abandonLoad(key, generation: generation)
            return
        } catch {
            guard isCurrentLoadGeneration(generation, for: key, phase: "tables-failed") else {
                if loadGenerations[key] == nil, case .loading = states[key] {
                    states[key] = .idle
                }
                return
            }
            Self.logger.warning(
                "[schema] load failed connId=\(connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
            let moved = adoptShown(key, scope: scope, generation: generation, type: type)
            if settleTablesFailed(key, message: error.localizedDescription) || moved {
                bumpGeneration(connectionId)
            }
        }

        let routinesOutcome = await routinesTask
        let triggersOutcome = await triggersTask
        let typesOutcome = await typesTask
        guard isCurrentLoadGeneration(generation, for: key, phase: "side-objects-loaded") else {
            return
        }
        commitSideObjects(key, routines: routinesOutcome, triggers: triggersOutcome, types: typesOutcome)

        if let loadedSchemas = await schemasTask {
            guard isCurrentLoadGeneration(generation, for: key, phase: "schemas-loaded") else {
                return
            }
            schemasInOrder[key] = loadedSchemas
        }
        bumpGeneration(connectionId)
    }

    private func runHierarchicalLoad(
        key: CatalogKey,
        loadKey: LoadKey,
        driver: DatabaseDriver,
        kinds: SideKinds,
        generation: Int,
        type: DatabaseType
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
            abandonLoad(key, generation: generation)
            return
        } catch {
            guard isCurrentLoadGeneration(generation, for: key, phase: "hierarchical-failed") else {
                return
            }
            Self.logger.warning(
                "[schema] hierarchical schema list failed connId=\(connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
            let moved = adoptShown(key, scope: scope, generation: generation, type: type)
            commitSideObjects(key, routines: routinesOutcome, triggers: triggersOutcome, types: typesOutcome)
            if settleTablesFailed(key, message: error.localizedDescription) || moved {
                bumpGeneration(connectionId)
            }
            return
        }

        guard isCurrentLoadGeneration(generation, for: key, phase: "hierarchical-loaded") else {
            return
        }
        adoptShown(key, scope: scope, generation: generation, type: type)
        schemasInOrder[key] = loadedSchemas
        dropSchemaLists(of: key, outside: Set(loadedSchemas))
        commitSideObjects(key, routines: routinesOutcome, triggers: triggersOutcome, types: typesOutcome)
        states[key] = .loaded([])
        unrefreshedCatalogs.remove(key)
        bumpGeneration(connectionId)
    }

    /// A schema the server no longer lists has no row left to fetch it again, so a list kept for it,
    /// from before the database was left, would go on feeding its tables to every catalog reader. A
    /// fetch still running for one finds its generation gone and commits nothing.
    private func dropSchemaLists(of key: CatalogKey, outside schemas: Set<String>) {
        let isGone: (SchemaKey) -> Bool = {
            $0.connectionId == key.connectionId && $0.database == key.database && !schemas.contains($0.schema)
        }
        perSchemaStates = perSchemaStates.filter { !isGone($0.key) }
        perSchemaSideObjects = perSchemaSideObjects.filter { !isGone($0.key) }
        schemaLoadGenerations = schemaLoadGenerations.filter { !isGone($0.key) }
        schemaFreshness.removeAll(where: isGone)
    }

    private func beginRefresh(_ connectionId: UUID, generation: Int) {
        refreshGenerations[connectionId] = generation
        refreshingConnections.insert(connectionId)
    }

    private func endRefresh(_ connectionId: UUID, generation: Int) {
        guard refreshGenerations[connectionId] == generation else { return }
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

    private func beginLoadGeneration(for key: CatalogKey) -> Int {
        nextLoadGeneration += 1
        let generation = nextLoadGeneration
        if case .loading? = states[key] {
            let previousGeneration = loadGenerations[key] ?? 0
            Self.logger.debug(
                "[schema] superseding in-flight load connId=\(key.connectionId, privacy: .public) previousGeneration=\(previousGeneration) newGeneration=\(generation)"
            )
        }
        loadGenerations[key] = generation
        return generation
    }

    private func isCurrentLoadGeneration(
        _ generation: Int,
        for key: CatalogKey,
        phase: String
    ) -> Bool {
        guard loadGenerations[key] == generation else {
            let currentGeneration = loadGenerations[key] ?? 0
            Self.logger.debug(
                "[schema] stale load transition ignored connId=\(key.connectionId, privacy: .public) phase=\(phase, privacy: .public) generation=\(generation) currentGeneration=\(currentGeneration)"
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
