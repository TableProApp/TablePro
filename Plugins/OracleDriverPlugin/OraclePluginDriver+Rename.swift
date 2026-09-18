//
//  OraclePluginDriver+Rename.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

extension OraclePluginDriver {
    /// The new name must be bare. A qualified one raises ORA-14047, because Oracle renames in
    /// place and has no statement that moves an object between schemas.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let quoted = OracleObjectQueries.quoteIdentifier(name)
        let target = schema.map { "\(OracleObjectQueries.quoteIdentifier($0)).\(quoted)" } ?? quoted
        _ = try await execute(
            query: "ALTER \(objectType) \(target) RENAME TO \(OracleObjectQueries.quoteIdentifier(newName))"
        )
    }
}
