import Foundation
import TableProPluginKit

// A result set has no schema behind it, so a query export never asks for structure or drop: drop alone wrote
// `DROP TABLE <the source table>` into a dump that never recreated it.
nonisolated enum QueryExportOptions {
    private static let schemaColumnIds: Set<String> = ["structure", "drop"]

    // Cleared by column id, not position: SQL declares [structure, drop, data] and MQL [drop, indexes, data].
    // A defaults array of the wrong length is dropped whole, as `ExportObjectItem.normalized` does.
    static func dataOnly(
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
