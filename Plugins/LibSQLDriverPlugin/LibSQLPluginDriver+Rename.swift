//
//  LibSQLPluginDriver+Rename.swift
//  LibSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension LibSQLPluginDriver {
    /// SQLite's rules, and SQLite's one rename: `ALTER TABLE` refuses a view. A Turso database
    /// name has no libSQL wire operation, which is why `dropDatabase` already refuses too.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        guard objectType.uppercased() == "TABLE" else {
            throw PluginDriverUnsupportedOperation.renameTable
        }
        _ = try await execute(
            query: "ALTER TABLE \(quoteIdentifier(name)) RENAME TO \(quoteIdentifier(newName))"
        )
    }
}
