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
    static func draw(
        _ text: String,
        font: NSFont,
        color: NSColor,
        at point: CGPoint,
        anchor: ERDiagramTextAnchor,
        in context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let line = self.line(for: text, font: font, color: color)
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

/// Rasterising a symbol resolves its dynamic colour, so a cached bitmap belongs to exactly one
/// appearance, the same rule `DataGridCellAccessoryGlyph` follows.
@MainActor
enum ERDiagramSymbolRenderer {
    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat
        let color: NSColor
        let appearance: NSAppearance.Name
    }

    private struct Glyph {
        let image: CGImage
        let size: CGSize
    }

    private static var glyphs: [Key: Glyph] = [:]

    static func draw(
        named name: String,
        pointSize: CGFloat,
        color: NSColor,
        at point: CGPoint,
        anchor: ERDiagramTextAnchor,
        in context: CGContext
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

        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(glyph.image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func glyph(named name: String, pointSize: CGFloat, color: NSColor) -> Glyph? {
        let key = Key(name: name, pointSize: pointSize, color: color, appearance: NSAppearance.currentDrawing().name)
        if let cached = glyphs[key] { return cached }

        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(hierarchicalColor: color))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }

        let glyph = Glyph(image: cgImage, size: image.size)
        glyphs[key] = glyph
        return glyph
    }
}
