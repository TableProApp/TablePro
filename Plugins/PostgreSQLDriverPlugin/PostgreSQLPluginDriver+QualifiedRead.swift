//
//  PostgreSQLPluginDriver+QualifiedRead.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    /// Reads with `search_path` narrowed to `pg_catalog`, so every name the server deparses comes
    /// back qualified. A view body and a column's type, default and generation expression go through
    /// here, because each is replayed as SQL on a connection whose path is some other schema.
    ///
    /// The narrowed path lasts only as long as the read, including on a session a query tab left
    /// inside `BEGIN`; `LibPQPluginConnection.executeTransactionScopedRead` says how.
    func executeQualifiedRead(_ query: String) async throws -> PluginQueryResult {
        try await core.executeTransactionScopedRead(PostgreSQLViewDefinition.qualifiedReadPrefix + query)
    }

    /// Reads with `search_path` narrowed to `pg_catalog` and one schema, so every name the server
    /// deparses is relative to that schema: its own types bare, other schemas' qualified. The column
    /// read goes through here, because that is the spelling a person reads in the Structure tab and
    /// the one two schemas are compared in.
    ///
    /// Scoped to the read the same way `executeQualifiedRead` is.
    func executeSchemaRelativeRead(_ query: String, schema: String) async throws -> PluginQueryResult {
        try await core.executeTransactionScopedRead(
            PostgreSQLSchemaQueries.schemaRelativeReadPrefix(schema: schema) + query
        )
    }
}
