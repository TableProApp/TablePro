//
//  QueryExportOptions.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Which per-object options a query export may ask for.
///
/// A result set has no schema behind it. `fetchTableDDL` returns an empty string on both query data
/// sources, so asking for structure produces no `CREATE` at all, and leaving drop on beside it
/// wrote `DROP TABLE <the source table>` into a dump that then never recreated it. The name is the
/// real table's whenever the export came from a table tab, so the dump destroyed what it claimed to
/// copy.
internal enum QueryExportOptions {
    /// The option columns a source with no DDL must not be asked for.
    private static let schemaColumnIds: Set<String> = ["structure", "drop"]

    /// Cleared by column id rather than by position. The ids are per format and the positions do
    /// not line up: SQL export declares `[structure, drop, data]` while MQL export declares
    /// `[drop, indexes, data]`, so clearing index 0 and 1 would turn off MQL's indexes and leave
    /// its drop on, which is the opposite of what is wanted.
    ///
    /// A defaults array that is not the length of the column list is discarded whole rather than
    /// read element-wise, because a mismatched array is exactly the misalignment this is here to
    /// avoid. `ExportObjectItem.normalized(forOptionColumnCount:defaultOptionValues:)` already
    /// treats one that way.
    internal static func dataOnly(
        columns: [PluginExportOptionColumn],
        defaults: [Bool]
    ) -> [Bool] {
        let aligned = defaults.count == columns.count ? defaults : []
        return columns.enumerated().map { index, column -> Bool in
            guard !schemaColumnIds.contains(column.id) else { return false }
            return aligned.indices.contains(index) ? aligned[index] : column.defaultValue
        }
    }
}
