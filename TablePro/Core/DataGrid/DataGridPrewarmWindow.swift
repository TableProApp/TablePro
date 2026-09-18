//
//  DataGridPrewarmWindow.swift
//  TablePro
//
//  The slice of a result the data grid formats ahead of the viewport.
//

import Foundation

/// The rows the background prewarm may format, as a function of the rows on screen.
///
/// Kept apart from the coordinator so the bound can be asserted without an `NSTableView`.
enum DataGridPrewarmWindow {
    static let margin = 250

    static func rows(around visible: Range<Int>, displayCount: Int) -> Range<Int> {
        guard displayCount > 0 else { return 0..<0 }
        let lower = max(0, min(visible.lowerBound, displayCount) - margin)
        let upper = min(displayCount, max(visible.lowerBound, visible.upperBound) + margin)
        guard lower < upper else { return 0..<0 }
        return lower..<upper
    }
}
