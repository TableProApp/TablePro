//
//  SnowflakePluginDriver+Rename.swift
//  SnowflakeDriverPlugin
//

import Foundation
import TableProPluginKit

extension SnowflakePluginDriver {
    /// Snowflake accepts a qualified new name and treats it as a move, so both sides are qualified
    /// the same way and the statement can only rename in place.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let target = qualifiedName(table: name, schema: schema)
        let renamed = qualifiedName(table: newName, schema: schema)
        _ = try await execute(query: "ALTER \(objectType) \(target) RENAME TO \(renamed)")
    }

    /// Not the database the session is on: the rename succeeds but leaves the session pointing at
    /// a name that no longer exists, so the app keeps the item off the row it is browsing.
    func renameDatabase(name: String, to newName: String) async throws {
        _ = try await execute(
            query: "ALTER DATABASE \(quoteIdentifier(name)) RENAME TO \(quoteIdentifier(newName))"
        )
    }

    func renameSchema(name: String, to newName: String) async throws {
        _ = try await execute(
            query: "ALTER SCHEMA \(quoteIdentifier(name)) RENAME TO \(quoteIdentifier(newName))"
        )
    }
}
