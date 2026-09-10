//
//  TrinoPluginDriver+Rename.swift
//  TrinoDriverPlugin
//

import Foundation
import TableProPluginKit

extension TrinoPluginDriver {
    /// Whether this works at all is the connector's decision, and many answer "this connector does
    /// not support renaming tables". That message is the honest one to show, so nothing here tries
    /// to predict it. The new name is bare: Trino renames within a schema and never across a
    /// catalog.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let quoted = quoteIdentifier(name)
        let target = schema.map { "\(quoteIdentifier($0)).\(quoted)" } ?? quoted
        _ = try await execute(query: "ALTER \(objectType) \(target) RENAME TO \(quoteIdentifier(newName))")
    }

    /// A Trino "database" in the tree is a catalog, which is configuration rather than an object,
    /// so only the schema level is renameable.
    func renameSchema(name: String, to newName: String) async throws {
        _ = try await execute(
            query: "ALTER SCHEMA \(quoteIdentifier(name)) RENAME TO \(quoteIdentifier(newName))"
        )
    }
}
