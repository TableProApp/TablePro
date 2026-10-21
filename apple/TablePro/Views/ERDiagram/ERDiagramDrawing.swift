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
    private static let ellipsis = "\u{2026}"

    // The point is the text's visual centre, not its baseline.
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
        context.textPosition = CGPoint(x: originX, y: baseline(for: point.y, font: font))
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func baseline(for centerY: CGFloat, font: NSFont) -> CGFloat {
        centerY + (font.ascender + font.descender) / 2
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return CGFloat(CTLineGetTypographicBounds(line(for: text, font: font, color: .labelColor), nil, nil, nil))
    }

    // What `draw` shows: the longest prefix that fits beside an ellipsis, as an end-truncated `CTLine` keeps.
    static func fittedText(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
        guard !text.isEmpty, maxWidth > 0 else { return "" }
        guard measure(text, font: font) > maxWidth else { return text }

        let characters = Array(text)
        var low = 0
        var high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(String(characters[..<mid]) + ellipsis, font: font) <= maxWidth {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return String(characters[..<low]) + ellipsis
    }

    // Uncached, so a search over prefixes does not flush the drawing cache.
    private static func measure(_ text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func fitted(_ line: CTLine, to maxWidth: CGFloat, font: NSFont, color: NSColor) -> CTLine {
        guard CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth else { return line }
        let ellipsis = self.line(for: ellipsis, font: font, color: color)
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

// A configured symbol bakes its colour, so the cache is keyed by appearance and contrast.
@MainActor
enum ERDiagramSymbolRenderer {
    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat
        let color: NSColor
        let appearance: NSAppearance.Name
        let increasedContrast: Bool
    }

    struct Glyph {
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
        // Every diagram context is flipped, and without `respectFlipped` a symbol draws upside down.
        glyph.image.draw(
            in: frame(of: glyph, at: point, anchor: anchor),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    static func frame(of glyph: Glyph, at point: CGPoint, anchor: ERDiagramTextAnchor) -> CGRect {
        let originX: CGFloat
        switch anchor {
        case .leading: originX = point.x
        case .trailing: originX = point.x - glyph.size.width
        case .center: originX = point.x - glyph.size.width / 2
        }
        return CGRect(
            x: originX,
            y: point.y - glyph.size.height / 2,
            width: glyph.size.width,
            height: glyph.size.height
        )
    }

    static func glyph(named name: String, pointSize: CGFloat, color: NSColor) -> Glyph? {
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
