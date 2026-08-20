//
//  MainContentCoordinator+SchemaLoading.swift
//  TablePro
//

import Combine
import Foundation
import os

extension MainContentCoordinator {
    /// Whether the connection is far enough along for the object list to load.
    ///
    /// A session is registered with a `.connecting` status before its driver connects, so a browse
    /// scope exists well before the connection does. The driver is the first thing that only exists
    /// once the connect succeeded, and every schema load and every failure decision here reads this
    /// one predicate: the two disagreeing is what turned a failed load into an endless retry (#2294).
    private var hasLiveDriver: Bool {
        services.databaseManager.driver(for: connectionId) != nil
    }

    /// Reload the schema once the connection lands.
    ///
    /// The window is created before `ensureConnected` runs, so the first schema load can
    /// reach `loadSchema` before a session exists. A local file connects fast enough that
    /// `databaseDidConnect` can also fire before this is armed, so arming is idempotent and
    /// loads immediately when the session is already there.
    internal func armPostConnectSchemaLoad() {
        guard !hasLiveDriver else {
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
        guard hasLiveDriver else {
            armPostConnectSchemaLoad()
            return
        }
        /// A live driver means a live session, so a missing scope here cannot happen. Arming on it
        /// anyway would re-enter this method immediately, which is the loop this method exists without.
        guard let scope = services.databaseManager.browseScope(for: connectionId) else {
            Self.logger.error(
                "[schema] no browse scope for a connected session connId=\(self.connectionId, privacy: .public)"
            )
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
            switch SchemaLoadPolicy.disposition(for: error, hasLiveDriver: hasLiveDriver) {
            case .ignore:
                return
            case .awaitConnection:
                Self.logger.info(
                    "[schema] initial load deferred until connect connId=\(self.connectionId, privacy: .public)"
                )
                armPostConnectSchemaLoad()
            case .surface(let message):
                Self.logger.error(
                    "[schema] initial load failed connId=\(self.connectionId, privacy: .public) error=\(message, privacy: .public)"
                )
                services.schemaService.markLoadFailed(connectionId: connectionId, message: message)
            }
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
