//
//  SchemaProviderRegistry.swift
//  TablePro
//
//  Manages shared SQLSchemaProvider instances, one per DatabaseScope.
//  Ref-counted per connection with grace period removal to avoid redundant schema loads.
//

import Combine
import Foundation
import os

/// Answers which scopes something is still rendering, so eviction can drop only the providers
/// nothing holds.
///
/// It is a pull, not a retain count, because a query tab reads its provider from a SwiftUI body
/// and appearance is not lifetime here: unparenting a pane fires `onDisappear` on a view that is
/// still alive, so a retain keyed on the view would churn on every connection switch, and one
/// missed release would pin a provider for the session.
@MainActor
protocol LiveScopeProviding: AnyObject {
    func liveScopes(for connectionId: UUID) -> Set<DatabaseScope>
}

@MainActor
final class SchemaProviderRegistry {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaProviderRegistry")

    /// How many providers one connection keeps before eviction looks for scopes nothing holds.
    /// A window renders one query tab at a time, so anything above the browse scope plus a
    /// handful of pinned tabs is a session's history rather than its working set.
    private static let softProviderLimit = 8

    static let shared = SchemaProviderRegistry()

    private var providers: [DatabaseScope: SQLSchemaProvider] = [:]
    private var loadedScopes: Set<DatabaseScope> = []
    private var populationTasks: [DatabaseScope: Task<Void, Never>] = [:]
    private var populationGenerations: [DatabaseScope: Int] = [:]
    private var refCounts: [UUID: Int] = [:]
    private var removalTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let metadataDriverProvider: any ScopedMetadataProviding
    private weak var liveScopeProvider: (any LiveScopeProviding)?

    #if DEBUG
    /// Test-only init for `@testable` tests in DEBUG builds; release builds must use `.shared`.
    internal init(
        metadataDriverProvider: any ScopedMetadataProviding = DatabaseManager.shared,
        liveScopeProvider: (any LiveScopeProviding)? = nil
    ) {
        self.metadataDriverProvider = metadataDriverProvider
        self.liveScopeProvider = liveScopeProvider
        subscribeToRefreshSignal()
    }
    #else
    private init(metadataDriverProvider: any ScopedMetadataProviding = DatabaseManager.shared) {
        self.metadataDriverProvider = metadataDriverProvider
        subscribeToRefreshSignal()
    }
    #endif

    func setLiveScopeProvider(_ provider: any LiveScopeProviding) {
        liveScopeProvider = provider
    }

    private func subscribeToRefreshSignal() {
        AppCommands.shared.refreshData
            .sink { [weak self] request in
                self?.refresh(request: request)
            }
            .store(in: &cancellables)
    }

    func provider(for scope: DatabaseScope) -> SQLSchemaProvider? {
        providers[scope]
    }

    func getOrCreate(for scope: DatabaseScope) -> SQLSchemaProvider {
        let connectionId = scope.connectionId
        if let removalTask = removalTasks[connectionId] {
            removalTask.cancel()
            removalTasks.removeValue(forKey: connectionId)
        }
        if let existing = providers[scope] {
            return existing
        }
        let metadataProvider = metadataDriverProvider
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { table, schema in
                try await metadataProvider.withMetadataDriver(scope: scope) { driver in
                    if let schema {
                        return try await driver.fetchColumns(table: table, schema: schema)
                    }
                    return try await driver.fetchColumns(table: table)
                }
            },
            fetchAllColumns: {
                try await metadataProvider.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                    try await driver.fetchAllColumns()
                }
            },
            fetchSchemaTables: { schema in
                try await metadataProvider.withMetadataDriver(scope: scope) { driver in
                    try await driver.fetchTables(schema: schema)
                }
            },
            sampleFieldPaths: { table, limit in
                try await metadataProvider.withMetadataDriver(scope: scope) { driver in
                    try await driver.sampleFieldPaths(table: table, limit: limit)
                }
            }
        )
        let provider = SQLSchemaProvider(metadataSource: source)
        providers[scope] = provider
        /// Never the scope being created. The quick switcher fabricates a scope when there is no
        /// browse cursor, and such a scope is in neither `liveScopes` nor the browse exemption, so
        /// eviction would drop the provider this call is about to return and the next
        /// `getOrCreate` would hand out a different instance for the same scope.
        evictUnheldProvidersIfNeeded(for: connectionId, keeping: scope)
        return provider
    }

    /// Creates the provider for `scope` if it does not exist yet and fills it once.
    ///
    /// "Filled" is tracked here rather than read back off the provider, because a database with
    /// no tables is loaded and empty, and asking the provider whether it holds any would refetch
    /// its catalog on every tab activation forever.
    @discardableResult
    func prepare(for scope: DatabaseScope, connection: DatabaseConnection? = nil) async -> SQLSchemaProvider {
        let provider = getOrCreate(for: scope)
        guard !loadedScopes.contains(scope) else { return provider }
        await populate(scope: scope, provider: provider, connection: connection)
        return provider
    }

    /// A data change repopulates every provider it reaches except the browse scope, which
    /// `SchemaRefreshService.syncAutocompleteProvider` owns and fills with the union of every
    /// schema the sidebar has expanded. Repopulating it here as well would give one provider two
    /// writers with no ordering between them and two different table sets to write.
    func refresh(request: DataRefreshRequest) {
        let browseScope = metadataDriverProvider.browseScope(for: request.connectionId)
        /// Most senders leave the scope nil, which reaches every provider of the connection.
        /// Repopulating all of them would run a catalog fetch and a whole-schema column preload
        /// per scope the session has ever visited, so only the scopes something still renders
        /// are refreshed; the rest reload when a tab binds to them again.
        let live = liveScopeProvider?.liveScopes(for: request.connectionId)
        let matching = providers.filter { scope, _ in
            scope.connectionId == request.connectionId
                && scope != browseScope
                && request.reaches(tabScope: scope)
                && (live?.contains(scope) ?? true)
        }
        for (scope, provider) in matching {
            Task { [weak self] in
                await self?.populate(scope: scope, provider: provider, connection: nil)
            }
        }
    }

    /// Fetches the scope's catalog and commits it over whatever the provider held.
    ///
    /// One lease covers the object list and the schema list, so a tab bound to another database
    /// can complete `SCHEMA.` and offer namespaces rather than only its own tables. A failure
    /// leaves the previous content alone and clears the loaded flag, so the next call retries.
    private func populate(
        scope: DatabaseScope,
        provider: SQLSchemaProvider,
        connection: DatabaseConnection?
    ) async {
        if let existing = populationTasks[scope] {
            await existing.value
            return
        }
        let metadataProvider = metadataDriverProvider
        let resolvedConnection = connection ?? DatabaseManager.shared.session(for: scope.connectionId)?.connection
        let databases = knownDatabases(for: scope)
        let generation = populationGenerations[scope, default: 0]

        let task = Task { [weak self] in
            let registry = self
            do {
                try await metadataProvider.withMetadataDriver(scope: scope, workload: .bulk) { driver in
                    let tables = try await driver.fetchTables(schema: scope.schema)
                    let schemas = (try? await driver.fetchSchemas()) ?? []
                    /// The fetch is a round trip, and `SchemaRefreshService` can finish filling
                    /// this scope during it with the union of every expanded schema. Committing
                    /// afterwards would narrow that union to this one schema and then record the
                    /// scope as loaded, so nothing would widen it again until a manual refresh.
                    guard await registry?.canCommitPopulation(of: scope, generation: generation) == true else { return }
                    await provider.resetForDatabase(
                        scope.database,
                        tables: tables,
                        driver: driver,
                        connection: resolvedConnection
                    )
                    await provider.setNamespaces(schemas: schemas, databases: databases)
                }
                self?.markPopulated(scope: scope, provider: provider, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.warning(
                    "[schema] scope population failed scope=\(scope.qualifiedDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                /// Fenced like the commit is, and for the same reason. `notePopulatedExternally`
                /// bumps the generation when `SchemaRefreshService` fills this scope with the
                /// union of every expanded schema, so a populate that started earlier and then
                /// failed must not clear the loaded flag for content that is present and correct.
                /// Doing so sends the next `prepare` to refill it with this one schema's tables,
                /// narrowing the union that the flag exists to protect.
                await registry?.markLoadFailed(scope: scope, generation: generation)
            }
        }
        populationTasks[scope] = task
        await task.value
        if populationTasks[scope] == task {
            populationTasks.removeValue(forKey: scope)
        }
    }

    /// The lease is not cancellation-aware, so a population whose scope was evicted or
    /// disconnected mid-flight still completes and writes into a provider nobody holds any more.
    /// Recording the scope as loaded on the strength of that write would leave its replacement
    /// permanently unfilled, so the identity of the provider written to is the fence.
    private func markPopulated(scope: DatabaseScope, provider: SQLSchemaProvider, generation: Int) {
        guard providers[scope] === provider, populationGenerations[scope, default: 0] == generation else { return }
        loadedScopes.insert(scope)
    }

    /// Clears the loaded flag so the next `prepare` retries, but only while this population is
    /// still the one filling the scope. A superseded fetch that fails has nothing to report.
    private func markLoadFailed(scope: DatabaseScope, generation: Int) {
        guard populationGenerations[scope, default: 0] == generation else { return }
        loadedScopes.remove(scope)
    }

    /// `SchemaRefreshService` fills the browse scope with the union of every schema the sidebar
    /// has expanded, which the registry cannot assemble. Without this, a tab sitting on the
    /// browse scope would see an unfilled provider and refill it with its own single-schema
    /// list, narrowing what the sidebar had already gathered.
    func notePopulatedExternally(scope: DatabaseScope) {
        guard providers[scope] != nil else { return }
        loadedScopes.insert(scope)
        populationGenerations[scope, default: 0] &+= 1
        populationTasks.removeValue(forKey: scope)?.cancel()
    }

    /// A population commits only while it is still the one filling this scope. `Task.cancel` is
    /// cooperative and the pooled body never checks it, so a superseded fetch runs to completion
    /// and has to be stopped at the write rather than at the read. The generation, not the loaded
    /// flag, is what separates "the owner filled this while I was fetching" from "this is a
    /// refresh of a scope that was already loaded".
    private func canCommitPopulation(of scope: DatabaseScope, generation: Int) -> Bool {
        populationGenerations[scope, default: 0] == generation
    }

    private func knownDatabases(for scope: DatabaseScope) -> [String] {
        let listed = DatabaseTreeMetadataService.shared.databases(for: scope.connectionId).map(\.name)
        guard listed.isEmpty else { return listed }
        return scope.database.isEmpty ? [] : [scope.database]
    }

    func retain(for connectionId: UUID) {
        removalTasks[connectionId]?.cancel()
        removalTasks.removeValue(forKey: connectionId)
        refCounts[connectionId, default: 0] += 1
    }

    func release(for connectionId: UUID) {
        guard var count = refCounts[connectionId] else { return }
        count -= 1
        if count <= 0 {
            refCounts.removeValue(forKey: connectionId)
            removalTasks[connectionId] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.dropProviders(for: connectionId) { _ in true }
                self.removalTasks.removeValue(forKey: connectionId)
            }
        } else {
            refCounts[connectionId] = count
        }
    }

    func clear(for connectionId: UUID) {
        dropProviders(for: connectionId) { _ in true }
        refCounts.removeValue(forKey: connectionId)
        removalTasks[connectionId]?.cancel()
        removalTasks.removeValue(forKey: connectionId)
    }

    func purgeUnused() {
        let orphanedIds = Set(providers.keys.map(\.connectionId)).filter { connectionId in
            let count = refCounts[connectionId] ?? 0
            let hasPendingRemoval = removalTasks[connectionId] != nil
            return count <= 0 && !hasPendingRemoval
        }
        for connectionId in orphanedIds {
            Self.logger.info("Purging orphaned schema provider for connection \(connectionId)")
            dropProviders(for: connectionId) { _ in true }
            refCounts.removeValue(forKey: connectionId)
        }
    }

    /// Drops the providers for scopes nothing renders any more. Keying by scope means a session
    /// that visits many databases leaves one provider per visited scope, each holding up to
    /// `SQLSchemaProvider.maxCachedTables` tables of column metadata, and only disconnecting
    /// reclaimed them.
    ///
    /// The browse scope is never dropped: `SchemaRefreshService` fills it and nothing here would
    /// know to refill it. A scope a window still renders is never dropped either, or the next
    /// body pass would build an empty provider for a tab whose `.task(id:)` has already run and
    /// will not run again.

    /// Reclaims now rather than at the next `getOrCreate`, for the callers that know a scope may
    /// have just stopped being rendered: closing a tab, and rebinding one to another database.
    ///
    /// Liveness is re-derived here rather than pushed, because rebinding a tab moves its scope
    /// **in place**: `changeContainer` calls `markTabRenamed`, not a `tabStructureVersion` bump,
    /// so a filter keyed on tab identity would keep the old scope's provider for the session.
    func reclaimUnheldProviders(for connectionId: UUID) {
        evictUnheldProviders(for: connectionId, respectingSoftLimit: false, keeping: nil)
    }

    private func evictUnheldProvidersIfNeeded(for connectionId: UUID, keeping scope: DatabaseScope?) {
        evictUnheldProviders(for: connectionId, respectingSoftLimit: true, keeping: scope)
    }

    private func evictUnheldProviders(
        for connectionId: UUID,
        respectingSoftLimit: Bool,
        keeping protected: DatabaseScope?
    ) {
        let held = providers.keys.filter { $0.connectionId == connectionId }
        if respectingSoftLimit {
            guard held.count > Self.softProviderLimit else { return }
        }
        guard let liveScopeProvider else { return }
        /// No browse cursor means no session, which is the window a reconnect passes through
        /// rather than a signal that nothing is held. Evicting here would drop the browse
        /// provider, whose union of every expanded schema only `SchemaRefreshService` can rebuild,
        /// and `coordinator.browseScope` is nil in that window too so `liveScopes` cannot protect
        /// it either. Wait for the session to come back.
        guard let browseScope = metadataDriverProvider.browseScope(for: connectionId) else { return }
        var keep = liveScopeProvider.liveScopes(for: connectionId)
        keep.insert(browseScope)
        if let protected {
            keep.insert(protected)
        }
        let evictable = held.filter { !keep.contains($0) }
        guard !evictable.isEmpty else { return }
        Self.logger.info(
            "Evicting \(evictable.count) unheld schema provider(s) for connection \(connectionId, privacy: .public)"
        )
        dropProviders(for: connectionId) { evictable.contains($0) }
    }

    private func dropProviders(for connectionId: UUID, where matches: (DatabaseScope) -> Bool) {
        let doomed = providers.keys.filter { $0.connectionId == connectionId && matches($0) }
        for scope in doomed {
            providers.removeValue(forKey: scope)
            loadedScopes.remove(scope)
            populationGenerations[scope, default: 0] &+= 1
            populationTasks.removeValue(forKey: scope)?.cancel()
        }
    }
}
