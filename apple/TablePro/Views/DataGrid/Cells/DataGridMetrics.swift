//
//  DataGridMetrics.swift
//  TablePro
//

import AppKit

enum DataGridMetrics {
    static let cellHorizontalInset: CGFloat = 4
    static let rowNumberHeaderPadding: CGFloat = 8
    static let rowNumberColumnMinWidth: CGFloat = 40
    static let dataColumnMinWidth: CGFloat = 30
    static let dataColumnMaxWidth: CGFloat = 1_200
    // Keeps the last column's divider off the viewport edge a resizable window claims for its own resize.
    static let trailingSpace: CGFloat = 40
    static let frozenDividerThickness: CGFloat = 2
    // Frozen columns that would leave the rest less than a third of the grid scroll instead.
    static let maximumFrozenShare: CGFloat = 2.0 / 3.0

    // The Row height setting is a floor: a grid font taller than the row would be cut at the cell edge.
    static func rowHeight(_ setting: DataGridRowHeight, font: NSFont) -> CGFloat {
        max(CGFloat(setting.rawValue), (font.ascender - font.descender + font.leading).rounded(.up))
    }

    static func lineHeight(of font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    // The padding of a one-line row stays around the lines, so one line is exactly the row height.
    static func wrappedRowHeight(lines: Int, rowHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        rowHeight + CGFloat(max(lines, 1) - 1) * lineHeight
    }

    // An overlay scroller floats over the last row, so only a legacy one adds height.
    static func fittingHeight(
        headerHeight: CGFloat,
        rowCount: Int,
        rowPitch: CGFloat,
        horizontalScrollerHeight: CGFloat
    ) -> CGFloat {
        headerHeight + CGFloat(max(rowCount, 0)) * rowPitch + horizontalScrollerHeight
    }
}

// What a wrapping grid lays a tall row out by: the one-line row height, and the pitch of the lines after the first.
struct DataGridWrapMetrics: Equatable {
    let rowHeight: CGFloat
    let lineHeight: CGFloat

    // Where a one-line row would put what it draws: the row number, the accessory, the checkbox and the edit field stay there.
    func firstLine(of rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rowHeight, rect.height))
    }
}
