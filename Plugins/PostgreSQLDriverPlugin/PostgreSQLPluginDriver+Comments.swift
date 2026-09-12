//
//  PostgreSQLPluginDriver+Comments.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    /// A plain read rather than the `search_path`-emptied one `fetchViewDefinition` takes: nothing
    /// here is deparsed by the server, so the session's path cannot change the answer.
    ///
    /// Cockroach, Redshift and PGlite inherit this, which is correct: all three keep
    /// `obj_description` and `col_description`.
    func fetchCommentDDL(table: String, schema: String?) async throws -> [String] {
        let resolvedSchema = schema ?? core.currentSchema
        let query = PostgreSQLCommentStatements.catalogQuery(name: table, schema: resolvedSchema)
        let result = try await execute(query: query)
        return PostgreSQLCommentStatements.statements(
            name: table,
            schema: resolvedSchema,
            rows: result.rows.map { $0.map(\.asText) }
        )
    }
}
