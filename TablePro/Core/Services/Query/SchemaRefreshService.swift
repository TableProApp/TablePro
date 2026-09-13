//
//  SchemaRefreshService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

/// Owns the connection-scoped schema refresh so every window of a connection shares
/// one load instead of running its own. Requests for the same connection and database
/// scope join the in-flight refresh.
@MainActor
final class SchemaRefreshService {
    static let shared = SchemaRefreshService()

    private struct RefreshKey: Hashable {
        let connectionId: UUID
        let database: String?
    }

    private struct InFlightRefresh {
        let id: UUID
        let task: Task<Void, Never>
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaRefreshService")

    private let schemaService: SchemaService
    private let treeMetadataService: DatabaseTreeMetadataService
    private let providerRegistry: SchemaProviderRegistry
    private let pluginManager: PluginManager
    private let metadataDriverProvider: any ScopedMetadataProviding
    private let databaseManager: DatabaseManager?

    private var inFlight: [RefreshKey: InFlightRefresh] = [:]
    private var schemaChangeCancellable: AnyCancellable?

    init(
        schemaService: SchemaService = .shared,
        treeMetadataService: DatabaseTreeMetadataService = .shared,
        providerRegistry: SchemaProviderRegistry = .shared,
        pluginManager: PluginManager = .shared,
        metadataDriverProvider: any ScopedMetadataProviding = DatabaseManager.shared,
        databaseManager: DatabaseManager? = .shared
    ) {
        self.schemaService = schemaService
        self.treeMetadataService = treeMetadataService
        self.providerRegistry = providerRegistry
        self.pluginManager = pluginManager
        self.metadataDriverProvider = metadataDriverProvider
        self.databaseManager = databaseManager
        schemaChangeCancellable = AppEvents.shared.currentSchemaChanged
            .sink { [weak self] connectionId in
                Task { @MainActor [weak self] in
                    await self?.refreshForSchemaSwitch(connectionId: connectionId)
                }
            }
    }

    func refresh(connection: DatabaseConnection, database: String? = nil) async {
        SchemaForeignKeyStore.shared.invalidate(connectionId: connection.id)
        let key = RefreshKey(connectionId: connection.id, database: database)
        if let existing = inFlight[key] {
            await existing.task.value
            return
        }
        let entry = InFlightRefresh(id: UUID(), task: Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(connection: connection, database: database)
        })
        inFlight[key] = entry
        await entry.task.value
        finish(entry, for: key)
    }

    /// A refresh asked for after a write must not answer with a load that began before it.
    ///
    /// Joining is right for two windows asking at the same moment, and wrong here: a fetch that
    /// started before the write commits hands back the catalog as it was. So the entry is replaced
    /// synchronously, before anything awaits, which makes every later plain refresh join this one,
    /// and its first step cancels the loads it supersedes. A superseded fetch blocked in a C call
    /// still completes, and `SchemaService`'s load generation discards what it brings back.
    func refreshAfterWrite(connection: DatabaseConnection) async {
        let connectionId = connection.id
        SchemaForeignKeyStore.shared.invalidate(connectionId: connectionId)
        for key in Array(inFlight.keys) where key.connectionId == connectionId {
            inFlight.removeValue(forKey: key)
        }
        let key = RefreshKey(connectionId: connectionId, database: nil)
        let entry = InFlightRefresh(id: UUID(), task: Task { @MainActor [weak self] in
            guard let self else { return }
            await self.schemaService.prepareForReload(connectionId: connectionId)
            await self.performRefresh(connection: connection, database: nil, refreshesLoadedTreeTables: false)
        })
        inFlight[key] = entry
        await entry.task.value
        finish(entry, for: key)
    }

    private func finish(_ entry: InFlightRefresh, for key: RefreshKey) {
        guard inFlight[key]?.id == entry.id else { return }
        inFlight.removeValue(forKey: key)
    }

    func waitForRefresh(connectionId: UUID) async {
        let tasks = inFlight.compactMap { key, entry in
            key.connectionId == connectionId ? entry.task : nil
        }
        for task in tasks {
            await task.value
        }
    }

    /// Brings every listed connection's catalog up to the scope that connection is browsing.
    /// Connections are independent, so they load concurrently rather than one after another.
    /// Returns the connections whose catalog ended up matching their browse scope.
    func loadBrowseCatalogs(connectionIds: [UUID]) async -> Set<UUID> {
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for connectionId in connectionIds {
                group.addTask {
                    let didLoad = await self.loadBrowseCatalog(connectionId: connectionId)
                    return (connectionId, didLoad)
                }
            }
            var loaded: Set<UUID> = []
            for await (connectionId, didLoad) in group where didLoad {
                loaded.insert(connectionId)
            }
            return loaded
        }
    }

    private func loadBrowseCatalog(connectionId: UUID) async -> Bool {
        await waitForRefresh(connectionId: connectionId)
        await schemaService.waitForRefresh(connectionId: connectionId)
        guard !Task.isCancelled,
              let session = databaseManager?.session(for: connectionId),
              session.isConnected,
              session.driver != nil,
              let scope = metadataDriverProvider.browseScope(for: connectionId) else { return false }

        if schemaService.loadedScope(for: connectionId) != scope {
            await refresh(connection: session.connection)
            await waitForRefresh(connectionId: connectionId)
            await schemaService.waitForRefresh(connectionId: connectionId)
        }

        guard !Task.isCancelled, schemaService.loadedScope(for: connectionId) == scope else { return false }
        guard pluginManager.databaseGroupingStrategy(for: session.connection.type) == .hierarchicalSchema else {
            return true
        }
        return await loadBrowsedSchemaTables(connectionId: connectionId, scope: scope)
    }

    /// A hierarchicalSchema plugin loads objects one schema at a time, so a loaded scope on its
    /// own means the schema list arrived, not that any schema holds objects. Without this, a
    /// connection whose browsed schema was never expanded reports a full catalog of nothing.
    private func loadBrowsedSchemaTables(connectionId: UUID, scope: DatabaseScope) async -> Bool {
        guard let schema = scope.schema else { return false }
        if schemaService.hasLoadedContent(for: connectionId, schema: schema) { return true }
        do {
            try await metadataDriverProvider.withMetadataDriver(
                scope: scope,
                workload: .bulk
            ) { [schemaService] driver in
                await schemaService.loadSchemaObjects(connectionId: connectionId, schema: schema, driver: driver)
            }
        } catch {
            Self.logger.warning(
                "[schema] browsed schema load failed connId=\(connectionId, privacy: .public) schema=\(schema, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        return schemaService.hasLoadedContent(for: connectionId, schema: schema)
    }

    /// Push the loaded table list into the autocomplete provider.
    ///
    /// The provider caches the driver it is handed and fetches columns from it later, so it
    /// must get one scoped to the browsed database rather than the shared session driver,
    /// which a tab's execution moves without writing session state.
    func syncAutocompleteProvider(connectionId: UUID) async {
        guard case .loaded = schemaService.state(for: connectionId) else {
            Self.logger.debug(
                "[schema] autocomplete sync skipped, schema not loaded connId=\(connectionId, privacy: .public)"
            )
            return
        }
        guard let browseScope = metadataDriverProvider.browseScope(for: connectionId) else {
            Self.logger.debug(
                "[schema] autocomplete sync skipped, no browse scope connId=\(connectionId, privacy: .public)"
            )
            return
        }
        let provider = providerRegistry.getOrCreate(for: browseScope)
        let browseDatabase = browseScope.database
        let tables = schemaService.allLoadedTables(for: connectionId)
        let schemas = schemaService.schemas(for: connectionId)
        let connection = databaseManager?.session(for: connectionId)?.connection
        do {
            try await metadataDriverProvider.withMetadataDriver(scope: browseScope) { driver in
                await provider.resetForDatabase(
                    browseDatabase,
                    tables: tables,
                    driver: driver,
                    connection: connection
                )
                await provider.setNamespaces(schemas: schemas, databases: [browseDatabase])
            }
            providerRegistry.notePopulatedExternally(scope: browseScope)
        } catch {
            Self.logger.warning(
                "[schema] autocomplete sync failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func refreshForSchemaSwitch(connectionId: UUID) async {
        guard let connection = databaseManager?.session(for: connectionId)?.connection else { return }
        guard pluginManager.databaseGroupingStrategy(for: connection.type) == .hierarchicalSchema else {
            await refresh(connection: connection)
            return
        }
        await refreshSessionScopedObjects(connectionId: connectionId)
    }

    /// A schema switch on a hierarchicalSchema engine moves the session's default schema and
    /// nothing else. That tree lists every schema and keys each object list by an explicit
    /// schema, so the schema list and the per-schema tables cannot have gone stale. Only the
    /// routines can: `fetchProcedures` and `fetchFunctions` resolve a nil schema to the driver's
    /// current one.
    ///
    /// Reloading the whole catalog instead re-fetched every expanded schema in series, on the
    /// one connection the clicked table's own query needs, because these engines browse no
    /// database and a server-scoped read cannot be pooled. That is why opening a table took a
    /// round trip per expanded schema (#2262).
    private func refreshSessionScopedObjects(connectionId: UUID) async {
        do {
            guard let scope = metadataDriverProvider.browseScope(for: connectionId) else {
                throw DatabaseError.notConnected
            }
            let connectionType = databaseManager?.session(for: connectionId)?.connection.type
            let browsesTriggers = connectionType?.supportsDatabaseTriggerBrowse ?? false
            let browsesTypes = connectionType?.supportsUserDefinedTypeBrowse ?? false
            let reloaded = try await metadataDriverProvider.withMetadataDriver(
                scope: scope,
                workload: .bulk
            ) { [schemaService] driver in
                /// All run, and none short circuits another: a failed routine fetch must not skip
                /// the trigger fetch that would still have succeeded.
                let routines = await schemaService.reloadRoutines(
                    connectionId: connectionId,
                    driver: driver,
                    scope: scope
                )
                let triggers = browsesTriggers
                    ? await schemaService.reloadTriggers(connectionId: connectionId, driver: driver, scope: scope)
                    : true
                let types = browsesTypes
                    ? await schemaService.reloadUserDefinedTypes(
                        connectionId: connectionId,
                        driver: driver,
                        scope: scope
                    )
                    : true
                return routines && triggers && types
            }
            /// Recording the new scope says the loaded routines belong to it. A reload that failed
            /// left the previous schema's routines in place, so claiming coverage there would pin
            /// them to a schema they never came from, with nothing scheduled to correct it.
            if reloaded {
                schemaService.noteScopeCovered(scope, for: connectionId)
            }
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] routine refresh after schema switch failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        await syncAutocompleteProvider(connectionId: connectionId)
    }

    private func performRefresh(
        connection: DatabaseConnection,
        database: String?,
        refreshesLoadedTreeTables: Bool = true
    ) async {
        let connectionId = connection.id

        if pluginManager.databaseGroupingStrategy(for: connection.type) == .hierarchicalSchema {
            await schemaService.prepareForReload(connectionId: connectionId)
        }

        do {
            guard let scope = metadataDriverProvider.browseScope(for: connectionId) else {
                throw DatabaseError.notConnected
            }
            try await metadataDriverProvider.withMetadataDriver(
                scope: scope,
                workload: .bulk
            ) { [schemaService] driver in
                await schemaService.reload(
                    connectionId: connectionId,
                    driver: driver,
                    connection: connection,
                    scope: scope
                )
                await schemaService.refreshLoadedSchemaObjects(
                    connectionId: connectionId,
                    driver: driver
                )
            }
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] refresh failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            schemaService.markLoadFailed(connectionId: connectionId, message: error.localizedDescription)
        }

        if refreshesLoadedTreeTables {
            await treeMetadataService.refreshLoadedTables(connectionId: connectionId, database: database)
        }
        await syncAutocompleteProvider(connectionId: connectionId)
    }
}

/// The browse scope's object list, routines, triggers, types and schema list, which is everything
/// `SchemaService` holds. A change that reaches none of it, or lands in a database the connection is
/// not browsing, has nothing to refresh here.
extension SchemaRefreshService: CatalogChangeTarget {
    func refreshCatalog(for change: CatalogChange) async {
        guard !change.kinds.isDisjoint(with: [.objects, .schemas]),
              let connection = databaseManager?.session(for: change.connectionId)?.connection,
              let browseScope = metadataDriverProvider.browseScope(for: change.connectionId),
              change.reaches(database: browseScope.database) else { return }
        await refreshAfterWrite(connection: connection)
    }
}
