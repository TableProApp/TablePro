//
//  TableDDLComposer.swift
//  TablePro
//

import Foundation

/// Joins a table's `CREATE TABLE` to the statements that stand outside it.
///
/// A driver answers `fetchTableDDL` with the table alone and `fetchIndexDDL` with the indexes that
/// statement does not declare, because a dump replays them in different phases: the table before
/// its rows, the indexes after. Anything showing one table's whole definition at once, Copy DDL and
/// the MCP schema tools among them, puts the two back together here rather than each spelling out
/// its own separator.
internal enum TableDDLComposer {
    internal static func compose(tableDDL: String, indexDDL: [String], preamble: String = "") -> String {
        let statements = indexDDL
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(";") ? $0 : "\($0);" }

        var composed = preamble.isEmpty ? tableDDL : "\(preamble)\n\(tableDDL)"
        guard !statements.isEmpty else { return composed }
        if !composed.hasSuffix(";") {
            composed += ";"
        }
        return composed + "\n\n" + statements.joined(separator: "\n")
    }
}
