//
//  DataGridPinnedBand.swift
//  TablePro
//

import AppKit

// Row-number gutter plus frozen columns, in table coordinates as they stand at scroll offset zero.
struct DataGridPinnedBand: Equatable {
    // Frozen columns that would leave the rest less than a third of the viewport scroll instead.
    static let maximumViewportShare: CGFloat = 2.0 / 3.0

    static let none = DataGridPinnedBand(gutterWidth: 0, width: 0, frozenColumns: [], offset: 0)

    let gutterWidth: CGFloat
    let width: CGFloat
    let frozenColumns: IndexSet
    let offset: CGFloat

    var isFreezing: Bool { !frozenColumns.isEmpty }

    static func resolve(
        gutterWidth: CGFloat,
        frozenColumns: IndexSet,
        frozenTrailingEdge: CGFloat,
        viewportWidth: CGFloat,
        offset: CGFloat
    ) -> DataGridPinnedBand {
        guard !frozenColumns.isEmpty,
              frozenTrailingEdge > gutterWidth,
              fits(width: frozenTrailingEdge, viewportWidth: viewportWidth) else {
            return DataGridPinnedBand(gutterWidth: gutterWidth, width: gutterWidth, frozenColumns: [], offset: offset)
        }
        return DataGridPinnedBand(
            gutterWidth: gutterWidth,
            width: frozenTrailingEdge,
            frozenColumns: frozenColumns,
            offset: offset
        )
    }

    static func fits(width: CGFloat, viewportWidth: CGFloat) -> Bool {
        viewportWidth > 0 && width <= viewportWidth * maximumViewportShare
    }

    func pins(_ tableColumnIndex: Int) -> Bool {
        frozenColumns.contains(tableColumnIndex)
    }

    func displayed(_ rect: NSRect, ofColumn tableColumnIndex: Int) -> NSRect {
        pins(tableColumnIndex) ? rect.offsetBy(dx: offset, dy: 0) : rect
    }

    func unscrolledPoint(_ point: NSPoint) -> NSPoint? {
        guard isFreezing else { return nil }
        let x = point.x - offset
        guard x >= 0, x < width else { return nil }
        return NSPoint(x: x, y: point.y)
    }

    // The offset moves on every scroll and changes nothing the band draws.
    func hasSameLayout(as other: DataGridPinnedBand) -> Bool {
        gutterWidth == other.gutterWidth && width == other.width && frozenColumns == other.frozenColumns
    }
}
