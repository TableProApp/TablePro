//
//  DatabaseManager+Scope.swift
//  TablePro
//

import Foundation

extension DatabaseManager {
    /// The scope a new tab inherits and the sidebar lists. Never the scope of an
    /// operation an existing tab owns.
    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        guard let session = activeSessions[connectionId] else { return nil }
        return DatabaseScope(
            connectionId: connectionId,
            database: session.resolvedBrowseDatabase,
            schema: session.browseSchema
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
            database: session.resolvedBrowseDatabase,
            schema: resolvedSchema
        )
    }
}
