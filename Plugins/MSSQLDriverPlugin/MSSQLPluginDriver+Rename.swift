//
//  MSSQLPluginDriver+Rename.swift
//  MSSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MSSQLPluginDriver {
    /// `sp_rename` takes names as string literals rather than identifiers, and the new one must be
    /// a single part: passing `schema.new` renames the object to something literally called
    /// "schema.new". Its object type argument is what tells the procedure this is not a column.
    ///
    /// Each half of the old name is bracketed before the two are joined, because `@objname` is
    /// parsed as a multipart name: a table legitimately called `quarter.1` would otherwise be read
    /// as the object `1` in the schema `quarter`.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        let qualified = [schema, name].compactMap { $0 }.map(quoteIdentifier).joined(separator: ".")
        _ = try await execute(
            query: "EXEC sp_rename \(literal(qualified)), \(literal(newName)), 'OBJECT'"
        )
    }

    private func literal(_ value: String) -> String {
        "N'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
