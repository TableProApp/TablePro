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

    private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaRefreshService")

    private let schemaService: SchemaService
    private let treeMetadataService: DatabaseTreeMetadataService
    private let providerRegistry: SchemaProviderRegistry
    private let pluginManager: PluginManager
    private let metadataDriverProvider: any ScopedMetadataProviding
    private let databaseManager: DatabaseManager?

    private var inFlight: [RefreshKey: Task<Void, Never>] = [:]
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
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(connection: connection, database: database)
        }
        inFlight[key] = task
        await task.value
        inFlight.removeValue(forKey: key)
    }

    func waitForRefresh(connectionId: UUID) async {
        let tasks = inFlight.compactMap { key, task in
            key.connectionId == connectionId ? task : nil
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
                group.addTask { @MainActor in
                    (connectionId, await self.loadBrowseCatalog(connectionId: connectionId))
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
                await schemaService.loadSchemaTables(connectionId: connectionId, schema: schema, driver: driver)
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
        guard let provider = providerRegistry.provider(for: connectionId) else {
            Self.logger.debug(
                "[schema] autocomplete sync skipped, no provider connId=\(connectionId, privacy: .public)"
            )
            return
        }
        guard let browseDatabase = metadataDriverProvider.browseScope(for: connectionId)?.database else {
            Self.logger.debug(
                "[schema] autocomplete sync skipped, no browse scope connId=\(connectionId, privacy: .public)"
            )
            return
        }
        let tables = schemaService.allLoadedTables(for: connectionId)
        let schemas = schemaService.schemas(for: connectionId)
        do {
            try await metadataDriverProvider.withBrowseMetadataDriver(connectionId: connectionId) { driver in
                await provider.resetForDatabase(browseDatabase, tables: tables, driver: driver)
                await provider.setNamespaces(schemas: schemas, databases: [browseDatabase])
            }
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
            try await metadataDriverProvider.withMetadataDriver(
                scope: scope,
                workload: .bulk
            ) { [schemaService] driver in
                await schemaService.reloadProcedures(connectionId: connectionId, driver: driver)
                await schemaService.reloadFunctions(connectionId: connectionId, driver: driver)
            }
            schemaService.noteScopeCovered(scope, for: connectionId)
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] routine refresh after schema switch failed connId=\(connectionId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        await syncAutocompleteProvider(connectionId: connectionId)
    }

    private func performRefresh(connection: DatabaseConnection, database: String?) async {
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
                await schemaService.refreshLoadedSchemaTables(
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

        await treeMetadataService.refreshLoadedTables(connectionId: connectionId, database: database)
        await syncAutocompleteProvider(connectionId: connectionId)
    }
}
