//
//  DataGridBodyChrome.swift
//  TablePro
//

import AppKit

/// The single owner of the data grid body's column separators, as `SortableHeaderChrome` is for the
/// header.
///
/// `NSTableView` draws vertical grid lines by keeping one separator view per column as its own
/// subview, and it re-sorts that whole subview list on every layout pass. That is O(columns) views
/// and O(columns squared) work per pass: measured at 518ms for a single pass on a 500-column result,
/// against 0.03ms with the mask cleared. Adding or removing any subview of the table view, which is
/// exactly what opening the inline cell editor does, forces such a pass. So the grid clears
/// `gridStyleMask` and draws the separators itself (#2381).
///
/// Where they are drawn follows AppKit's own split rather than inventing one. A row view covers
/// whatever the table view draws underneath it, which is why AppKit puts its horizontal separator
/// inside `NSTableRowView.drawSeparator(in:)` and can only put a vertical one in a view above the
/// rows. So a row draws the separators crossing it, and the table view draws only the area below the
/// last row, where nothing covers it.
@MainActor
enum DataGridBodyChrome {
    static let separatorThickness: CGFloat = 1

    /// Where the separators fall: one standing at the leading edge of every presented column the
    /// rect reaches.
    ///
    /// The leading edge, not the trailing one, is where AppKit put it, and taking the boundary from
    /// the column rather than from a fixed step keeps the row-number column's edge and leaves the
    /// pool's spacers without one.
    ///
    /// Pure, and separate from the drawing, so a test can measure the geometry against
    /// `rect(ofColumn:)` without a graphics context.
    ///
    /// - Parameters:
    ///   - rect: the area being drawn, in the coordinate space of `view`.
    ///   - view: the view drawing, which supplies the space the column rects are converted into.
    static func separatorRects(
        in rect: NSRect,
        of view: NSView,
        tableView: NSTableView,
        presentsColumn: (Int) -> Bool
    ) -> [NSRect] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let inTableView = view.convert(rect, to: tableView)
        return tableView.columnIndexes(in: inTableView).compactMap { tableColumnIndex in
            guard presentsColumn(tableColumnIndex) else { return nil }
            let columnRect = view.convert(tableView.rect(ofColumn: tableColumnIndex), from: tableView)
            guard columnRect.width > 0 else { return nil }
            let separator = NSRect(
                x: columnRect.minX - separatorThickness,
                y: rect.minY,
                width: separatorThickness,
                height: rect.height
            )
            return separator.intersects(rect) ? separator : nil
        }
    }

    static func drawColumnSeparators(
        in rect: NSRect,
        of view: NSView,
        tableView: NSTableView,
        presentsColumn: (Int) -> Bool
    ) {
        let separators = separatorRects(in: rect, of: view, tableView: tableView, presentsColumn: presentsColumn)
        guard !separators.isEmpty else { return }
        tableView.gridColor.setFill()
        separators.forEach { $0.fill() }
    }
}
