import Foundation
import TableProPluginKit

// Clears every option a format says a kind does not take, so a routine never carries a Data flag that would make it
// look exportable for a phase it has no rows for. Values that do not line up with the columns are left alone.
nonisolated enum ExportOptionMask {
    static func masked(
        _ values: [Bool],
        columns: [PluginExportOptionColumn],
        kind: PluginExportObjectKind,
        supports: (String, PluginExportObjectKind) -> Bool
    ) -> [Bool] {
        guard values.count == columns.count else { return values }
        return zip(columns, values).map { column, value in
            supports(column.id, kind) ? value : false
        }
    }
}
