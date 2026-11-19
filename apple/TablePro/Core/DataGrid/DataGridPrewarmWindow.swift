//
//  DataGridPrewarmWindow.swift
//  TablePro
//
//  The slice of a result the data grid formats ahead of the viewport.
//

import Foundation
import TableProPluginKit

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

// A few rows of the window, copied out so the formatting never holds the result's whole buffer: an edit made
// meanwhile would then copy every row.
struct DataGridPrewarmBatch: Sendable {
    static let rowLimit = 32

    let rows: [Row]
    let columnCount: Int
    let columnTypes: [ColumnType]
    let formats: [ValueDisplayFormat?]
    let databaseType: DatabaseType?
    let dateFormat: DateFormatOption
    // What the display cache had dropped when the rows were copied; text formatted before a later drop is stale.
    let invalidations: Int

    // A renderer serves one thread, so each batch builds its own from the format.
    @concurrent
    nonisolated func formatted() async -> sending [(id: RowID, box: RowDisplayBox)] {
        let dates = DateDisplayRenderer(format: dateFormat)
        var formatted: [(id: RowID, box: RowDisplayBox)] = []
        formatted.reserveCapacity(rows.count)
        for row in rows where !Task.isCancelled {
            let box = RowDisplayBox(ContiguousArray<String?>(repeating: nil, count: columnCount))
            for dataIndex in 0..<min(row.values.count, columnCount) {
                let display = CellDisplayFormatter.display(
                    row.values[dataIndex],
                    columnType: dataIndex < columnTypes.count ? columnTypes[dataIndex] : nil,
                    displayFormat: dataIndex < formats.count ? formats[dataIndex] : nil,
                    databaseType: databaseType,
                    dates: dates
                )
                box.setText(display.text ?? row.values[dataIndex].asText ?? "", at: dataIndex, isFormatted: display.isFormatted)
            }
            formatted.append((row.id, box))
        }
        return formatted
    }
}
