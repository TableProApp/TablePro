//
//  SpecialCharacterMarkRenderer.swift
//  CodeEditTextView
//

import AppKit

enum SpecialCharacterMarkRenderer {
    static func draw(
        _ mark: SpecialCharacterMark,
        from minX: CGFloat,
        to maxX: CGFloat,
        top: CGFloat,
        height: CGFloat,
        color: NSColor,
        in context: CGContext
    ) {
        let inset = SpecialCharacterMetrics.outerInset
        let width = maxX - minX
        guard width > 2 * inset, height > 2 * inset else { return }

        let box = CGRect(x: minX + inset, y: top + inset, width: width - 2 * inset, height: height - 2 * inset)
            .insetBy(dx: SpecialCharacterMetrics.strokeWidth / 2, dy: SpecialCharacterMetrics.strokeWidth / 2)

        context.saveGState()
        defer { context.restoreGState() }

        let radius = min(SpecialCharacterMetrics.cornerRadius, box.height / 2, box.width / 2)
        context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setStrokeColor(color.safeCGColor)
        context.setLineWidth(SpecialCharacterMetrics.strokeWidth)
        context.strokePath()

        guard case .marker(let label) = mark.character else { return }
        let line = SpecialCharacterMetrics.labelLine(label, font: mark.font, color: color)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let labelWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: box.midX - labelWidth / 2, y: box.midY + (ascent - descent) / 2)
        CTLineDraw(line, context)
    }
}
