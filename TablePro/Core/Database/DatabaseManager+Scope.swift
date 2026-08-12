//
//  DatabaseManager+Scope.swift
//  TablePro
//

import Foundation

extension DatabaseManager {
    /// Where the connection's shared driver is pinned, as a scope. For connection-scoped work
    /// that has no window to ask. Never the scope a window browses, and never the scope of an
    /// operation an existing tab owns.
    func driverScope(for connectionId: UUID) -> DatabaseScope? {
        guard let session = activeSessions[connectionId] else { return nil }
        return DatabaseScope(
            connectionId: connectionId,
            database: session.resolvedDriverDatabase,
            schema: session.driverSchema
        )
    }

    /// Freezes a tab's identity once, at creation, the way `resolvedSchemaName` does one
    /// tier down: an explicit database passes through untouched, and only a missing one
    /// falls back to where the user happens to be browsing. Re-deriving it later is what
    /// lets a tab drift onto another database.
    func resolvedScope(database: String?, schema: String?, for connectionId: UUID) -> DatabaseScope? {
        let resolvedSchema = resolvedSchemaName(schema, for: connectionId)
        if let database, !database.isEmpty {
            return DatabaseScope(connectionId: connectionId, database: database, schema: resolvedSchema)
        }
        guard let session = activeSessions[connectionId] else { return nil }
        return DatabaseScope(
            connectionId: connectionId,
            database: session.resolvedDriverDatabase,
            schema: resolvedSchema
        )
    }
}
