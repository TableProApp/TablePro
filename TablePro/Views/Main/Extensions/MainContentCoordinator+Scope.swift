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
}
