//
//  OraclePluginDriver+Rename.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated extension OraclePluginDriver {
    // A qualified new name raises ORA-14047: Oracle renames in place and cannot move an object between schemas.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let quoted = OracleObjectQueries.quoteIdentifier(name)
        let target = schema.map { "\(OracleObjectQueries.quoteIdentifier($0)).\(quoted)" } ?? quoted
        _ = try await execute(
            query: "ALTER \(objectType) \(target) RENAME TO \(OracleObjectQueries.quoteIdentifier(newName))"
        )
    }
}
