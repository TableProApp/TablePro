//
//  SortableHeaderChrome.swift
//  TablePro
//

import AppKit

@MainActor
enum SortableHeaderChrome {
    static let separatorThickness: CGFloat = 1
    static let columnDividerHeight: CGFloat = 16

    /// The cells never draw a background of their own, so the header lays one down under
    /// `NSTableHeaderView.draw`; without a theme override it is the table's own background.
    static var backgroundColor: NSColor {
        ThemeEngine.shared.resolved[.gridHeaderBackground]
    }

    static var lineColor: NSColor {
        ThemeEngine.shared.resolved[.gridLine]
    }

    static func fillBackground(_ rect: NSRect) {
        backgroundColor.setFill()
        rect.fill()
    }

    static func drawBottomSeparator(in bounds: NSRect) {
        lineColor.setFill()
        NSRect(
            x: bounds.minX,
            y: bounds.maxY - separatorThickness,
            width: bounds.width,
            height: separatorThickness
        ).fill()
    }

    static func drawColumnDivider(in cellFrame: NSRect) {
        let dividerHeight = min(columnDividerHeight, cellFrame.height)
        lineColor.setFill()
        NSRect(
            x: cellFrame.maxX - separatorThickness,
            y: cellFrame.midY - dividerHeight / 2,
            width: separatorThickness,
            height: dividerHeight
        ).fill()
    }
}
