//
//  SchemaRefreshService.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

/// Owns the schema refresh so every window browsing the same container shares one load
/// instead of running its own. Requests for the same scope join the in-flight refresh;
/// windows on different databases or schemas of one connection do not, because they are
/// filling different caches.
@MainActor
final class SchemaRefreshService {
    static let shared = SchemaRefreshService()

    private struct RefreshKey: Hashable {
        let scope: DatabaseScope
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

    func refresh(connection: DatabaseConnection, scope: DatabaseScope, database: String? = nil) async {
        let key = RefreshKey(scope: scope, database: database)
        if let existing = inFlight[key] {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(connection: connection, scope: scope, database: database)
        }
        inFlight[key] = task
        await task.value
        inFlight.removeValue(forKey: key)
    }

    /// Push the loaded table list into the autocomplete provider.
    ///
    /// The provider caches the driver it is handed and fetches columns from it later, so it
    /// must get one scoped to the container the window is browsing rather than the shared
    /// session driver, which a tab's execution moves without writing session state.
    func syncAutocompleteProvider(scope: DatabaseScope) async {
        guard case .loaded = schemaService.state(for: scope) else {
            Self.logger.debug(
                "[schema] autocomplete sync skipped, schema not loaded connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public)"
            )
            return
        }
        guard let provider = providerRegistry.provider(for: scope) else {
            Self.logger.debug(
                "[schema] autocomplete sync skipped, no provider connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public)"
            )
            return
        }
        let tables = schemaService.allLoadedTables(for: scope)
        let schemas = schemaService.schemas(for: scope)
        let database = scope.database
        do {
            try await metadataDriverProvider.withMetadataDriver(scope: scope) { driver in
                await provider.resetForDatabase(database, tables: tables, driver: driver)
                await provider.setNamespaces(schemas: schemas, databases: [database])
            }
        } catch {
            Self.logger.warning(
                "[schema] autocomplete sync failed connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// The driver's schema moved, which is a connection-wide fact with no window attached,
    /// so this refreshes the driver's own container. A window that browses another schema
    /// refreshes its own scope through its coordinator.
    private func refreshForSchemaSwitch(connectionId: UUID) async {
        guard let databaseManager,
              let connection = databaseManager.session(for: connectionId)?.connection,
              let scope = databaseManager.driverScope(for: connectionId) else { return }
        await refresh(connection: connection, scope: scope)
    }

    private func performRefresh(connection: DatabaseConnection, scope: DatabaseScope, database: String?) async {
        if pluginManager.databaseGroupingStrategy(for: connection.type) == .hierarchicalSchema {
            await schemaService.prepareForReload(scope: scope)
        }

        do {
            try await metadataDriverProvider.withMetadataDriver(
                scope: scope,
                workload: .bulk
            ) { [schemaService] driver in
                await schemaService.reload(
                    scope: scope,
                    driver: driver,
                    connection: connection
                )
                await schemaService.refreshLoadedSchemaTables(
                    scope: scope,
                    driver: driver
                )
            }
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "[schema] refresh failed connId=\(scope.connectionId, privacy: .public) container=\(scope.qualifiedDescription, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            schemaService.markLoadFailed(scope: scope, message: error.localizedDescription)
        }

        await treeMetadataService.refreshLoadedTables(connectionId: scope.connectionId, database: database)
        await syncAutocompleteProvider(scope: scope)
    }
}
