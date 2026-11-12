//
//  MainContentCoordinator+DatabaseFileChanges.swift
//  TablePro
//

import Foundation

// Every commit rewrites a database file, so a file event alone says nothing about the catalog. The engine's
// schema token does: the catalog reloads only when it moved, or when the engine has none.
internal struct SchemaChangeTokenGate: Equatable {
    // Read before the catalog it stands for, so it never claims a schema newer than the one loaded.
    private(set) var loadedToken: String?

    mutating func admits(_ token: String?) -> Bool {
        if let token, token == loadedToken { return false }
        loadedToken = token
        return true
    }

    mutating func forget() {
        loadedToken = nil
    }
}

extension MainContentCoordinator {
    func refreshTablesIfSchemaChanged() async {
        let token = try? await services.databaseManager.withBrowseMetadataDriver(connectionId: connectionId) { driver in
            try await (driver as? PluginDriverAdapter)?.schemaChangeToken()
        }
        guard schemaTokenGate.admits(token) else { return }
        DatabaseTreeMetadataService.shared.markListsStale(connectionId: connectionId)
        schemaColumns.removeAll()
        // Never joins a load that began before this write: that load's catalog predates the new token.
        let committed = await services.schemaRefreshService.refreshAfterWrite(connection: connection)
        // Another window's refresh may have replaced this one; prune against the catalog it leaves.
        await services.schemaRefreshService.waitForRefresh(connectionId: connectionId)
        pruneStaleSidebarState()
        if !committed {
            schemaTokenGate.forget()
        }
    }
}
