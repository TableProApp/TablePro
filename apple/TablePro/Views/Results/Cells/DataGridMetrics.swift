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
    /// Room the grid scrolls past its last column. Without it the last column's divider sits on the
    /// viewport's last point, which a resizable window claims for its own edge resize.
    static let trailingSpace: CGFloat = 40

    // The Row height setting is a floor: a grid font taller than the row would be cut at the cell edge.
    static func rowHeight(_ setting: DataGridRowHeight, font: NSFont) -> CGFloat {
        max(CGFloat(setting.rawValue), (font.ascender - font.descender + font.leading).rounded(.up))
    }
}
