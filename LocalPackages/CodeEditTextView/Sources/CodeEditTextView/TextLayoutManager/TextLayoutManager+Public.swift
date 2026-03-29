//
//  TextLayoutManager+Public.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/13/23.
//

import AppKit

extension TextLayoutManager {
    // MARK: - Estimate

    public func estimatedHeight() -> CGFloat {
        max(lineStorage.height, estimateLineHeight())
    }

    public func estimatedWidth() -> CGFloat {
        maxLineWidth + edgeInsets.horizontal
    }

    // MARK: - Text Lines

    /// Finds a text line for the given y position relative to the text view.
    ///
    /// Y values begin at the top of the view and extend down. Eg, a `0` y value would  return the first line in
    /// the text view if it exists. Though, for that operation the user should instead use
    /// ``TextLayoutManager/textLineForIndex(_:)`` for reliability.
    ///
    /// - Parameter posY: The y position to find a line for.
    /// - Returns: A text line position, if a line could be found at the given y position.
    public func textLineForPosition(_ posY: CGFloat) -> TextLineStorage<TextLine>.TextLinePosition? {
        determineVisiblePosition(for: lineStorage.getLine(atPosition: posY))?.position
    }

    /// Finds a text line for a given text offset.
    ///
    /// This method will not do any checking for document bounds, and will simply return `nil` if the offset if negative
    /// or outside the range of the document.
    ///
    /// However, if the offset is equal to the length of the text storage (one index past the end of the document) this
    /// method will return the last line in the document if it exists.
    ///
    /// - Parameter offset: The offset in the document to fetch a line for.
    /// - Returns: A text line position, if a line could be found at the given offset.
    public func textLineForOffset(_ offset: Int) -> TextLineStorage<TextLine>.TextLinePosition? {
        if offset == lineStorage.length {
            return lineStorage.last
        } else {
            return determineVisiblePosition(for: lineStorage.getLine(atOffset: offset))?.position
        }
    }

    /// Finds text line and returns it if found.
    /// Lines are 0 indexed.
    /// - Parameter index: The line to find.
    /// - Returns: The text line position if any, `nil` if the index is out of bounds.
    public func textLineForIndex(_ index: Int) -> TextLineStorage<TextLine>.TextLinePosition? {
        guard index >= 0 && index < lineStorage.count else { return nil }
        return determineVisiblePosition(for: lineStorage.getLine(atIndex: index))?.position
    }

    /// Calculates the text position at the given point in the view.
    /// - Parameter point: The point to translate to text position.
    /// - Returns: The text offset in the document where the given point is laid out.
    /// - Warning: If the requested point has not been laid out or it's layout has since been invalidated by edits or
    ///            other changes, this method will return the invalid data. For best results, ensure the text around the
    ///            point has been laid out or is visible before calling this method.
    public func textOffsetAtPoint(_ point: CGPoint) -> Int? {
        guard point.y <= estimatedHeight() else { // End position is a special case.
            return textStorage?.length
        }
        guard let linePosition = determineVisiblePosition(for: lineStorage.getLine(atPosition: point.y))?.position,
              let fragmentPosition = linePosition.data.typesetter.lineFragments.getLine(
                atPosition: point.y - linePosition.yPos
              ) else {
            return nil
        }

        return textOffsetAtPoint(point, fragmentPosition: fragmentPosition, linePosition: linePosition)
    }

    func textOffsetAtPoint(
        _ point: CGPoint,
        fragmentPosition: TextLineStorage<LineFragment>.TextLinePosition,
        linePosition: TextLineStorage<TextLine>.TextLinePosition
    ) -> Int? {
        let fragment = fragmentPosition.data
        if fragment.width == 0 {
            return linePosition.range.location + fragmentPosition.range.location
        } else if fragment.width <= point.x - edgeInsets.left {
            return findOffsetAfterEndOf(fragmentPosition: fragmentPosition, in: linePosition)
        } else {
            return findOffsetAtPoint(inFragment: fragment, xPos: point.x, inLine: linePosition)
        }
    }

    /// Finds a document offset after a line fragment. Returns a cursor position.
    ///
    /// If the fragment ends the line, return the position before the potential line break. This visually positions the
    /// cursor at the end of the line, but before the break character. If deleted, it edits the visually selected line.
    ///
    /// If not at the line end, do the same with the fragment and respect any composed character sequences at
    /// the line break.
    ///
    /// Return the line end position otherwise.
    ///
    /// - Parameters:
    ///   - fragmentPosition: The fragment position being queried.
    ///   - linePosition: The line position that contains the `fragment`.
    /// - Returns: The position visually at the end of the line fragment.
    private func findOffsetAfterEndOf(
        fragmentPosition: TextLineStorage<LineFragment>.TextLinePosition,
        in linePosition: TextLineStorage<TextLine>.TextLinePosition
    ) -> Int? {
        let fragmentRange = fragmentPosition.range.translate(location: linePosition.range.location)
        let endPosition = fragmentRange.max

        // If the endPosition is at the end of the line, and the line ends with a line ending character
        // return the index before the eol.
        if fragmentPosition.index == linePosition.data.lineFragments.count - 1,
           let lineEnding = LineEnding(line: textStorage?.substring(from: fragmentRange) ?? "") {
            return endPosition - lineEnding.length
        } else if fragmentPosition.index != linePosition.data.lineFragments.count - 1 {
            // If this isn't the last fragment, we want to place the cursor at the offset right before the break
            // index, to appear on the end of *this* fragment.
            let string = (textStorage?.string as? NSString)
            return string?.rangeOfComposedCharacterSequence(at: endPosition - 1).location
        } else {
            // Otherwise, return the end of the fragment (and the end of the line).
            return endPosition
        }
    }

    /// Finds a document offset for a point that lies in a line fragment.
    /// - Parameters:
    ///   - fragment: The fragment the point lies in.
    ///   - xPos: The point being queried, relative to the text view.
    ///   - linePosition: The position that contains the `fragment`.
    /// - Returns: The offset (relative to the document) that's closest to the given point, or `nil` if it could not be
    ///            found.
    func findOffsetAtPoint(
        inFragment fragment: LineFragment,
        xPos: CGFloat,
        inLine linePosition: TextLineStorage<TextLine>.TextLinePosition
    ) -> Int? {
        guard let (content, contentPosition) = fragment.findContent(atX: xPos - edgeInsets.left) else {
            return nil
        }
        switch content.data {
        case .text(let ctLine):
            let fragmentIndex = CTLineGetStringIndexForPosition(
                ctLine,
                CGPoint(x: xPos - edgeInsets.left - contentPosition.xPos, y: fragment.height/2)
            )
            return fragmentIndex + contentPosition.offset + linePosition.range.location
        case .attachment:
            return contentPosition.offset + linePosition.range.location
        }
    }

    // MARK: - Rect For Offset

    /// Find a position for the character at a given offset.
    /// Returns the rect of the character at the given offset.
    /// The rect may represent more than one unicode unit, for instance if the offset is at the beginning of an
    /// emoji or non-latin glyph.
    /// - Parameter offset: The offset to create the rect for.
    /// - Returns: The found rect for the given offset.
    public func rectForOffset(_ offset: Int) -> CGRect? {
        guard offset < lineStorage.length else {
            return rectForEndOffset()
        }
        guard let linePosition = determineVisiblePosition(for: lineStorage.getLine(atOffset: offset))?.position else {
            return nil
        }
        guard let fragmentPosition = linePosition.data.typesetter.lineFragments.getLine(
            atOffset: offset - linePosition.range.location
        ) else {
            return CGRect(x: edgeInsets.left, y: linePosition.yPos, width: 0, height: linePosition.height)
        }

        // Get the *real* length of the character at the offset. If this is a surrogate pair it'll return the correct
        // length of the character at the offset.
        let realRange = if textStorage?.length == 0 {
            NSRange(location: offset, length: 0)
        } else if let string = textStorage?.string as? NSString {
            string.rangeOfComposedCharacterSequence(at: offset)
        } else {
            NSRange(location: offset, length: 0)
        }

        let minXPos = characterXPosition(
            in: fragmentPosition.data,
            for: realRange.location - linePosition.range.location - fragmentPosition.range.location
        )
        let maxXPos = characterXPosition(
            in: fragmentPosition.data,
            for: realRange.max - linePosition.range.location - fragmentPosition.range.location
        )

        return CGRect(
            x: minXPos + edgeInsets.left,
            y: linePosition.yPos + fragmentPosition.yPos,
            width: maxXPos - minXPos,
            height: fragmentPosition.data.scaledHeight
        )
    }

    /// Calculates all text bounding rects that intersect with a given range.
    /// - Parameters:
    ///   - range: The range to calculate bounding rects for.
    ///   - line: The line to calculate rects for.
    /// - Returns: Multiple bounding rects. Will return one rect for each line fragment that overlaps the given range.
    public func rectsFor(range: NSRange) -> [CGRect] {
        return linesInRange(range).flatMap { self.rectsFor(range: range, in: $0) }
    }

    /// Calculates all text bounding rects that intersect with a given range, with a given line position.
    /// - Parameters:
    ///   - range: The range to calculate bounding rects for.
    ///   - line: The line to calculate rects for.
    /// - Returns: Multiple bounding rects. Will return one rect for each line fragment that overlaps the given range.
    private func rectsFor(range: NSRange, in line: borrowing TextLineStorage<TextLine>.TextLinePosition) -> [CGRect] {
        guard let textStorage = (textStorage?.string as? NSString) else { return [] }

        // Don't make rects in between characters
        let realRangeStart = textStorage.rangeOfComposedCharacterSequence(at: range.lowerBound)
        let realRangeEnd = textStorage.rangeOfComposedCharacterSequence(at: range.upperBound - 1)

        // Fragments are relative to the line
        let relativeRange = NSRange(
            start: realRangeStart.lowerBound - line.range.location,
            end: realRangeEnd.upperBound - line.range.location
        )

        var rects: [CGRect] = []
        for fragmentPosition in line.data.lineFragments.linesInRange(relativeRange) {
            guard let intersectingRange = fragmentPosition.range.intersection(relativeRange) else { continue }
            let fragmentRect = characterRect(in: fragmentPosition.data, for: intersectingRange)
            guard fragmentRect.width > 0 else { continue }
            rects.append(
                CGRect(
                    x: fragmentRect.minX + edgeInsets.left,
                    y: fragmentPosition.yPos + line.yPos,
                    width: fragmentRect.width,
                    height: fragmentRect.height
                )
            )
        }
        return rects
    }

    /// Creates a smooth bezier path for the specified range.
    /// If the range exceeds the available text, it uses the maximum available range.
    /// - Parameters:
    ///   - range: The range of text offsets to generate the path for.
    ///   - cornerRadius: The radius of the edges when rounding. Defaults to four.
    /// - Returns: An `NSBezierPath` representing the visual shape for the text range, or `nil` if the range is invalid.
    public func roundedPathForRange(_ range: NSRange, cornerRadius: CGFloat = 4) -> NSBezierPath? {
        // Ensure the range is within the bounds of the text storage
        let validRange = NSRange(
            location: range.lowerBound,
            length: min(range.length, lineStorage.length - range.lowerBound)
        )

        guard validRange.length > 0 else { return rectForEndOffset().map { NSBezierPath(rect: $0) } }

        var rightSidePoints: [CGPoint] = [] // Points for Bottom-right → Top-right
        var leftSidePoints: [CGPoint] = []  // Points for Bottom-left → Top-left

        for fragmentRect in rectsFor(range: range) {
            rightSidePoints.append(
                contentsOf: [
                    CGPoint(x: fragmentRect.maxX, y: fragmentRect.minY), // Bottom-right
                    CGPoint(x: fragmentRect.maxX, y: fragmentRect.maxY)  // Top-right
                ]
            )
            leftSidePoints.insert(
                contentsOf: [
                    CGPoint(x: fragmentRect.minX, y: fragmentRect.maxY), // Top-left
                    CGPoint(x: fragmentRect.minX, y: fragmentRect.minY)  // Bottom-left
                ],
                at: 0
            )
        }

        // Combine the points in clockwise order
        let points = leftSidePoints + rightSidePoints

        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }

        // Close the path
        if let firstPoint = points.first {
            return NSBezierPath.smoothPath(points + [firstPoint], radius: cornerRadius)
        }

        return nil
    }

    /// Finds a suitable cursor rect for the end position.
    /// - Returns: A CGRect if it could be created.
    private func rectForEndOffset() -> CGRect? {
        if let last = lineStorage.last {
            if last.range.isEmpty {
                // Return a 0-width rect at the end of the last line.
                return CGRect(x: edgeInsets.left, y: last.yPos, width: 0, height: last.height)
            } else if let rect = rectForOffset(last.range.max - 1) {
                return  CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
            }
        } else if lineStorage.isEmpty {
            // Text is empty, create a new rect with estimated height at the origin
            return CGRect(
                x: edgeInsets.left,
                y: 0.0,
                width: 0,
                height: estimateLineHeight()
            )
        }
        return nil
    }

    // MARK: - Line Fragment Rects

    /// Finds the x position of the offset in the string the fragment represents.
    /// - Parameters:
    ///   - lineFragment: The line fragment to calculate for.
    ///   - offset: The offset, relative to the start of the *line*.
    /// - Returns: The x position of the character in the drawn line, from the left.
    public func characterXPosition(in lineFragment: LineFragment, for offset: Int) -> CGFloat {
        renderDelegate?.characterXPosition(in: lineFragment, for: offset) ?? lineFragment._xPos(for: offset)
    }

    public func characterRect(in lineFragment: LineFragment, for range: NSRange) -> CGRect {
        let minXPos = characterXPosition(in: lineFragment, for: range.lowerBound)
        let maxXPos = characterXPosition(in: lineFragment, for: range.upperBound)
        return CGRect(
            x: minXPos,
            y: 0,
            width: maxXPos - minXPos,
            height: lineFragment.scaledHeight
        ).pixelAligned
    }

    func contentRun(at offset: Int) -> LineFragment.FragmentContent? {
        guard let textLine = textLineForOffset(offset),
              let fragment = textLine.data.lineFragments.getLine(atOffset: offset - textLine.range.location) else {
            return nil
        }
        return fragment.data.findContent(at: offset - textLine.range.location - fragment.range.location)?.content
    }
}
