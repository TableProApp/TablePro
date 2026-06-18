//
//  StatusBarSnapshot+RowInfo.swift
//  TablePro
//

import Foundation

extension StatusBarSnapshot {
    func statusText(selectedCount: Int) -> String? {
        let loadedCount = rowCount

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
        if tabType == .table, showsPaginationControls {
            return nil
        }
        if loadedCount > 0 {
            let formattedCount = loadedCount.formatted(.number.grouping(.automatic))
            return String(format: String(localized: "%@ rows"), formattedCount)
        }
        return String(localized: "No rows")
    }
}
