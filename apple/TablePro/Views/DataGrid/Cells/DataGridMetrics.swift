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
