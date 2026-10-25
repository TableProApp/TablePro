//
//  DataGridBodyChrome.swift
//  TablePro
//

import AppKit
import TableProTheme

// gridStyleMask stays empty: AppKit's vertical grid lines keep one subview per column and made a 500-column layout pass take 518 ms (#2381).
@MainActor
enum DataGridBodyChrome {
    static let separatorThickness: CGFloat = 1

    // One separator at the leading edge of every column the rect reaches, in the space of `view`.
    static func separatorRects(in rect: NSRect, of view: NSView, tableView: NSTableView) -> [NSRect] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let inTableView = view.convert(rect, to: tableView)
        return tableView.columnIndexes(in: inTableView).compactMap { tableColumnIndex in
            let columnRect = view.convert(tableView.rect(ofColumn: tableColumnIndex), from: tableView)
            guard columnRect.width > 0, columnRect.minX > 0 else { return nil }
            let separator = NSRect(
                x: columnRect.minX - separatorThickness,
                y: rect.minY,
                width: separatorThickness,
                height: rect.height
            )
            return separator.intersects(rect) ? separator : nil
        }
    }

    static func drawColumnSeparators(in rect: NSRect, of view: NSView, tableView: NSTableView) {
        let separators = separatorRects(in: rect, of: view, tableView: tableView)
        guard !separators.isEmpty else { return }
        tableView.gridColor.setFill()
        separators.forEach { $0.fill() }
    }

    struct RowBand: Equatable {
        let row: Int
        let rect: NSRect
        let isTableRow: Bool
    }

    // The table's rows, then bands one row apart past the last row, numbered on as NSTableView continues its alternation.
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

    // AppKit reads the table's own backgroundColor for the area an elastic scroll uncovers.
    static func applyThemeColors(to tableView: NSTableView, scope: ThemeScope) {
        let resolved = scope.resolved
        let gridColor = resolved[.gridLine]
        if tableView.gridColor != gridColor {
            tableView.gridColor = gridColor
        }
        let background = resolved[.gridBackground]
        if tableView.backgroundColor != background {
            tableView.backgroundColor = background
        }
    }

    // The theme's pair when it declares one, otherwise the system's alternating pair the slots fall back to.
    static func stripeColor(forRow row: Int, of tableView: NSTableView, scope: ThemeScope) -> NSColor? {
        guard tableView.usesAlternatingRowBackgroundColors else { return nil }
        let resolved = scope.resolved
        return row.isMultiple(of: 2) ? resolved[.gridBackground] : resolved[.gridAlternateRow]
    }

    // Opaque whatever the stripe is, because a frozen pane row covers the scrolling rows beneath it.
    static func fillRowBackground(_ rect: NSRect, row: Int, of tableView: NSTableView, scope: ThemeScope) {
        tableView.backgroundColor.setFill()
        rect.fill()
        guard let stripe = stripeColor(forRow: row, of: tableView, scope: scope) else { return }
        stripe.setFill()
        rect.fill(using: .sourceOver)
    }

    // NSTableView's own past-the-last-row drawing blends the stripe twice, measured on macOS 27.
    static func drawTableBackground(in rect: NSRect, of tableView: NSTableView, scope: ThemeScope) {
        tableView.backgroundColor.setFill()
        rect.fill()
        for band in rowBands(in: rect, of: tableView, tableView: tableView) where !band.isTableRow {
            guard let stripe = stripeColor(forRow: band.row, of: tableView, scope: scope) else { continue }
            stripe.setFill()
            band.rect.intersection(rect).fill(using: .sourceOver)
        }
    }
}
