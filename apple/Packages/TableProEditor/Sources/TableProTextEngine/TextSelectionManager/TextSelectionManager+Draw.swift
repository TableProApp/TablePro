//
//  TextSelectionManager+Draw.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 1/12/25.
//

import AppKit

extension TextSelectionManager {
    /// Draws line backgrounds and selection rects for each selection in the given rect.
    /// - Parameter rect: The rect to draw in.
    public func drawSelections(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        var highlightedLines: Set<TextLine.ID> = []
        // For each selection in the rect
        for textSelection in textSelections {
            if textSelection.range.isEmpty {
                drawHighlightedLine(
                    in: rect,
                    for: textSelection,
                    context: context,
                    highlightedLines: &highlightedLines
                )
            } else {
                drawSelectedRange(in: rect, for: textSelection, context: context)
            }
        }
        context.restoreGState()
        noteSelectionsDrawn(in: rect)
    }

    /// Draws a highlighted line in the given rect.
    /// - Parameters:
    ///   - rect: The rect to draw in.
    ///   - textSelection: The selection to draw.
    ///   - context: The context to draw in.
    ///   - highlightedLines: The set of all lines that have already been highlighted, used to avoid highlighting lines
    ///                       twice and updated if this function comes across a new line id.
    private func drawHighlightedLine(
        in rect: NSRect,
        for textSelection: TextSelection,
        context: CGContext,
        highlightedLines: inout Set<TextLine.ID>
    ) {
        guard let linePosition = layoutManager?.textLineForOffset(textSelection.range.location),
              !highlightedLines.contains(linePosition.data.id) else {
            return
        }
        highlightedLines.insert(linePosition.data.id)
        context.saveGState()

        let insetXPos = max(rect.minX, edgeInsets.left)
        let maxWidth = (textView?.frame.width ?? 0) - insetXPos - edgeInsets.right

        let selectionRect = CGRect(
            x: insetXPos,
            y: linePosition.yPos,
            width: min(rect.width, maxWidth),
            height: linePosition.height
        ).pixelAligned

        if selectionRect.intersects(rect) {
            context.setFillColor(selectedLineBackgroundColor.safeCGColor)
            context.fill(selectionRect)
        }
        context.restoreGState()
    }

    /// Draws a selected range in the given context.
    /// - Parameters:
    ///   - rect: The rect to draw in.
    ///   - range: The range to highlight.
    ///   - context: The context to draw in.
    private func drawSelectedRange(in rect: NSRect, for textSelection: TextSelection, context: CGContext) {
        context.saveGState()
        context.setFillColor(selectedRangeFillColor.safeCGColor)
        context.fill(getFillRects(in: rect, for: textSelection))
        context.restoreGState()
    }

    // `unemphasizedSelectedTextBackgroundColor` is documented for a window that is not key OR a view without
    // key focus, so both conditions gate the accent colour.
    var selectedRangeFillColor: NSColor {
        let hasFocus = (textView?.isFirstResponder ?? false) && (textView?.window?.isKeyWindow ?? false)
        return drawsSelectionEmphasized || hasFocus
            ? selectionBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
    }
}
