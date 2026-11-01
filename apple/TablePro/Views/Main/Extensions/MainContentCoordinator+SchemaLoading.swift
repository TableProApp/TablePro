//
//  MainContentCoordinator+SchemaLoading.swift
//  TablePro
//

import Combine
import Foundation
import os

/// One tab's Table Info numbers, stamped with the table and the execution they were read against.
struct TableMetadataCacheEntry {
    var table: TableTabIdentity
    let lastExecutedAt: Date?
    /// The coordinator's `tableMetadataGeneration` when the read started.
    let generation: Int
    let metadata: TableMetadata
    /// Set when the object changed without the tab running again, as a comment edit does. The
    /// numbers stay on screen until a refetch replaces them, rather than the panel going empty while
    /// it runs and staying empty if it fails.
    var isStale = false
}

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
        setupPluginDriver()
        startSchemaLoad()
    }

    /// The schema half of an activation, which runs on every appearance of this connection's
    /// content, a connection switch included. A catalog and an autocomplete provider that are
    /// already loaded are left alone, so coming back to a connection queries nothing.
    func loadSchemaOnActivation() {
        let scope = services.databaseManager.browseScope(for: connectionId)
        let action = SchemaLoadPolicy.activationAction(
            hasLiveDriver: hasLiveDriver,
            catalog: services.schemaService.state(for: connectionId),
            autocompletePopulated: scope.map { services.schemaProviderRegistry.isPopulated($0) } ?? false,
            loadInFlight: schemaLoadTask != nil
        )
        Self.logger.info(
            "[schema] activation connId=\(self.connectionId, privacy: .public) action=\(String(describing: action), privacy: .public)"
        )
        switch action {
        case .none:
            return
        case .awaitConnection:
            armPostConnectSchemaLoad()
        case .load:
            startSchemaLoad()
        }
    }

    /// Starts the schema load, or joins the one already running, and returns it. Every caller
    /// shares one load, so opening a connection no longer fetches every column twice, once for the
    /// view restoring its tabs and once for the view appearing.
    @discardableResult
    func startSchemaLoad() -> Task<Void, Never> {
        if let schemaLoadTask { return schemaLoadTask }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadSchema()
            self.schemaLoadTask = nil
            self.schemaLoadDriver = nil
        }
        schemaLoadTask = task
        schemaLoadDriver = services.databaseManager.driver(for: connectionId)
        return task
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
                    "[schema] initial load failed connId=\(self.connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public) \(message, privacy: .private)"
                )
                services.schemaService.markLoadFailed(connectionId: connectionId, message: message, scope: scope)
            }
            return
        }
        await DatabaseTreeMetadataService.shared.loadDatabases(
            connectionId: connectionId,
            databaseType: connection.type
        )
        await services.schemaRefreshService.syncAutocompleteProvider(connectionId: connectionId)
        pruneStaleSidebarState()
    }

    /// `.bulk` keeps the read off the connection the table's own metadata uses. The capability is
    /// read from the session driver: a pooled lease would connect a new driver only to learn the engine declines.
    func prefetchForeignKeys(scope: DatabaseScope) {
        guard services.databaseManager.driver(for: connectionId)?.providesBulkForeignKeyFetch == true else { return }
        SchemaForeignKeyStore.shared.prefetch(scope: scope) { [services] in
            do {
                return try await services.databaseManager.withMetadataDriver(
                    scope: scope,
                    workload: .bulk
                ) { driver in
                    try await driver.fetchAllForeignKeys(schema: scope.schema)
                }
            } catch {
                Self.logger.info(
                    "[fk] schema foreign key prefetch failed: \(error.publicLogShape, privacy: .public)"
                )
                return nil
            }
        }
    }

    // Beside a load's rows: the foreign key prefetch for any table, the schema read when the cache misses.
    func startSchemaFetch(
        _ tableName: String?,
        uncached: Bool,
        isView: Bool,
        scope: DatabaseScope
    ) -> Task<FetchedTableSchema, Error>? {
        if let tableName, !tableName.isEmpty { prefetchForeignKeys(scope: scope) }
        return QueryExecutor.schemaFetch(tableName: uncached ? tableName : nil, isView: isView, scope: scope)
    }

    /// The table a tab's Table Info describes, or nil on a tab with no table of its own, such as a
    /// query. The load's task key, the load and the read all ask this one question, so they agree on
    /// which tabs have Table Info and on when a retarget makes the cached numbers another table's.
    func tableInfoIdentity(of tab: QueryTab) -> TableTabIdentity? {
        tab.tableIdentity(browsing: browseDatabaseName)
    }

    /// Whether the cache already holds this tab's numbers.
    ///
    /// The panel used to be backed by one latest-wins slot, so alternating between two tabs missed
    /// it on every switch and ran a statistics command (`collStats` on MongoDB) each time. The entry
    /// is keyed by tab and stamped with the tab's last execution, so the next load after a reload, a
    /// page or a filter reads the numbers again, while a plain switch does not. (#2424)
    func hasCurrentTableMetadata(for tab: QueryTab) -> Bool {
        guard let entry = tableMetadataCache[tab.id], !entry.isStale else { return false }
        return entry.table == tableInfoIdentity(of: tab) && entry.lastExecutedAt == tab.execution.lastExecutedAt
    }

    /// The numbers loaded for this tab's table, or nil. Matched on the whole identity, so a table of
    /// the same name in another database or schema never shows them. A refresh keeps showing them
    /// until new ones arrive.
    func currentTableMetadata(for tab: QueryTab) -> TableMetadata? {
        guard let entry = tableMetadataCache[tab.id], entry.table == tableInfoIdentity(of: tab) else { return nil }
        return entry.metadata
    }

    /// Reads the tab's numbers once its rows have arrived, and only while the inspector, the one
    /// view that draws them, is on screen. A read before the rows would be stamped with no execution
    /// and read again the moment they land.
    func loadTableMetadata(for tab: QueryTab) async {
        guard let table = tableInfoIdentity(of: tab),
              let executedAt = tab.execution.lastExecutedAt,
              trailingPaneState?.inspector.isOnScreen == true,
              !hasCurrentTableMetadata(for: tab)
        else { return }
        guard let scope = scope(for: tab) else {
            Self.logger.error("Skipped table metadata load: no database bound to the tab")
            return
        }
        let generation = tableMetadataGeneration
        do {
            let metadata = try await services.databaseManager.withMetadataDriver(scope: scope) { driver in
                try await driver.fetchTableMetadata(tableName: table.table, schema: scope.schema)
            }
            /// The fetch cannot be cancelled, so it can land after its tab moved onto another table on
            /// the same id, or closed, and stored then it would show the numbers of what the tab used
            /// to show. A tab that only ran again keeps them, stamped with the run they were read for,
            /// so they show and the next load reads again; the load key does not move on a page, and
            /// dropping them would leave the panel empty. A read that started later and landed first,
            /// after another run or after an invalidation, is kept.
            guard let live = tabManager.tabs.first(where: { $0.id == tab.id }),
                  tableInfoIdentity(of: live) == table
            else { return }
            if let existing = tableMetadataCache[tab.id], existing.table == table,
               let existingStamp = existing.lastExecutedAt,
               (existingStamp, existing.generation) > (executedAt, generation) {
                return
            }
            tableMetadataCache[tab.id] = TableMetadataCacheEntry(
                table: table,
                lastExecutedAt: executedAt,
                generation: generation,
                metadata: metadata,
                isStale: generation != tableMetadataGeneration
            )
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Failed to load table metadata: \(error.publicLogShape, privacy: .public)")
        }
    }

    /// The object changed under the numbers without the tab running again, so the next load reads
    /// them afresh while the panel goes on showing the ones it has.
    func markTableMetadataStale(forTabs tabIds: some Sequence<UUID>) {
        tableMetadataGeneration &+= 1
        for tabId in tabIds {
            tableMetadataCache[tabId]?.isStale = true
        }
    }

    /// A rename leaves the tab on the same table under another name, so its numbers still describe
    /// it, and the panel draws none of them from the name. Moved onto the tab's new identity, they
    /// stay on screen with no read at all.
    func followRename(ofTableMetadataFor tab: QueryTab) {
        guard var entry = tableMetadataCache[tab.id], let table = tableInfoIdentity(of: tab) else { return }
        entry.table = table
        tableMetadataCache[tab.id] = entry
    }
}
