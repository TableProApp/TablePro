//
//  MainContentCoordinator+SchemaLoading.swift
//  TablePro
//

import Combine
import Foundation
import os

extension MainContentCoordinator {
    /// Reload the schema once the connection lands.
    ///
    /// The window is created before `ensureConnected` runs, so the first schema load can
    /// reach `loadSchema` before a session exists. A local file connects fast enough that
    /// `databaseDidConnect` can also fire before this is armed, so arming is idempotent and
    /// loads immediately when the session is already there.
    internal func armPostConnectSchemaLoad() {
        guard services.databaseManager.browseScope(for: connectionId) == nil else {
            postConnectCancellable = nil
            loadSchemaForNewSession()
            return
        }
        guard postConnectCancellable == nil else { return }
        postConnectCancellable = services.appEvents.databaseDidConnect
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self, payload.connectionId == self.connection.id else { return }
                self.postConnectCancellable = nil
                self.loadSchemaForNewSession()
            }
    }

    private func loadSchemaForNewSession() {
        Task { @MainActor in
            self.setupPluginDriver()
            await self.loadSchemaIfNeeded()
        }
    }

    func loadSchema() async {
        let connection = connection
        guard let scope = services.databaseManager.browseScope(for: connectionId) else {
            armPostConnectSchemaLoad()
            return
        }
        do {
            try await services.databaseManager.withMetadataDriver(scope: scope) { [services, connectionId] driver in
                await services.schemaService.load(
                    connectionId: connectionId,
                    driver: driver,
                    connection: connection,
                    scope: scope
                )
            }
        } catch {
            // No session yet: the object list would sit on an empty schema forever, so wait
            // for the connection instead of swallowing the failure.
            Self.logger.info(
                "[schema] initial load deferred until connect connId=\(self.connectionId, privacy: .public)"
            )
            armPostConnectSchemaLoad()
            return
        }
        await DatabaseTreeMetadataService.shared.loadDatabases(
            connectionId: connectionId,
            databaseType: connection.type
        )
        await services.schemaRefreshService.syncAutocompleteProvider(connectionId: connectionId)
        pruneStaleSidebarState()
        prefetchForeignKeys(scope: scope)
    }

    /// The user cannot open a table before the object list they click it in has loaded, so starting
    /// here puts the fetch ahead of the first table open without competing with it. On a poolable
    /// engine `.bulk` also keeps it off the connection the table's own metadata will use.
    ///
    /// The capability is read from the session driver rather than from inside the lease, because a
    /// pooled lease builds and connects a whole new driver: asking there would open a second server
    /// connection on every engine that then declines, and throw the answer away.
    func prefetchForeignKeys(scope: DatabaseScope) {
        guard services.databaseManager.driver(for: connectionId)?.providesBulkForeignKeyFetch == true else { return }
        SchemaForeignKeyStore.shared.prefetch(scope: scope) { [services] in
            do {
                return try await services.databaseManager.withMetadataDriver(
                    scope: scope,
                    workload: .bulk
                ) { driver in
                    try await driver.fetchAllForeignKeys()
                }
            } catch {
                Self.logger.info(
                    "[fk] schema foreign key prefetch failed: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    }

    func loadTableMetadata(tableName: String) async {
        guard let scope = selectedTabScope else {
            Self.logger.error("Skipped table metadata load: no database bound to the selected tab")
            return
        }
        do {
            let metadata = try await services.databaseManager.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchTableMetadata(tableName: tableName)
            }
            self.tableMetadata = metadata
        } catch {
            Self.logger.error("Failed to load table metadata: \(error.localizedDescription, privacy: .public)")
        }
    }
}
