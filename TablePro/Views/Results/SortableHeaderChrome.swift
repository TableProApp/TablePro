//
//  SortableHeaderChrome.swift
//  TablePro
//

import AppKit
import TableProTheme

@MainActor
enum SortableHeaderChrome {
    static let separatorThickness: CGFloat = 1
    static let columnDividerHeight: CGFloat = 16

    /// The cells never draw a background of their own, so the header lays one down under
    /// `NSTableHeaderView.draw`; without a theme override it is the table's own background.
    static func backgroundColor(scope: ThemeScope) -> NSColor {
        scope.resolved[.gridHeaderBackground]
    }

    static func lineColor(scope: ThemeScope) -> NSColor {
        scope.resolved[.gridLine]
    }

    static func fillBackground(_ rect: NSRect, scope: ThemeScope) {
        backgroundColor(scope: scope).setFill()
        rect.fill()
    }

    static func drawBottomSeparator(in bounds: NSRect, scope: ThemeScope) {
        lineColor(scope: scope).setFill()
        NSRect(
            x: bounds.minX,
            y: bounds.maxY - separatorThickness,
            width: bounds.width,
            height: separatorThickness
        ).fill()
    }

    static func drawColumnDivider(in cellFrame: NSRect, scope: ThemeScope) {
        let dividerHeight = min(columnDividerHeight, cellFrame.height)
        lineColor(scope: scope).setFill()
        NSRect(
            x: cellFrame.maxX - separatorThickness,
            y: cellFrame.midY - dividerHeight / 2,
            width: separatorThickness,
            height: dividerHeight
        ).fill()
    }
}
