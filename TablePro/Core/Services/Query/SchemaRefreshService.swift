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
        await refresh(connection: connection)
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
