//
//  StatusBarSnapshot+RowInfo.swift
//  TablePro
//

import Foundation

extension StatusBarSnapshot {
    func rowInfoText(selectedCount: Int) -> String {
        let loadedCount = rowCount
        let total = pagination.totalRowCount

        if selectedCount > 0 {
            if selectedCount == loadedCount {
                return String(format: String(localized: "All %d rows selected"), loadedCount)
            }
            return String(format: String(localized: "%d of %d rows selected"), selectedCount, loadedCount)
        }
        if tabType == .query, pagination.hasMoreRows {
            let formattedCount = loadedCount.formatted(.number.grouping(.automatic))
            return String(format: String(localized: "Showing %@ rows"), formattedCount)
        }
        if tabType == .table, let total, total > 0 {
            let formattedTotal = total.formatted(.number.grouping(.automatic))
            let prefix = pagination.isApproximateRowCount ? "~" : ""
            return String(format: String(localized: "%d-%d of %@%@ rows"), pagination.rangeStart, pagination.rangeEnd, prefix, formattedTotal)
        }
        if tabType == .table, isPagedWithUnknownTotal {
            let rangeEnd = pagination.currentOffset + loadedCount
            return String(format: String(localized: "%d-%d of ? rows"), pagination.rangeStart, rangeEnd)
        }
        if loadedCount > 0 {
            let formattedCount = loadedCount.formatted(.number.grouping(.automatic))
            return String(format: String(localized: "%@ rows"), formattedCount)
        }
        return String(localized: "No rows")
    }
}
