//
//  DuckDBPluginDriver+Rename.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit

extension DuckDBPluginDriver {
    /// The new name is bare and the object stays in its schema. DuckDB has no `ALTER SCHEMA
    /// RENAME` and no database rename at all, so those stay unimplemented.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let quoted = quoteIdentifier(name)
        let target = schema.map { "\(quoteIdentifier($0)).\(quoted)" } ?? quoted
        _ = try await execute(query: "ALTER \(objectType) \(target) RENAME TO \(quoteIdentifier(newName))")
    }
}
