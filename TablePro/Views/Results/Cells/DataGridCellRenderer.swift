//
//  DataGridCellRenderer.swift
//  TablePro
//

import AppKit
import CoreText

/// Draws one data cell into a rect.
///
/// The grid draws its cells rather than mounting a view for each, so the drawing has to live apart
/// from any view. Everything here is a function of the appearance it is handed; the only state is a
/// bounded cache of laid-out lines, because building a `CTLine` is the expensive part of a cell and
/// scrolling redraws the same values over and over.
@MainActor
final class DataGridCellRenderer {
    /// A laid-out line depends on nothing but the text and the two attributes it carries, so this is
    /// the whole identity of a cached line.
    private struct LineKey: Hashable {
        let text: String
        let font: NSFont
        let color: NSColor
    }

    /// A viewport holds a few hundred cells and a scroll reuses them, so this only has to outlive a
    /// few screens. Cleared wholesale rather than evicted one at a time: the cost of a miss is one
    /// `CTLine`, and tracking recency would cost more than it saves.
    private static let lineCacheLimit = 4_096
    /// Past this many characters a cell can only ever show an ellipsis, and laying out the rest is
    /// wasted on a value the reader opens the inspector to read anyway.
    private static let maximumLaidOutCharacters = 300

    private var lineCache: [LineKey: CTLine] = [:]

    func invalidateCachedLines() {
        lineCache.removeAll(keepingCapacity: true)
    }

    func draw(_ appearance: DataGridCellAppearance, in rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }

        if let tint = appearance.backgroundTint {
            tint.setFill()
            rect.fill()
        }

        let accessoryRect = appearance.accessory.frame(in: rect)

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        drawText(appearance, in: rect)
        drawAccessory(appearance.accessoryRole, in: accessoryRect)
        NSGraphicsContext.current?.restoreGraphicsState()

        if appearance.drawsFocusBorder {
            drawFocusBorder(in: rect)
        } else if appearance.drawsFocusRing {
            drawFocusRing(in: rect)
        }
    }

    private func drawText(_ appearance: DataGridCellAppearance, in rect: NSRect) {
        guard !appearance.text.isEmpty else { return }
        let availableWidth = appearance.accessory.availableTextWidth(in: rect)
        guard availableWidth > 0, let context = NSGraphicsContext.current?.cgContext else { return }

        let fullLine = line(for: appearance.text, font: appearance.font, color: appearance.textColor)
        let typographicWidth = CTLineGetTypographicBounds(fullLine, nil, nil, nil)
        let ellipsis = line(for: "\u{2026}", font: appearance.font, color: appearance.textColor)
        let ellipsisWidth = CTLineGetTypographicBounds(ellipsis, nil, nil, nil)
        guard Double(availableWidth) >= ellipsisWidth else { return }

        let lineToDraw = typographicWidth > Double(availableWidth)
            ? (CTLineCreateTruncatedLine(fullLine, Double(availableWidth), .end, ellipsis) ?? ellipsis)
            : fullLine

        let font = appearance.font
        let baselineOffset = (rect.height - font.ascender + font.descender - font.leading) / 2 + font.ascender

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: rect.minX + DataGridMetrics.cellHorizontalInset,
            y: rect.minY + baselineOffset
        )
        CTLineDraw(lineToDraw, context)
        context.restoreGState()
    }

    private func line(for text: String, font: NSFont, color: NSColor) -> CTLine {
        let key = LineKey(text: text, font: font, color: color)
        if let cached = lineCache[key] { return cached }

        let source = text as NSString
        let laidOut = source.length > Self.maximumLaidOutCharacters
            ? source.substring(to: Self.maximumLaidOutCharacters) + "\u{2026}"
            : text
        let attributed = NSAttributedString(
            string: laidOut,
            attributes: [.font: font, .foregroundColor: color]
        )
        let created = CTLineCreateWithAttributedString(attributed as CFAttributedString)

        if lineCache.count >= Self.lineCacheLimit {
            lineCache.removeAll(keepingCapacity: true)
        }
        lineCache[key] = created
        return created
    }

    private func drawAccessory(_ role: DataGridCellAccessoryGlyph.Role?, in rect: NSRect) {
        guard !rect.isEmpty, let role else { return }
        guard let glyph = DataGridCellAccessoryGlyph.image(for: role),
              let context = NSGraphicsContext.current?.cgContext else { return }

        let drawRect = DataGridCellAccessoryGlyph.centeredRect(pointSize: glyph.pointSize, in: rect)
        context.saveGState()
        context.translateBy(x: drawRect.minX, y: drawRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(glyph.image, in: CGRect(origin: .zero, size: drawRect.size))
        context.restoreGState()
    }

    private func drawFocusBorder(in rect: NSRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.alternateSelectedControlTextColor.setStroke()
        path.stroke()
    }

    /// The cell cursor on an unselected row. A mounted cell got this from AppKit's exterior focus
    /// ring; a drawn cell has no view to hang one on, so it is drawn to the same shape.
    private func drawFocusRing(in rect: NSRect) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.stroke()
    }
}
