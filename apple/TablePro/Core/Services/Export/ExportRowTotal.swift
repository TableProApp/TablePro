//
//  ExportRowTotal.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// How one object's catalog estimate becomes its share of an export's progress total.
nonisolated enum ExportRowTotal {
    /// A filter keeps an unknown share of the rows, so no estimate says how many the export reads.
    static func isUnknowable(_ scope: PluginExportRowScope) -> Bool {
        !scope.sanitizedFilter.isEmpty
    }

    /// The rows the object adds to the total, or nil when nothing bounds them.
    static func rows(estimate: Int?, scope: PluginExportRowScope) -> Int? {
        guard !isUnknowable(scope), let estimate else { return nil }
        let estimated = max(0, estimate)
        guard let rowLimit = scope.rowLimit else { return estimated }
        return min(max(0, rowLimit), estimated)
    }
}
