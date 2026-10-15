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

    /// The table an open by name lands on. The open path binds a missing database to the browse
    /// cursor and a missing schema through `resolvedSchemaName`, so a lookup for a tab already
    /// showing it resolves the same way. Treating a missing part as "any" matched `tenant_a.orders`
    /// for a request that meant the `orders` of the database being browsed.
    func requestedTableIdentity(
        table: String,
        database: String?,
        schema: String?,
        for connectionId: UUID
    ) -> TableTabIdentity {
        let named = database.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedDatabase = named ?? activeSessions[connectionId]?.resolvedBrowseDatabase ?? ""
        return TableTabIdentity(
            table: table,
            database: resolvedDatabase,
            schema: resolvedSchemaName(schema, inDatabase: resolvedDatabase, for: connectionId)
        )
    }

    /// The identity of a table tab as it stands, with an unbound database read as the browse
    /// cursor, the rule `TabTableContext.resolvedDatabaseName(browsing:)` defines.
    func tableIdentity(of tab: QueryTab, for connectionId: UUID) -> TableTabIdentity? {
        tab.tableIdentity(browsing: activeSessions[connectionId]?.resolvedBrowseDatabase ?? "")
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
