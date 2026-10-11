//
//  DataGridBodyChrome.swift
//  TablePro
//

import AppKit

/// The single owner of the data grid body's column separators and of the table's background, as
/// `SortableHeaderChrome` is for the header.
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
        ThemeEngine.shared.palette[.gridLine].setFill()
        separators.forEach { $0.fill() }
    }

    // MARK: - Row backgrounds

    /// One row's band in the space of the view asking: a row of the table, or one of the bands past
    /// the last row that the alternation continues through.
    struct RowBand: Equatable {
        let row: Int
        let rect: NSRect
        let isTableRow: Bool
    }

    /// Every band the rect reaches: the table's rows, then bands one row apart past the last row,
    /// numbered on from it, which is where `NSTableView` continues the alternation.
    ///
    /// - Parameters:
    ///   - rect: the area being drawn, in the coordinate space of `view`.
    ///   - view: the view drawing, which supplies the space the bands are converted into.
    static func rowBands(in rect: NSRect, of view: NSView, tableView: NSTableView) -> [RowBand] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let inTableView = view.convert(rect, to: tableView)
        let rows = tableView.rows(in: inTableView)
        var bands = (rows.location..<(rows.location + rows.length)).map { row in
            RowBand(row: row, rect: view.convert(tableView.rect(ofRow: row), from: tableView), isTableRow: true)
        }

        let pitch = tableView.rowHeight + tableView.intercellSpacing.height
        let rowCount = tableView.numberOfRows
        let lastRowBottom = rowCount > 0 ? tableView.rect(ofRow: rowCount - 1).maxY : tableView.bounds.minY
        guard pitch > 0, inTableView.maxY > lastRowBottom else { return bands }

        var index = max(0, Int(((inTableView.minY - lastRowBottom) / pitch).rounded(.down)))
        while lastRowBottom + CGFloat(index) * pitch < inTableView.maxY {
            let band = NSRect(
                x: inTableView.minX,
                y: lastRowBottom + CGFloat(index) * pitch,
                width: inTableView.width,
                height: pitch
            )
            bands.append(RowBand(row: rowCount + index, rect: view.convert(band, from: tableView), isTableRow: false))
            index += 1
        }
        return bands
    }

    /// The theme's background, falling back to the system's, for the table to paint itself with.
    ///
    /// Set on the table rather than read from the theme at each draw, because AppKit reads the
    /// table's own `backgroundColor` too, for the area an elastic scroll uncovers.
    static func applyBackground(to tableView: NSTableView) {
        let background = ThemeEngine.shared.palette[.gridBackground]
        guard tableView.backgroundColor != background else { return }
        tableView.backgroundColor = background
    }

    /// The alternate stripe a row carries, or nil when the table does not alternate, where a row
    /// shows the table's own background.
    ///
    /// The theme's pair when it declares one, otherwise `NSColor.alternatingContentBackgroundColors`,
    /// which is the pair `NSTableView` itself hands its row views.
    static func stripeColor(forRow row: Int, of tableView: NSTableView) -> NSColor? {
        guard tableView.usesAlternatingRowBackgroundColors else { return nil }
        return row.isMultiple(of: 2)
            ? ThemeEngine.shared.palette[.gridBackground]
            : ThemeEngine.shared.palette[.gridAlternateRow]
    }

    /// What a row view lays down before its tint and selection: its stripe, or the table's own
    /// background when the table does not alternate.
    ///
    /// Painted by `DataGridRowView` itself rather than by `NSTableRowView`, which paints the system
    /// stripes whatever the theme declares.
    static func rowBackgroundColor(forRow row: Int, of tableView: NSTableView) -> NSColor {
        stripeColor(forRow: row, of: tableView) ?? tableView.backgroundColor
    }

    /// Lays `background` down and blends `layers` over it bottom to top, which is the colour a row
    /// view's fills end up showing over the table beneath them. Opaque whatever the layers are,
    /// because the background replaces the pixels rather than blending over them.
    static func fill(_ rect: NSRect, with layers: [NSColor], over background: NSColor) {
        background.setFill()
        rect.fill()
        for layer in layers {
            layer.setFill()
            rect.fill(using: .sourceOver)
        }
    }

    /// The table's background: its own colour, and past the last row the alternate stripes blended
    /// over it once.
    ///
    /// Drawn here rather than by `NSTableView.drawBackground(inClipRect:)`, which blends the stripe in
    /// twice past the last row. Measured on macOS 27 in dark mode, its empty rows read 52 against the
    /// rows' 40, so the empty area striped brighter than the rows above it, and nothing that paints
    /// the stripe once could match it, the pinned row gutter included. Under the rows only the
    /// table's colour goes down, because a row view blends its own stripe over exactly that.
    static func drawTableBackground(in rect: NSRect, of tableView: NSTableView) {
        tableView.backgroundColor.setFill()
        rect.fill()
        for band in rowBands(in: rect, of: tableView, tableView: tableView) where !band.isTableRow {
            guard let stripe = stripeColor(forRow: band.row, of: tableView) else { continue }
            stripe.setFill()
            band.rect.intersection(rect).fill(using: .sourceOver)
        }
    }
}
