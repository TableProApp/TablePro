//
//  ERDiagramDrawing.swift
//  TablePro
//
//  Text and symbol drawing for the ER diagram's CoreGraphics renderers, matching what the
//  SwiftUI `GraphicsContext.draw(_:at:anchor:)` calls they replaced put on screen.
//

import AppKit

enum ERDiagramTextAnchor {
    case leading
    case trailing
    case center
}

@MainActor
enum ERDiagramTextRenderer {
    private struct LineKey: Hashable {
        let text: String
        let font: NSFont
        let color: NSColor
    }

    private static let lineCacheLimit = 4_000
    private static var lineCache: [LineKey: CTLine] = [:]

    /// The anchor point is the text's visual centre on the vertical axis, which is where
    /// `GraphicsContext.draw(_:at:anchor:)` put it. The context is flipped, so the baseline sits
    /// below that centre by half the difference between ascent and descent.
    ///
    /// Text wider than `maxWidth` is cut at its end with an ellipsis, the way a truncating label is,
    /// so two texts given widths that add up to their room can never draw over each other.
    static func draw(
        _ text: String,
        font: NSFont,
        color: NSColor,
        at point: CGPoint,
        anchor: ERDiagramTextAnchor,
        maxWidth: CGFloat = .greatestFiniteMagnitude,
        in context: CGContext
    ) {
        guard !text.isEmpty, maxWidth > 0 else { return }
        let line = fitted(self.line(for: text, font: font, color: color), to: maxWidth, font: font, color: color)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        let originX: CGFloat
        switch anchor {
        case .leading: originX = point.x
        case .trailing: originX = point.x - width
        case .center: originX = point.x - width / 2
        }

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: originX, y: point.y + (font.ascender + font.descender) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The width `draw` lays `text` out at before any truncation.
    static func width(of text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return CGFloat(CTLineGetTypographicBounds(line(for: text, font: font, color: .labelColor), nil, nil, nil))
    }

    private static func fitted(_ line: CTLine, to maxWidth: CGFloat, font: NSFont, color: NSColor) -> CTLine {
        guard CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth else { return line }
        let ellipsis = self.line(for: "\u{2026}", font: font, color: color)
        return CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? ellipsis
    }

    private static func line(for text: String, font: NSFont, color: NSColor) -> CTLine {
        let key = LineKey(text: text, font: font, color: color)
        if let cached = lineCache[key] { return cached }
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let created = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        if lineCache.count >= lineCacheLimit {
            lineCache.removeAll(keepingCapacity: true)
        }
        lineCache[key] = created
        return created
    }
}

/// Configuring a symbol resolves its dynamic colour, so a cached image belongs to exactly one
/// appearance and contrast setting, the same rule `DataGridCellAccessoryGlyph` follows.
///
/// What is cached is the configured `NSImage`, not a bitmap of it. A symbol is vector art and the
/// diagram is drawn at whatever scale the scroll view is magnified to, so rasterising once at 1x
/// and stretching that bitmap would leave every badge soft on a Retina display, in the 2x PNG
/// export, and worse again at 300%. `NSImage.draw(in:)` renders into the current context at its
/// resolution instead.
@MainActor
enum ERDiagramSymbolRenderer {
    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat
        let color: NSColor
        let appearance: NSAppearance.Name
        let increasedContrast: Bool
    }

    private struct Glyph {
        let image: NSImage
        let size: CGSize
    }

    private static var glyphs: [Key: Glyph] = [:]

    static func draw(
        named name: String,
        pointSize: CGFloat,
        color: NSColor,
        at point: CGPoint,
        anchor: ERDiagramTextAnchor
    ) {
        guard let glyph = glyph(named: name, pointSize: pointSize, color: color) else { return }

        let originX: CGFloat
        switch anchor {
        case .leading: originX = point.x
        case .trailing: originX = point.x - glyph.size.width
        case .center: originX = point.x - glyph.size.width / 2
        }
        let rect = CGRect(
            x: originX,
            y: point.y - glyph.size.height / 2,
            width: glyph.size.width,
            height: glyph.size.height
        )

        glyph.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func glyph(named name: String, pointSize: CGFloat, color: NSColor) -> Glyph? {
        let key = Key(
            name: name,
            pointSize: pointSize,
            color: color,
            appearance: NSAppearance.currentDrawing().name,
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        if let cached = glyphs[key] { return cached }

        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(hierarchicalColor: color))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }

        let glyph = Glyph(image: image, size: image.size)
        glyphs[key] = glyph
        return glyph
    }
}
