//
//  DataGridDisplayState.swift
//  TablePro
//

import Foundation

// Formatted text kept by the model, so a remount of the grid draws from it instead of formatting every row again (#2424).
@MainActor
final class DataGridDisplayState {
    let lineCounts: RowLineCountStore
    let cache: RowDisplayCache
    var highlightRuleSetKey: HighlightRuleSet.Key?
    // Whether the cached text kept its line breaks, which only a grid that wraps asks for.
    var keepsLineBreaks = false

    init() {
        let lineCounts = RowLineCountStore()
        self.lineCounts = lineCounts
        cache = RowDisplayCache(lineCounts: lineCounts)
    }
}
