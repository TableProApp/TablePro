//
//  StatementRunRibbonView+Draw.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView

extension StatementRunRibbonView {
    /// How dim a control is when running is not possible right now.
    private static let disabledOpacity: CGFloat = 0.4

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isPointerInGutter,
              let layoutManager = controller?.textView?.layoutManager,
              let range = documentRange(covering: dirtyRect, layoutManager: layoutManager) else {
            return
        }

        let anchors = statementsByAnchorLine(in: range, layoutManager: layoutManager)
        for (lineNumber, statement) in anchors {
            guard let line = layoutManager.textLineForIndex(lineNumber) else { continue }
            draw(statement, atY: line.yPos, lineHeight: line.height)
        }
    }

    private func draw(_ statement: StatementRun, atY yPos: CGFloat, lineHeight: CGFloat) {
        let isHovered = isEnabled && statement == hoveredStatement
        var color = isHovered ? hoveredGlyphColor : glyphColor
        if !isEnabled {
            color = color.withAlphaComponent(color.alphaComponent * Self.disabledOpacity)
        }

        guard let image = glyph(color: color) else { return }

        let size = image.size
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: yPos + (lineHeight - size.height) / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect.pixelAligned)
    }
}
