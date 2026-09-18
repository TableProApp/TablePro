//
//  TextSelectionManager+FillRects.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 10/22/23.
//

import Foundation

extension TextSelectionManager {
    /// A rect a text selection covers, and the line fragment it was measured from.
    ///
    /// The fragment travels with the rect because the rect alone cannot say which fragment it belongs to. Fill rects
    /// are pixel aligned, so an edge can round a fraction of a point into the neighbouring line, and anything that
    /// re-derives the fragment from the rect's `y` position picks up lines the selection never touched.
    struct FillRect {
        /// The rect the selection covers, in the text view's coordinate space.
        let rect: CGRect
        /// The line fragment the selection covers part of.
        let fragment: LineFragment
        /// Where `fragment` begins, in the text view's coordinate space.
        let fragmentOrigin: CGPoint

        /// Returns this rect clipped to a drawing rect, pixel aligned like the selection highlight.
        func clipped(to drawingRect: CGRect) -> FillRect {
            FillRect(
                rect: rect.intersection(drawingRect).pixelAligned,
                fragment: fragment,
                fragmentOrigin: fragmentOrigin
            )
        }
    }

    /// Calculate a set of rects for a text selection suitable for filling with the selection color to indicate a
    /// multi-line selection. The returned rects surround all selected line fragments for the given selection,
    /// following the available text layout space, rather than the available selection layout space.
    ///
    /// - Parameters:
    ///   - rect: The bounding rect of available draw space.
    ///   - textSelection: The selection to use.
    /// - Returns: An array of rects that the selection overlaps.
    func getFillRects(in rect: NSRect, for textSelection: TextSelection) -> [CGRect] {
        fillRects(in: rect, for: textSelection).map(\.rect)
    }

    /// Calculate the rects a text selection covers, each with the line fragment it was measured from.
    ///
    /// Use this over ``TextSelectionManager/getFillRects(in:for:)`` when the rects are used to draw text rather than
    /// to fill the selection color, such as the image of a dragged selection.
    ///
    /// - Parameters:
    ///   - rect: The bounding rect of available draw space.
    ///   - textSelection: The selection to use.
    /// - Returns: A fill rect for every line fragment the selection overlaps inside `rect`.
    func fillRects(in rect: NSRect, for textSelection: TextSelection) -> [FillRect] {
        // Bound the work by the rect we were asked to fill, never by the viewport: under responsive scrolling
        // `draw(_:)` is called with rects outside the visible area and the result is cached.
        guard let layoutManager,
              let drawnRange = layoutManager.textRange(covering: rect),
              let range = textSelection.range.intersection(drawnRange) else {
            return []
        }

        var rects: [FillRect] = []

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
            rects.append(
                contentsOf: fillRects(in: validTextDrawingRect, selectionRange: range, forPosition: linePosition)
            )
        }

        // Pixel align these to avoid aliasing on the edges of each rect that should be a solid box. A fragment
        // that misses the drawing rect intersects to `CGRect.null`, whose origin is infinite.
        return rects
            .map { $0.clipped(to: validTextDrawingRect) }
            .filter { !$0.rect.isNull && !$0.rect.isEmpty }
    }

    /// Find fill rects for a specific line position.
    /// - Parameters:
    ///   - rect: The bounding rect of the overall view.
    ///   - range: The selected range to create fill rects for.
    ///   - linePosition: The line position to use.
    /// - Returns: An array of rects that the selection overlaps.
    private func fillRects(
        in rect: NSRect,
        selectionRange range: NSRange,
        forPosition linePosition: TextLineStorage<TextLine>.TextLinePosition
    ) -> [FillRect] {
        guard let layoutManager else { return [] }
        var rects: [FillRect] = []

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
            // If the line ends with a line-break character, the selection logically continues onto a
            // (possibly empty) trailing line and the highlight should extend to the right edge — even
            // when this fragment is at the end of the document. Without this check, the very last
            // fragment of a buffer that ends in `\n` collapses to zero width because
            // `rectForOffset(lineStorage.length)` resolves to the trailing-empty-line position at
            // the leading edge.
            let lineEndsWithNewline: Bool = {
                guard !linePosition.range.isEmpty,
                      let textStorage = layoutManager.textStorage,
                      let lineString = textStorage.substring(from: linePosition.range) else {
                    return false
                }
                return LineEnding(line: lineString) != nil
            }()

            // If the selection is at the end of the line, or contains the end of the fragment, and is not the end
            // of the document, we select the entire line to the right of the selection point.
            // true, !true = false, false
            // true, !true = false, true
            if endOfLine && !(endOfDocument && !emptyLine && !lineEndsWithNewline) {
                maxRect = CGRect(
                    x: rect.maxX,
                    y: fragmentPosition.yPos + linePosition.yPos,
                    width: 0,
                    height: fragmentPosition.height
                )
            } else if let maxFragmentRect = layoutManager.rectForOffset(intersectionRange.max) {
                maxRect = maxFragmentRect
            } else {
                maxRect = CGRect(
                    x: minRect.maxX,
                    y: minRect.origin.y,
                    width: 0,
                    height: minRect.height
                )
            }

            rects.append(
                FillRect(
                    rect: CGRect(
                        x: minRect.origin.x,
                        y: minRect.origin.y,
                        width: maxRect.minX - minRect.minX,
                        height: max(minRect.height, maxRect.height)
                    ),
                    fragment: fragmentPosition.data,
                    fragmentOrigin: CGPoint(
                        x: layoutManager.edgeInsets.left,
                        y: linePosition.yPos + fragmentPosition.yPos
                    )
                )
            )
        }

        return rects
    }
}
