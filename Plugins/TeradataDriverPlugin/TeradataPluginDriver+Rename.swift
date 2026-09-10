//
//  TeradataPluginDriver+Rename.swift
//  TeradataDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProTeradataCore

extension TeradataPluginDriver {
    /// Teradata cannot move a table between databases, so the new name is bare and the object
    /// keeps its own. Views, macros and procedures each need their own `RENAME` keyword, which is
    /// what the object type carries.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let quoted = TeradataSchemaQueries.quoteIdentifier(name)
        let target = schema.map { "\(TeradataSchemaQueries.quoteIdentifier($0)).\(quoted)" } ?? quoted
        _ = try await execute(
            query: "RENAME \(objectType) \(target) TO \(TeradataSchemaQueries.quoteIdentifier(newName))"
        )
    }
}
