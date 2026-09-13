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

    /// Freezes a tab's identity once, at creation, the way `resolvedSchemaName(_:inDatabase:for:)`
    /// does one tier down: an explicit database passes through untouched, and only a missing one
    /// falls back to where the user happens to be browsing. Re-deriving it later is what
    /// lets a tab drift onto another database.
    func resolvedScope(database: String?, schema: String?, for connectionId: UUID) -> DatabaseScope? {
        if let database, !database.isEmpty {
            return DatabaseScope(
                connectionId: connectionId,
                database: database,
                schema: resolvedSchemaName(schema, inDatabase: database, for: connectionId)
            )
        }
        guard let session = activeSessions[connectionId] else { return nil }
        return DatabaseScope(
            connectionId: connectionId,
            database: session.resolvedBrowseDatabase,
            schema: resolvedSchemaName(schema, inDatabase: nil, for: connectionId)
        )
    }

    /// Authoritative schema for a table identity. An explicit schema passes through unchanged; a
    /// blank or missing one resolves to the live session's current schema and stays nil for
    /// schema-less engines. A blank name never reaches a query builder: engines that qualify
    /// object names treat it as "no schema" and emit an unqualified name.
    ///
    /// A schema name only means something inside the database that holds it, so the browsing
    /// fallback stops at a database boundary: a caller naming another database and no schema gets
    /// no schema, not the one the user happens to be on here. Carrying it across made the sidebar
    /// ask a newly attached database for a schema that lives in a different one, and bound a table
    /// opened in another database from a link to a schema that database may not have.
    func resolvedSchemaName(_ schemaName: String?, inDatabase database: String?, for connectionId: UUID) -> String? {
        guard let database, !database.isEmpty,
              database != activeSessions[connectionId]?.resolvedBrowseDatabase else {
            return resolvedSchemaName(schemaName, for: connectionId)
        }
        guard let schemaName, !schemaName.isEmpty else { return nil }
        return schemaName
    }

    private func resolvedSchemaName(_ schemaName: String?, for connectionId: UUID) -> String? {
        if let schemaName, !schemaName.isEmpty { return schemaName }
        guard let sessionSchema = activeSessions[connectionId]?.browseSchema, !sessionSchema.isEmpty else {
            return nil
        }
        return sessionSchema
    }
}
