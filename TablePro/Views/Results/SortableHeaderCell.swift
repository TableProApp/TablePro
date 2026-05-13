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
    private static let defaultIndicatorSize = NSSize(width: 9, height: 6)

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
        drawTitle(in: titleRect(forBounds: cellFrame), font: titleFont(isSorted: sortDirection != nil))

        guard let direction = sortDirection else { return }

        let indicatorImage = Self.indicatorImage(for: direction)
        let indicatorSize = indicatorImage?.size ?? Self.defaultIndicatorSize
        let indicatorOriginX = cellFrame.maxX - Self.indicatorPadding - indicatorSize.width
        let indicatorOriginY = cellFrame.midY - indicatorSize.height / 2
        let indicatorRect = NSRect(
            x: indicatorOriginX,
            y: indicatorOriginY,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        Self.drawIndicator(image: indicatorImage, in: indicatorRect)

        if let priorityText = priorityNumberString() {
            let priorityWidth = Self.measureWidth(of: priorityText)
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

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let inset = min(DataGridMetrics.cellHorizontalInset, rect.width / 2)
        let availableWidth = max(0, rect.width - inset * 2 - reservedTrailingWidth())
        return NSRect(
            x: rect.minX + inset,
            y: rect.minY,
            width: availableWidth,
            height: rect.height
        )
    }

    private func reservedTrailingWidth() -> CGFloat {
        guard let direction = sortDirection else { return 0 }
        let indicatorWidth = Self.indicatorImage(for: direction)?.size.width
            ?? Self.defaultIndicatorSize.width
        let priorityText = priorityNumberString()
        let priorityComponent = priorityText.map { Self.measureWidth(of: $0) + Self.indicatorSpacing } ?? 0
        return indicatorWidth + Self.indicatorPadding * 2 + priorityComponent
    }

    private func titleFont(isSorted: Bool) -> NSFont {
        let baseFont = font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        guard isSorted else { return baseFont }
        return NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
    }

    private func drawTitle(in rect: NSRect, font titleFont: NSFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.headerTextColor,
            .paragraphStyle: paragraph
        ]

        let title = NSAttributedString(string: stringValue, attributes: attributes)
        let textHeight = title.size().height
        let drawRect = NSRect(
            x: rect.minX,
            y: rect.midY - textHeight / 2,
            width: rect.width,
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
