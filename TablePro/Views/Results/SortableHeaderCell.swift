//
//  SortableHeaderCell.swift
//  TablePro
//

import AppKit

@MainActor
final class SortableHeaderCell: NSTableHeaderCell {
    var sortDirection: SortDirection?
    var sortPriority: Int?

    private static let indicatorPadding: CGFloat = 4
    private static let indicatorSpacing: CGFloat = 2
    private static let priorityFontSize: CGFloat = 9

    override init(textCell string: String) {
        super.init(textCell: string)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let direction = sortDirection else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }

        let indicatorImage = Self.indicatorImage(for: direction)
        let indicatorSize = indicatorImage?.size ?? NSSize(width: 9, height: 6)
        let priorityText = priorityNumberString()
        let priorityWidth = priorityText.map { Self.measureWidth(of: $0) } ?? 0
        let reservedWidth = indicatorSize.width
            + Self.indicatorPadding * 2
            + (priorityText == nil ? 0 : priorityWidth + Self.indicatorSpacing)

        let titleFrame = NSRect(
            x: cellFrame.minX,
            y: cellFrame.minY,
            width: max(0, cellFrame.width - reservedWidth),
            height: cellFrame.height
        )
        super.drawInterior(withFrame: titleFrame, in: controlView)

        let indicatorOriginX = cellFrame.maxX - Self.indicatorPadding - indicatorSize.width
        let indicatorOriginY = cellFrame.midY - indicatorSize.height / 2
        let indicatorRect = NSRect(
            x: indicatorOriginX,
            y: indicatorOriginY,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        Self.drawTintedIndicator(image: indicatorImage, in: indicatorRect)

        if let priorityText {
            let textOriginX = indicatorOriginX - Self.indicatorSpacing - priorityWidth
            let textRect = NSRect(
                x: textOriginX,
                y: cellFrame.minY,
                width: priorityWidth,
                height: cellFrame.height
            )
            Self.drawPriorityText(priorityText, in: textRect)
        }
    }

    override func drawSortIndicator(
        withFrame cellFrame: NSRect,
        in controlView: NSView,
        ascending: Bool,
        priority: Int
    ) {}

    private func priorityNumberString() -> String? {
        guard let sortPriority, sortPriority >= 2 else { return nil }
        return String(sortPriority)
    }

    private static func indicatorImage(for direction: SortDirection) -> NSImage? {
        switch direction {
        case .ascending:
            return NSImage(named: NSImage.Name("NSAscendingSortIndicator"))
        case .descending:
            return NSImage(named: NSImage.Name("NSDescendingSortIndicator"))
        }
    }

    private static func drawTintedIndicator(image: NSImage?, in rect: NSRect) {
        guard let image else { return }
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
    }

    private static func drawPriorityText(_ text: String, in rect: NSRect) {
        let attributes = priorityAttributes()
        let textSize = (text as NSString).size(withAttributes: attributes)
        let drawRect = NSRect(
            x: rect.minX,
            y: rect.midY - textSize.height / 2,
            width: rect.width,
            height: textSize.height
        )
        (text as NSString).draw(in: drawRect, withAttributes: attributes)
    }

    private static func measureWidth(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: priorityAttributes()).width
    }

    private static func priorityAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: priorityFontSize, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    }
}
