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
    ///
    /// A schema name only means something inside the database that holds it, so the
    /// browsing fallback stops at a database boundary: a caller naming another database
    /// and no schema gets no schema, not the one the user happens to be on here. Carrying
    /// it across made the sidebar ask a newly attached database for a schema that lives in
    /// a different one, and the engine rejected the whole read.
    func resolvedScope(database: String?, schema: String?, for connectionId: UUID) -> DatabaseScope? {
        if let database, !database.isEmpty {
            let isBrowsedDatabase = activeSessions[connectionId]?.resolvedBrowseDatabase == database
            let inheritedSchema = isBrowsedDatabase ? resolvedSchemaName(schema, for: connectionId) : schema
            return DatabaseScope(connectionId: connectionId, database: database, schema: inheritedSchema)
        }
        guard let session = activeSessions[connectionId] else { return nil }
        return DatabaseScope(
            connectionId: connectionId,
            database: session.resolvedBrowseDatabase,
            schema: resolvedSchemaName(schema, for: connectionId)
        )
    }
}
