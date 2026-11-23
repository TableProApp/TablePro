//
//  SavedRowsCountEffect.swift
//  TablePro
//

import Foundation

// What a successful save does to the row total its tab shows. A total at or past the count threshold stays as an
// estimate, which the next count skips: recounting it reads up to the threshold and then blanks the total.
enum SavedRowsCountEffect: Equatable {
    case estimate
    case retire

    struct Tab: Equatable {
        let narrowsRows: Bool
        let showsTruncatedTable: Bool
        let totalRowCount: Int?
    }

    static func effect(on tab: Tab, threshold: Int) -> Self {
        guard !tab.narrowsRows, !tab.showsTruncatedTable, let total = tab.totalRowCount, total >= threshold else {
            return .retire
        }
        return .estimate
    }
}
