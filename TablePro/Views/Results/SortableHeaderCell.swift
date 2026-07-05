//
//  SortableHeaderCell.swift
//  TablePro
//

import AppKit

@MainActor
final class SortableHeaderCell: NSTableHeaderCell {
    var sortDirection: SortDirection?
    var sortPriority: Int?
    var isColumnSelected: Bool = false
    var isValueFiltered: Bool = false
    var isFunnelVisible: Bool = false
    var supportsValueFilter: Bool = true

    private static let indicatorPadding: CGFloat = 4
    private static let indicatorSpacing: CGFloat = 2
    private static let priorityFontSize: CGFloat = 9
    private static let defaultIndicatorSize = NSSize(width: 9, height: 6)
    private static let funnelSize = NSSize(width: 13, height: 13)
    private static let funnelPointSize: CGFloat = 11

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
        if isColumnSelected {
            NSColor.selectedContentBackgroundColor.setFill()
            cellFrame.fill()
        }

        let foreground = foregroundColor(emphasized: isColumnSelected)
        drawTitle(
            in: titleRect(forBounds: cellFrame),
            font: titleFont(isSorted: sortDirection != nil),
            color: foreground
        )

        var trailingCursorX = cellFrame.maxX - Self.indicatorPadding

        if supportsValueFilter {
            if isValueFiltered || isFunnelVisible {
                let funnelImage = Self.funnelImage(
                    active: isValueFiltered,
                    color: funnelColor(active: isValueFiltered, emphasized: isColumnSelected)
                )
                let drawSize = funnelImage?.size ?? Self.funnelSize
                let funnelRect = NSRect(
                    x: trailingCursorX - drawSize.width,
                    y: cellFrame.midY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
                Self.drawIndicator(image: funnelImage, in: funnelRect)
            }
            trailingCursorX -= Self.funnelSize.width + Self.indicatorSpacing
        }

        guard let direction = sortDirection else { return }

        let indicatorImage = Self.indicatorImage(for: direction, color: foreground)
        let indicatorSize = indicatorImage?.size ?? Self.defaultIndicatorSize
        let indicatorOriginX = trailingCursorX - indicatorSize.width
        let indicatorOriginY = cellFrame.midY - indicatorSize.height / 2
        let indicatorRect = NSRect(
            x: indicatorOriginX,
            y: indicatorOriginY,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        Self.drawIndicator(image: indicatorImage, in: indicatorRect)

        if let priorityText = priorityNumberString() {
            let priorityWidth = Self.measureWidth(of: priorityText, color: foreground)
            let textOriginX = indicatorOriginX - Self.indicatorSpacing - priorityWidth
            let textRect = NSRect(
                x: textOriginX,
                y: cellFrame.minY,
                width: priorityWidth,
                height: cellFrame.height
            )
            Self.drawPriorityText(priorityText, in: textRect, color: foreground)
        }
    }

    func funnelRect(forBounds rect: NSRect) -> NSRect {
        guard supportsValueFilter else { return .null }
        let size = Self.funnelSize
        return NSRect(
            x: rect.maxX - Self.indicatorPadding - size.width,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
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
        var width: CGFloat = 0
        if supportsValueFilter {
            width += Self.funnelSize.width + Self.indicatorSpacing
        }
        if let direction = sortDirection {
            width += Self.indicatorImage(for: direction, color: .secondaryLabelColor)?.size.width
                ?? Self.defaultIndicatorSize.width
            if let priorityText = priorityNumberString() {
                width += Self.measureWidth(of: priorityText, color: .secondaryLabelColor) + Self.indicatorSpacing
            }
        }
        guard width > 0 else { return 0 }
        return width + Self.indicatorPadding * 2
    }

    private func funnelColor(active: Bool, emphasized: Bool) -> NSColor {
        if emphasized { return .alternateSelectedControlTextColor }
        return active ? .controlAccentColor : .secondaryLabelColor
    }

    private static func funnelImage(active: Bool, color: NSColor) -> NSImage? {
        let symbolName = active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        let configuration = NSImage.SymbolConfiguration(pointSize: funnelPointSize, weight: .regular)
            .applying(.init(hierarchicalColor: color))
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private func titleFont(isSorted: Bool) -> NSFont {
        let baseFont = font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        guard isSorted else { return baseFont }
        return NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
    }

    private func foregroundColor(emphasized: Bool) -> NSColor {
        emphasized ? .alternateSelectedControlTextColor : .headerTextColor
    }

    private func drawTitle(in rect: NSRect, font titleFont: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: color,
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
        var components = [super.accessibilityLabel() ?? stringValue]
        if let direction = sortDirection {
            switch direction {
            case .ascending:
                components.append(String(localized: "Sorted ascending"))
            case .descending:
                components.append(String(localized: "Sorted descending"))
            }
            if let sortPriority, sortPriority >= 2 {
                components.append(String(format: String(localized: "Priority %d"), sortPriority))
            }
        }
        if isValueFiltered {
            components.append(String(localized: "Filtered"))
        }
        return components.joined(separator: ", ")
    }

    private func priorityNumberString() -> String? {
        guard let sortPriority, sortPriority >= 2 else { return nil }
        return String(sortPriority)
    }

    private static func indicatorImage(for direction: SortDirection, color: NSColor) -> NSImage? {
        let symbolName = direction == .ascending ? "chevron.up" : "chevron.down"
        let configuration = NSImage.SymbolConfiguration(pointSize: priorityFontSize, weight: .semibold)
            .applying(.init(hierarchicalColor: color))
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

    private static func drawPriorityText(_ text: String, in rect: NSRect, color: NSColor) {
        let attributes = priorityAttributes(color: color)
        let textSize = (text as NSString).size(withAttributes: attributes)
        let drawRect = NSRect(
            x: rect.minX,
            y: rect.midY - textSize.height / 2,
            width: rect.width,
            height: textSize.height
        )
        (text as NSString).draw(in: drawRect, withAttributes: attributes)
    }

    private static func measureWidth(of text: String, color: NSColor) -> CGFloat {
        (text as NSString).size(withAttributes: priorityAttributes(color: color)).width
    }

    private static func priorityAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: priorityFontSize, weight: .medium),
            .foregroundColor: color
        ]
    }
}
