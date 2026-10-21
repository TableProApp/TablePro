import AppKit

// The screen and every export draw through this, so no export drifts from the canvas.
@MainActor
protocol ERDiagramCanvas {
    func fill(_ path: CGPath, color: CGColor)
    // Round caps and joins for connectors, butt caps and miter joins for borders and rules.
    func stroke(_ path: CGPath, color: CGColor, lineWidth: CGFloat, rounded: Bool)
    func clip(to path: CGPath, _ draw: () -> Void)
    func drawText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        at point: CGPoint,
        anchor: ERDiagramTextAnchor,
        maxWidth: CGFloat
    )
    func drawSymbol(named name: String, pointSize: CGFloat, color: NSColor, at point: CGPoint, anchor: ERDiagramTextAnchor)
}

extension ERDiagramCanvas {
    func drawText(_ text: String, font: NSFont, color: NSColor, at point: CGPoint, anchor: ERDiagramTextAnchor) {
        drawText(text, font: font, color: color, at: point, anchor: anchor, maxWidth: .greatestFiniteMagnitude)
    }
}

// The context is expected to be flipped and to be `NSGraphicsContext.current`, which symbols draw into.
@MainActor
struct ERDiagramContextCanvas: ERDiagramCanvas {
    let context: CGContext

    func fill(_ path: CGPath, color: CGColor) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    func stroke(_ path: CGPath, color: CGColor, lineWidth: CGFloat, rounded: Bool) {
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(rounded ? .round : .butt)
        context.setLineJoin(rounded ? .round : .miter)
        context.addPath(path)
        context.strokePath()
    }

    func clip(to path: CGPath, _ draw: () -> Void) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        draw()
        context.restoreGState()
    }

    func drawText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        at point: CGPoint,
        anchor: ERDiagramTextAnchor,
        maxWidth: CGFloat
    ) {
        ERDiagramTextRenderer.draw(text, font: font, color: color, at: point, anchor: anchor, maxWidth: maxWidth, in: context)
    }

    func drawSymbol(named name: String, pointSize: CGFloat, color: NSColor, at point: CGPoint, anchor: ERDiagramTextAnchor) {
        ERDiagramSymbolRenderer.draw(named: name, pointSize: pointSize, color: color, at: point, anchor: anchor)
    }
}
