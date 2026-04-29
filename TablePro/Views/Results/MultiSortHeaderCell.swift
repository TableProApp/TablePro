//
//  MultiSortHeaderCell.swift
//  TablePro
//

import AppKit

@MainActor
final class MultiSortHeaderCell: NSTableHeaderCell {
    var sortIndicatorImage: NSImage?
    var sortPriority: Int = 0

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let imageGap: CGFloat = 4
        let imageSize: CGFloat = 11

        var titleFrame = cellFrame
        if sortIndicatorImage != nil {
            titleFrame.size.width -= imageSize + imageGap * 2
        }
        super.drawInterior(withFrame: titleFrame, in: controlView)

        guard let image = sortIndicatorImage else { return }

        let imageRect = NSRect(
            x: cellFrame.maxX - imageSize - imageGap,
            y: cellFrame.midY - imageSize / 2,
            width: imageSize,
            height: imageSize
        )
        image.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
    }
}
