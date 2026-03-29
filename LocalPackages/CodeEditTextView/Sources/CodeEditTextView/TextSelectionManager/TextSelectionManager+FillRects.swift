//
//  TextSelectionManager+FillRects.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/22/23.
//

import Foundation

extension TextSelectionManager {
    /// Calculate a set of rects for a text selection suitable for filling with the selection color to indicate a
    /// multi-line selection. The returned rects surround all selected line fragments for the given selection,
    /// following the available text layout space, rather than the available selection layout space.
    ///
    /// - Parameters:
    ///   - rect: The bounding rect of available draw space.
    ///   - textSelection: The selection to use.
    /// - Returns: An array of rects that the selection overlaps.
    func getFillRects(in rect: NSRect, for textSelection: TextSelection) -> [CGRect] {
        guard let layoutManager,
              let range = textSelection.range.intersection(delegate?.visibleTextRange ?? .zero) else {
            return []
        }

        var fillRects: [CGRect] = []

        let textWidth = if layoutManager.maxLineLayoutWidth == .greatestFiniteMagnitude {
            layoutManager.maxLineWidth
        } else {
            layoutManager.maxLineLayoutWidth
        }
        let maxWidth = max(textWidth, layoutManager.wrapLinesWidth)
        let validTextDrawingRect = CGRect(
            x: layoutManager.edgeInsets.left,
            y: rect.minY,
            width: maxWidth,
            height: rect.height
        ).intersection(rect)

        for linePosition in layoutManager.linesInRange(range) {
            fillRects.append(
                contentsOf: getFillRects(in: validTextDrawingRect, selectionRange: range, forPosition: linePosition)
            )
        }

        // Pixel align these to avoid aliasing on the edges of each rect that should be a solid box.
        return fillRects.map { $0.intersection(validTextDrawingRect).pixelAligned }
    }

    /// Find fill rects for a specific line position.
    /// - Parameters:
    ///   - rect: The bounding rect of the overall view.
    ///   - range: The selected range to create fill rects for.
    ///   - linePosition: The line position to use.
    /// - Returns: An array of rects that the selection overlaps.
    private func getFillRects(
        in rect: NSRect,
        selectionRange range: NSRange,
        forPosition linePosition: TextLineStorage<TextLine>.TextLinePosition
    ) -> [CGRect] {
        guard let layoutManager else { return [] }
        var fillRects: [CGRect] = []

        // The selected range contains some portion of the line
        for fragmentPosition in linePosition.data.lineFragments {
            guard let fragmentRange = fragmentPosition
                .range
                .shifted(by: linePosition.range.location),
                  let intersectionRange = fragmentRange.intersection(range),
                  let minRect = layoutManager.rectForOffset(intersectionRange.location) else {
                continue
            }

            let maxRect: CGRect
            let endOfLine = fragmentRange.max <= range.max || range.contains(fragmentRange.max)
            let endOfDocument = intersectionRange.max == layoutManager.lineStorage.length
            let emptyLine = linePosition.range.isEmpty

            // If the selection is at the end of the line, or contains the end of the fragment, and is not the end
            // of the document, we select the entire line to the right of the selection point.
            // true, !true = false, false
            // true, !true = false, true
            if endOfLine && !(endOfDocument && !emptyLine) {
                maxRect = CGRect(
                    x: rect.maxX,
                    y: fragmentPosition.yPos + linePosition.yPos,
                    width: 0,
                    height: fragmentPosition.height
                )
            } else if let maxFragmentRect = layoutManager.rectForOffset(intersectionRange.max) {
                maxRect = maxFragmentRect
            } else {
                continue
            }

            fillRects.append(CGRect(
                x: minRect.origin.x,
                y: minRect.origin.y,
                width: maxRect.minX - minRect.minX,
                height: max(minRect.height, maxRect.height)
            ))
        }

        return fillRects
    }
}
