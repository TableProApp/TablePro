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
    private let metadataDriverProvider: any MetadataDriverProviding
    private let databaseManager: DatabaseManager?

    private var inFlight: [RefreshKey: Task<Void, Never>] = [:]
    private var schemaChangeCancellable: AnyCancellable?

    init(
        schemaService: SchemaService = .shared,
        treeMetadataService: DatabaseTreeMetadataService = .shared,
        providerRegistry: SchemaProviderRegistry = .shared,
        pluginManager: PluginManager = .shared,
        metadataDriverProvider: any MetadataDriverProviding = DatabaseManager.shared,
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

    /// Push the loaded table list into the autocomplete provider. Called after every
    /// refresh and after the initial per-window schema load.
    func syncAutocompleteProvider(connectionId: UUID) async {
        guard case .loaded = schemaService.state(for: connectionId),
              let driver = databaseManager?.driver(for: connectionId),
              let provider = providerRegistry.provider(for: connectionId) else { return }
        let currentDatabase = databaseManager?.session(for: connectionId)?.activeDatabase
        await provider.resetForDatabase(
            currentDatabase,
            tables: schemaService.allLoadedTables(for: connectionId),
            driver: driver
        )
        await provider.setNamespaces(
            schemas: schemaService.schemas(for: connectionId),
            databases: currentDatabase.map { [$0] } ?? []
        )
    }

    private func refreshForSchemaSwitch(connectionId: UUID) async {
        guard let connection = databaseManager?.session(for: connectionId)?.connection else { return }
        await refresh(connection: connection)
    }

    private func performRefresh(connection: DatabaseConnection, database: String?) async {
        let connectionId = connection.id

        if pluginManager.databaseGroupingStrategy(for: connection.type) == .hierarchicalSchema {
            await schemaService.invalidate(connectionId: connectionId)
        }

        do {
            try await metadataDriverProvider.withMetadataDriver(
                connectionId: connectionId,
                workload: .bulk
            ) { [schemaService] driver in
                await schemaService.reload(
                    connectionId: connectionId,
                    driver: driver,
                    connection: connection
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
