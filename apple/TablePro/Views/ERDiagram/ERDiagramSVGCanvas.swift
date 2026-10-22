import AppKit

// A symbol has no public vector outline, so each one is a PNG in `<defs>`.
@MainActor
final class ERDiagramSVGCanvas: ERDiagramCanvas {
    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let color: NSColor
    }

    private static let symbolScale: CGFloat = 4
    private static let monospaceFamily = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Monaco, Consolas, monospace"
    private static let proportionalFamily = "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', Helvetica, Arial, sans-serif"

    private var defs: [String] = []
    private var body: [String] = []
    private var depth = 0
    private var clipIds: [String: String] = [:]
    private var symbolIds: [SymbolKey: String] = [:]

    func fill(_ path: CGPath, color: CGColor) {
        append("<path d=\"\(Self.pathData(path))\"\(Self.paint("fill", color))/>")
    }

    func stroke(_ path: CGPath, color: CGColor, lineWidth: CGFloat, rounded: Bool) {
        var attributes = " fill=\"none\"\(Self.paint("stroke", color)) stroke-width=\"\(Self.number(lineWidth))\""
        if rounded {
            attributes += " stroke-linecap=\"round\" stroke-linejoin=\"round\""
        }
        append("<path d=\"\(Self.pathData(path))\"\(attributes)/>")
    }

    func clip(to path: CGPath, _ draw: () -> Void) {
        let data = Self.pathData(path)
        let id: String
        if let existing = clipIds[data] {
            id = existing
        } else {
            id = "clip\(clipIds.count + 1)"
            clipIds[data] = id
            defs.append("<clipPath id=\"\(id)\"><path d=\"\(data)\"/></clipPath>")
        }
        group("<g clip-path=\"url(#\(id))\">", draw)
    }

    func translated(by offset: CGPoint, _ draw: () -> Void) {
        group("<g transform=\"translate(\(Self.number(offset.x)) \(Self.number(offset.y)))\">", draw)
    }

    func drawText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        at point: CGPoint,
        anchor: ERDiagramTextAnchor,
        maxWidth: CGFloat
    ) {
        let shown = ERDiagramTextRenderer.fittedText(text, font: font, maxWidth: maxWidth)
        guard !shown.isEmpty else { return }

        var attributes = " x=\"\(Self.number(point.x))\""
        attributes += " y=\"\(Self.number(ERDiagramTextRenderer.baseline(for: point.y, font: font)))\""
        if !font.isFixedPitch {
            attributes += " font-family=\"\(Self.proportionalFamily)\""
        }
        attributes += " font-size=\"\(Self.number(font.pointSize))\""
        let weight = Self.cssWeight(of: font)
        if weight != 400 {
            attributes += " font-weight=\"\(weight)\""
        }
        switch anchor {
        case .leading: break
        case .trailing: attributes += " text-anchor=\"end\""
        case .center: attributes += " text-anchor=\"middle\""
        }
        attributes += Self.paint("fill", color.cgColor)
        append("<text\(attributes)>\(Self.escaped(shown))</text>")
    }

    func drawSymbol(named name: String, pointSize: CGFloat, color: NSColor, at point: CGPoint, anchor: ERDiagramTextAnchor) {
        guard let glyph = ERDiagramSymbolRenderer.glyph(named: name, pointSize: pointSize, color: color),
              let id = symbolId(SymbolKey(name: name, pointSize: pointSize, color: color), glyph: glyph)
        else { return }
        let frame = ERDiagramSymbolRenderer.frame(of: glyph, at: point, anchor: anchor)
        append("<use xlink:href=\"#\(id)\" x=\"\(Self.number(frame.minX))\" y=\"\(Self.number(frame.minY))\"/>")
    }

    func document(size: CGSize, title: String) -> String {
        let width = Self.number(size.width)
        let height = Self.number(size.height)
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\""
                + " width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\""
                + " font-family=\"\(Self.monospaceFamily)\" xml:space=\"preserve\">",
            "  <title>\(Self.escaped(title))</title>",
        ]
        if !defs.isEmpty {
            lines.append("  <defs>")
            lines += defs.map { "    " + $0 }
            lines.append("  </defs>")
        }
        lines += body.map { "  " + $0 }
        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Output

    private func append(_ element: String) {
        body.append(String(repeating: "  ", count: depth) + element)
    }

    private func group(_ open: String, _ draw: () -> Void) {
        append(open)
        depth += 1
        draw()
        depth -= 1
        append("</g>")
    }

    private func symbolId(_ key: SymbolKey, glyph: ERDiagramSymbolRenderer.Glyph) -> String? {
        if let existing = symbolIds[key] { return existing }
        guard let image = Self.rasterize(glyph) else { return nil }
        let id = "symbol\(symbolIds.count + 1)"
        symbolIds[key] = id
        defs.append(
            "<image id=\"\(id)\" width=\"\(Self.number(image.size.width))\" height=\"\(Self.number(image.size.height))\""
                + " xlink:href=\"data:image/png;base64,\(image.png.base64EncodedString())\"/>"
        )
        return id
    }

    private static func rasterize(_ glyph: ERDiagramSymbolRenderer.Glyph) -> (png: Data, size: CGSize)? {
        let pixelsWide = max(1, Int((glyph.size.width * symbolScale).rounded(.up)))
        let pixelsHigh = max(1, Int((glyph.size.height * symbolScale).rounded(.up)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelsWide,
                  height: pixelsHigh,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.scaleBy(x: symbolScale, y: symbolScale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        glyph.image.draw(in: CGRect(origin: .zero, size: glyph.size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return nil }
        let size = CGSize(width: CGFloat(pixelsWide) / symbolScale, height: CGFloat(pixelsHigh) / symbolScale)
        return (png, size)
    }

    // MARK: - Encoding

    nonisolated static func pathData(_ path: CGPath) -> String {
        var commands: [String] = []
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                commands.append("M\(number(points[0].x)) \(number(points[0].y))")
            case .addLineToPoint:
                commands.append("L\(number(points[0].x)) \(number(points[0].y))")
            case .addQuadCurveToPoint:
                commands.append(
                    "Q\(number(points[0].x)) \(number(points[0].y)) \(number(points[1].x)) \(number(points[1].y))"
                )
            case .addCurveToPoint:
                commands.append(
                    "C\(number(points[0].x)) \(number(points[0].y)) \(number(points[1].x)) \(number(points[1].y))"
                        + " \(number(points[2].x)) \(number(points[2].y))"
                )
            case .closeSubpath:
                commands.append("Z")
            @unknown default:
                break
            }
        }
        return commands.joined(separator: " ")
    }

    // Two decimals is a hundredth of a point, finer than any renderer places a stroke.
    nonisolated static func number(_ value: CGFloat, decimals: Int = 2) -> String {
        var text = String(format: "%.\(decimals)f", Double(value))
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    nonisolated static func paint(_ attribute: String, _ color: CGColor) -> String {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 4
        else { return " \(attribute)=\"#000000\"" }

        let hex = components.prefix(3)
            .map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }
            .joined()
        let alpha = min(max(components[3], 0), 1)
        guard alpha < 1 else { return " \(attribute)=\"#\(hex)\"" }
        return " \(attribute)=\"#\(hex)\" \(attribute)-opacity=\"\(number(alpha, decimals: 3))\""
    }

    nonisolated static func cssWeight(of font: NSFont) -> Int {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        let scale: [(trait: Double, css: Int)] = [
            (-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900),
        ]
        return scale.min { abs($0.trait - weight) < abs($1.trait - weight) }?.css ?? 400
    }

    // Characters XML 1.0 cannot hold become U+FFFD, so any table name gives a well-formed file.
    nonisolated static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                let value = scalar.value
                let allowed = (0x20...0xD7FF).contains(value) || (0xE000...0xFFFD).contains(value) || value >= 0x10000
                result.unicodeScalars.append(allowed ? scalar : "\u{FFFD}")
            }
        }
        return result
    }
}
