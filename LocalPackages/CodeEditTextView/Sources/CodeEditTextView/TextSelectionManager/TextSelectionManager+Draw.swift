//
//  TextSelectionManager+Draw.swift
//  CodeEditTextView
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
            context.setFillColor(selectedLineBackgroundColor.cgColor)
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

        let fillColor = (textView?.isFirstResponder ?? false)
        ? selectionBackgroundColor.cgColor
        : selectionBackgroundColor.grayscale.cgColor

        context.setFillColor(fillColor)

        let fillRects = getFillRects(in: rect, for: textSelection)
        textSelection.boundingRect = fillRects.boundingRect()

        context.fill(fillRects)
        context.restoreGState()
    }

}
