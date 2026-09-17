//
//  MainContentCoordinator+CatalogChange.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What a window does with a change to its connection's catalog. The connection-level half has
/// already run once in `CatalogChangeService`; this is the part each window owns: its tabs, its
/// selection and its cached columns.
extension MainContentCoordinator {
    /// Reported whether the statement succeeded or failed: DDL that commits as it runs, a procedure
    /// or a dropped connection can leave the catalog changed behind an error.
    nonisolated static func postStatementRan(_ sql: String, on connection: DatabaseConnection) {
        CatalogChangeService.post(
            .statementsRan(connectionId: connection.id, statements: [sql], databaseType: connection.type)
        )
    }

    func applyCatalogChange(_ change: CatalogChange) {
        guard change.connectionId == connectionId else { return }
        schemaColumns.removeAll()
        pruneStaleSidebarState()
    }

    func applyContainerChange(_ change: DatabaseContainerChange) {
        guard change.connectionId == connectionId else { return }
        let container = change.container
        let database = container.database ?? browseDatabaseName
        switch (change.kind, container.kind) {
        case (.dropped, .database):
            closeTabsForRemovedObjects(ids: tableTabIds(inDatabase: database, schema: nil))
        case (.dropped, .schema):
            closeTabsForRemovedObjects(ids: tableTabIds(inDatabase: database, schema: container.schema))
        case (.renamed(let newName), .database):
            retargetTabs(database: database, schema: nil, toDatabase: newName, toSchema: nil)
        case (.renamed(let newName), .schema):
            guard let schema = container.schema else { return }
            retargetTabs(database: database, schema: schema, toDatabase: database, toSchema: newName)
        }
    }

    /// Selection and queued operations naming objects the freshly loaded catalog no longer has,
    /// judged by the object each names rather than by a bare table name.
    func pruneStaleSidebarState() {
        let adoption = CatalogEditAdoption(
            databaseManager: services.databaseManager,
            schemaService: services.schemaService
        )
        adoption.pruneStaleOperations(connectionId: connectionId)
        guard let catalog = adoption.loadedBrowseCatalog(connectionId: connectionId) else { return }
        let selected = windowSidebarState.selectedTables
        let stale = catalog.staleRefs(in: selected)
        guard !stale.isEmpty else { return }
        windowSidebarState.selectTables(selected.subtracting(stale))
    }

    private func tableTabIds(inDatabase database: String, schema: String?) -> [UUID] {
        let browseDatabase = browseDatabaseName
        return tabManager.tabs.filter { tab in
            guard tab.tabType == .table,
                  tab.tableContext.resolvedDatabaseName(browsing: browseDatabase) == database else { return false }
            guard let schema else { return true }
            return tab.tableContext.schemaName?.nilIfEmpty == schema
        }.map(\.id)
    }
}
