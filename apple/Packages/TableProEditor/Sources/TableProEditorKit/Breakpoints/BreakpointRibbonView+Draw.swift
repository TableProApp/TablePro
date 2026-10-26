//
//  BreakpointRibbonView+Draw.swift
//  TableProEditorKit
//

import AppKit
import TableProTextEngine

extension BreakpointRibbonView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let controller, let layoutManager = controller.textView?.layoutManager else { return }
        let breakpoints = controller.breakpointLines
        let executionLine = controller.executionLine

        for lineNumber in breakpoints {
            let marker: Marker = lineNumber == executionLine ? .breakpointAtExecution : .breakpoint
            draw(marker, color: breakpointColor, onLine: lineNumber, in: dirtyRect, layoutManager: layoutManager)
        }

        if let executionLine, !breakpoints.contains(executionLine) {
            draw(.execution, color: executionColor, onLine: executionLine, in: dirtyRect, layoutManager: layoutManager)
        }

        if let hoveredLine, hoveredLine != executionLine, !breakpoints.contains(hoveredLine) {
            let hint = breakpointColor.withAlphaComponent(breakpointColor.alphaComponent * Self.hintOpacity)
            draw(.breakpoint, color: hint, onLine: hoveredLine, in: dirtyRect, layoutManager: layoutManager)
        }
    }

    private func draw(
        _ marker: Marker,
        color: NSColor,
        onLine lineNumber: Int,
        in dirtyRect: NSRect,
        layoutManager: TextLayoutManager
    ) {
        guard let line = position(ofLine: lineNumber, in: layoutManager),
              line.yPos < dirtyRect.maxY, line.yPos + line.height > dirtyRect.minY,
              let image = glyph(marker, color: color) else {
            return
        }

        let size = image.size
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: line.yPos + (line.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect.pixelAligned)
    }
}
