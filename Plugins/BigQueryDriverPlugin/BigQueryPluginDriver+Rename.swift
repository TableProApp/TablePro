//
//  BigQueryPluginDriver+Rename.swift
//  BigQueryDriverPlugin
//

import Foundation
import TableProPluginKit

extension BigQueryPluginDriver {
    /// The new name is bare and the table stays in its dataset. BigQuery refuses the statement
    /// while a streaming buffer is active, which is roughly five hours after the last row streamed
    /// in, and for an external table; both come back as the server's own message.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let quoted = quoteIdentifier(name)
        let target = schema.map { "\(quoteIdentifier($0)).\(quoted)" } ?? quoted
        _ = try await execute(query: "ALTER \(objectType) \(target) RENAME TO \(quoteIdentifier(newName))")
    }
}
