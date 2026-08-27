//
//  CloudflareD1PluginDriver+Rename.swift
//  CloudflareD1DriverPlugin
//

import Foundation
import TableProPluginKit

extension CloudflareD1PluginDriver {
    /// SQLite's rules, and SQLite's one rename: `ALTER TABLE` refuses a view. A D1 database is an
    /// API object whose edit endpoint accepts only read replication, so its name cannot change.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        guard objectType.uppercased() == "TABLE" else {
            throw PluginDriverUnsupportedOperation.renameTable
        }
        _ = try await execute(
            query: "ALTER TABLE \(quoteIdentifier(name)) RENAME TO \(quoteIdentifier(newName))"
        )
    }
}
