//
//  SortableHeaderChrome.swift
//  TablePro
//

import AppKit

@MainActor
enum SortableHeaderChrome {
    static let separatorThickness: CGFloat = 1
    static let columnDividerHeight: CGFloat = 16

    static func fillBackground(_ rect: NSRect) {
        ThemeEngine.shared.palette[.gridHeaderBackground].setFill()
        rect.fill()
    }

    static func drawBottomSeparator(in bounds: NSRect) {
        ThemeEngine.shared.palette[.gridLine].setFill()
        NSRect(
            x: bounds.minX,
            y: bounds.maxY - separatorThickness,
            width: bounds.width,
            height: separatorThickness
        ).fill()
    }

    static func drawColumnDivider(in cellFrame: NSRect) {
        let dividerHeight = min(columnDividerHeight, cellFrame.height)
        ThemeEngine.shared.palette[.gridLine].setFill()
        NSRect(
            x: cellFrame.maxX - separatorThickness,
            y: cellFrame.midY - dividerHeight / 2,
            width: separatorThickness,
            height: dividerHeight
        ).fill()
    }
}
