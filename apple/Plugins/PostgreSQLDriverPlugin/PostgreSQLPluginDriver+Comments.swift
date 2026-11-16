//
//  PostgreSQLPluginDriver+Comments.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

// PGlite inherits this. CockroachDB and Redshift conform to `LibPQBackedDriver` directly, so they do not.
extension PostgreSQLPluginDriver {
    func fetchCommentDDL(table: String, schema: String?) async throws -> [String] {
        try await exportCatalog.fetchCommentDDL(table: table, schema: schema)
    }
}
