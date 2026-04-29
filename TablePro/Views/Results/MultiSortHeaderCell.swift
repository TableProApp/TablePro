//
//  MultiSortHeaderCell.swift
//  TablePro
//

import AppKit

@MainActor
final class MultiSortHeaderCell: NSTableHeaderCell {
    var sortAscending: Bool?
    var sortPriority: Int = 0

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame, in: controlView)

        guard let ascending = sortAscending else { return }
        super.drawSortIndicator(
            withFrame: cellFrame,
            in: controlView,
            ascending: ascending,
            priority: sortPriority
        )
    }

    override func drawSortIndicator(
        withFrame cellFrame: NSRect,
        in controlView: NSView,
        ascending: Bool,
        priority: Int
    ) {}
}
