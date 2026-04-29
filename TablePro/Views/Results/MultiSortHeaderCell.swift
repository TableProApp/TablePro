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

        var titleFrame = cellFrame
        if let image = sortIndicatorImage {
            titleFrame.size.width -= image.size.width + imageGap * 2
        }
        super.drawInterior(withFrame: titleFrame, in: controlView)

        guard let image = sortIndicatorImage else { return }
        let imageRect = NSRect(
            x: cellFrame.maxX - image.size.width - imageGap,
            y: cellFrame.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )

        let drawable: NSImage
        if image.isTemplate {
            drawable = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                NSColor.labelColor.withAlphaComponent(0.4).set()
                rect.fill(using: .sourceAtop)
                return true
            }
        } else {
            drawable = image
        }
        drawable.draw(in: imageRect)
    }

    override func drawSortIndicator(
        withFrame cellFrame: NSRect,
        in controlView: NSView,
        ascending: Bool,
        priority: Int
    ) {}
}
