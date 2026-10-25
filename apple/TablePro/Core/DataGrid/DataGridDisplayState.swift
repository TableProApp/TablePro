//
//  DataGridDisplayState.swift
//  TablePro
//

import Foundation

// Formatted text kept by the model, so a remount of the grid draws from it instead of formatting every row again (#2424).
@MainActor
final class DataGridDisplayState {
    let cache = RowDisplayCache()
    var highlightRuleSetKey: HighlightRuleSet.Key?
}
