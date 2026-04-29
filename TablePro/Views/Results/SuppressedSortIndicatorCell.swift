//
//  SuppressedSortIndicatorCell.swift
//  TablePro
//

import AppKit

@MainActor
final class SuppressedSortIndicatorCell: NSTableHeaderCell {
    override init(textCell string: String) {
        super.init(textCell: string)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawSortIndicator(
        withFrame cellFrame: NSRect,
        in controlView: NSView,
        ascending: Bool,
        priority: Int
    ) {}
}
