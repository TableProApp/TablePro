//
//  DamengPluginDriver+Rename.swift
//  DamengDriverPlugin
//

import Foundation
import TableProPluginKit

extension DamengPluginDriver {
    /// Oracle-compatible, so the new name stays bare. Dameng also ships `sp_rename`, which is not
    /// used here: the ALTER form is the one its own documentation leads with.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let quoted = quoteIdentifier(name)
        let target = schema.map { "\(quoteIdentifier($0)).\(quoted)" } ?? quoted
        _ = try await execute(query: "ALTER \(objectType) \(target) RENAME TO \(quoteIdentifier(newName))")
    }
}
