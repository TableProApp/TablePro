//
//  MainContentCoordinator+Scope.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// A tab's target, read only from the tab and its connection. It deliberately reads
    /// no window, toolbar or coordinator state, so moving the tab to another window
    /// cannot change what it queries.
    func scope(for tab: QueryTab) -> DatabaseScope? {
        services.databaseManager.resolvedScope(
            database: tab.tableContext.databaseName,
            schema: tab.tableContext.schemaName,
            for: connectionId
        )
    }

    var selectedTabScope: DatabaseScope? {
        guard let tab = tabManager.selectedTab else { return browseScope }
        return scope(for: tab)
    }

    /// Where the sidebar is pointing. Correct for the object list and for seeding a new
    /// tab, never for an operation an open tab owns.
    var browseScope: DatabaseScope? {
        services.databaseManager.browseScope(for: connectionId)
    }
}
