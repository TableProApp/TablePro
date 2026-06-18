//
//  PaginationState+Display.swift
//  TablePro
//

import Foundation

extension PaginationState {
    func rangeText(loadedRowCount: Int) -> String? {
        if let total = totalRowCount, total > 0 {
            let formattedTotal = total.formatted(.number.grouping(.automatic))
            let prefix = isApproximateRowCount ? "~" : ""
            return String(format: String(localized: "%d-%d of %@%@ rows"), rangeStart, rangeEnd, prefix, formattedTotal)
        }
        if currentPage > 1 || loadedRowCount >= pageSize {
            let end = currentOffset + loadedRowCount
            return String(format: String(localized: "%d-%d of ? rows"), rangeStart, end)
        }
        return nil
    }

    static func pageSizeLabel(_ size: Int) -> String {
        size.formatted(.number.grouping(.never))
    }
}
