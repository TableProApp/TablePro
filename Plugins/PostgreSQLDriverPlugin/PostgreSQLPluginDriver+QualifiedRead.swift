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
}
