//
//  MainContentCoordinator+Scope.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// A tab's target, read only from the tab and its connection. It deliberately reads
    /// no window, toolbar or coordinator state, so moving the tab to another window
    /// cannot change what it queries.
    ///
    /// It resolves before a session exists, because a tab already knows its own database
    /// and the connection knows its saved default. Only the browse-cursor fallback, for a
    /// tab that never recorded one, needs a live session.
    func scope(for tab: QueryTab) -> DatabaseScope? {
        if let resolved = services.databaseManager.resolvedScope(
            database: tab.tableContext.databaseName,
            schema: tab.tableContext.schemaName,
            for: connectionId
        ) {
            return resolved
        }
        let database = tab.tableContext.databaseName.isEmpty
            ? connection.database
            : tab.tableContext.databaseName
        return DatabaseScope(
            connectionId: connectionId,
            database: database,
            schema: tab.tableContext.schemaName
        )
    }

    var selectedTabScope: DatabaseScope? {
        guard let tab = tabManager.selectedTab else { return browseScope }
        return scope(for: tab)
    }

    /// Where THIS window's sidebar is pointing. Correct for the object list and for seeding a
    /// new tab, never for an operation an open tab owns.
    ///
    /// Non-optional, unlike the connection's driver scope: a window always knows the container
    /// it is showing, even before a session exists, because it falls back to the connection's
    /// saved default rather than to nothing.
    var browseScope: DatabaseScope {
        DatabaseScope(
            connectionId: connectionId,
            database: browseDatabaseName,
            schema: browseSchemaName
        )
    }

    /// The objects this window's sidebar is showing. Reading the connection's session tables
    /// instead hands back whatever container the shared driver sits on, which is another
    /// window's selection as often as it is this one's.
    var browseTables: [TableInfo] {
        services.schemaService.tables(for: browseScope)
    }

    /// Puts this window back on the container it was saved browsing, without touching the driver.
    ///
    /// Restore cannot go through `switchDatabase`: N windows restoring would fire N
    /// connection-wide switches at one driver and the last to land would drag every window onto its
    /// database, which is the bug per-window browse state exists to close. The switch did carry one
    /// thing this path still needs, though. A window's first schema load reads `browseScope` before
    /// the saved state comes back off disk, so a cursor that moves afterwards points at a container
    /// nobody has loaded, and the object list sits empty on the container the user actually left the
    /// window on. Asking for that load is the whole reason this is not a bare `applyBrowseState`.
    internal func seedRestoredBrowseState(_ state: WindowBrowseState) {
        guard !state.isUnset else { return }
        let previousScope = browseScope
        applyBrowseState(state)
        guard browseScope != previousScope else { return }
        Task { await loadSchemaIfNeeded() }
    }

    /// Creates the provider as well as retaining it, because the autocomplete sync that runs
    /// right after a database switch only fills a provider that already exists.
    internal func retainSchemaProvider(for scope: DatabaseScope) {
        guard retainedSchemaProviderScope != scope else { return }
        if let previous = retainedSchemaProviderScope {
            services.schemaProviderRegistry.release(for: previous)
        }
        _ = services.schemaProviderRegistry.getOrCreate(for: scope)
        services.schemaProviderRegistry.retain(for: scope)
        retainedSchemaProviderScope = scope
    }

    /// Follows the browse cursor, so a window that moved to another database stops holding the
    /// scope it left alive. A window that never retained one must not start here.
    internal func moveRetainedSchemaProvider() {
        guard retainedSchemaProviderScope != nil else { return }
        retainSchemaProvider(for: browseScope)
    }

    internal func releaseRetainedSchemaProvider() {
        guard let scope = retainedSchemaProviderScope else { return }
        retainedSchemaProviderScope = nil
        services.schemaProviderRegistry.release(for: scope)
    }
}
