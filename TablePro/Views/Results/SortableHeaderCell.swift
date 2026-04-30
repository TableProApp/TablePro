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
    private static let titleHorizontalPadding: CGFloat = 4

    override init(textCell string: String) {
        super.init(textCell: string)
        lineBreakMode = .byTruncatingTail
        truncatesLastVisibleLine = true
        wraps = false
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        lineBreakMode = .byTruncatingTail
        truncatesLastVisibleLine = true
        wraps = false
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
        drawSortedTitle(in: titleFrame)

        let indicatorOriginX = cellFrame.maxX - Self.indicatorPadding - indicatorSize.width
        let indicatorOriginY = cellFrame.midY - indicatorSize.height / 2
        let indicatorRect = NSRect(
            x: indicatorOriginX,
            y: indicatorOriginY,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        Self.drawIndicator(image: indicatorImage, in: indicatorRect)

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

    private func drawSortedTitle(in rect: NSRect) {
        let baseFont = font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: boldFont,
            .foregroundColor: NSColor.headerTextColor,
            .paragraphStyle: paragraph
        ]

        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let textHeight = title.size().height
        let drawRect = NSRect(
            x: rect.minX + Self.titleHorizontalPadding,
            y: rect.midY - textHeight / 2,
            width: max(0, rect.width - Self.titleHorizontalPadding),
            height: textHeight
        )
        title.draw(in: drawRect)
    }

    override func drawSortIndicator(
        withFrame cellFrame: NSRect,
        in controlView: NSView,
        ascending: Bool,
        priority: Int
    ) {}

    override func accessibilityLabel() -> String? {
        let baseLabel = super.accessibilityLabel() ?? stringValue
        guard let direction = sortDirection else { return baseLabel }
        let directionSuffix: String
        switch direction {
        case .ascending:
            directionSuffix = String(localized: "Sorted ascending")
        case .descending:
            directionSuffix = String(localized: "Sorted descending")
        }
        guard let sortPriority, sortPriority >= 2 else {
            return "\(baseLabel), \(directionSuffix)"
        }
        let prioritySuffix = String(format: String(localized: "Priority %d"), sortPriority)
        return "\(baseLabel), \(directionSuffix), \(prioritySuffix)"
    }

    private func priorityNumberString() -> String? {
        guard let sortPriority, sortPriority >= 2 else { return nil }
        return String(sortPriority)
    }

    private static func indicatorImage(for direction: SortDirection) -> NSImage? {
        let symbolName = direction == .ascending ? "chevron.up" : "chevron.down"
        let configuration = NSImage.SymbolConfiguration(pointSize: priorityFontSize, weight: .semibold)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private static func drawIndicator(image: NSImage?, in rect: NSRect) {
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
