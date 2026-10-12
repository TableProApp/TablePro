//
//  LineFragmentRenderer+Invisibles.swift
//  TableProTextEngine
//

import AppKit

extension LineFragmentRenderer {
    private struct InvisibleDrawingContext {
        let lineFragment: LineFragment
        let ctLine: CTLine
        /// The index in the `CTLine`'s string that the scan starts at.
        let lineOffset: Int
        /// The offset from the start of the fragment that the scan starts at.
        let fragmentOffset: Int
        /// The end of the content being scanned, in document coordinates.
        let contentEnd: Int
        let position: CGPoint
        let context: CGContext
    }

    /// Draws the invisible characters of one text content.
    /// - Parameters:
    ///   - drawing: The content being drawn.
    ///   - lineFragment: The fragment the content belongs to.
    ///   - visibleRange: The part of the content's string the clip can reach, or `nil` to scan all of it.
    ///   - context: The context being drawn into.
    func drawInvisibles(
        _ drawing: TextContentDrawing,
        of lineFragment: LineFragment,
        visibleRange: CFRange?,
        in context: CGContext
    ) {
        guard let textStorage,
              let invisibleCharacterDelegate,
              !invisibleCharacterDelegate.triggerCharacters.isEmpty else {
            return
        }

        let contentRange = CTLineGetStringRange(drawing.ctLine)
        let scanRange = Self.contentScanRange(contentRange: contentRange, visibleRange: visibleRange)
        guard scanRange.length > 0 else { return }

        let string = textStorage.string as NSString
        let contentStart = lineFragment.documentRange.location + drawing.contentOffset
        let documentRange = NSRange(
            start: contentStart + scanRange.location,
            end: contentStart + scanRange.max
        ).clamped(to: string.length)
        guard documentRange.length > 0 else { return }

        let drawingContext = InvisibleDrawingContext(
            lineFragment: lineFragment,
            ctLine: drawing.ctLine,
            lineOffset: contentRange.location + scanRange.location,
            fragmentOffset: drawing.contentOffset + scanRange.location,
            contentEnd: min(contentStart + contentRange.length, string.length),
            position: drawing.origin,
            context: context
        )

        processInvisibleCharacters(
            in: string.substring(with: documentRange),
            range: documentRange,
            delegate: invisibleCharacterDelegate,
            drawingContext: drawingContext
        )
    }

    /// The part of a content's own text a draw has to scan for invisible characters.
    ///
    /// Ends at the content's own end rather than at the end of the fragment, so a fragment holding more than one
    /// content never prices a later content's characters off this content's line.
    /// - Parameters:
    ///   - contentRange: The string range of the content's `CTLine`.
    ///   - visibleRange: The part of that range the clip can reach, or `nil` when no bound is known.
    /// - Returns: A range relative to the start of the content.
    static func contentScanRange(contentRange: CFRange, visibleRange: CFRange?) -> NSRange {
        let length = max(0, contentRange.length)
        guard let visibleRange else {
            return NSRange(location: 0, length: length)
        }
        let start = min(max(0, visibleRange.location - contentRange.location), length)
        let end = min(max(start, visibleRange.location + visibleRange.length - contentRange.location), length)
        return NSRange(location: start, length: end - start)
    }

    private func processInvisibleCharacters(
        in string: String,
        range: NSRange,
        delegate: InvisibleCharactersDelegate,
        drawingContext: InvisibleDrawingContext
    ) {
        drawingContext.context.saveGState()
        defer { drawingContext.context.restoreGState() }

        lazy var markedOffsets = Set(drawingContext.lineFragment.specialCharacters.flatMap { mark in
            mark.offset..<(mark.offset + mark.length)
        })

        for (idx, character) in string.utf16.enumerated()
        where delegate.triggerCharacters.contains(character)
            && !markedOffsets.contains(drawingContext.fragmentOffset + idx) {
            processInvisibleCharacter(
                character: character,
                at: idx,
                in: range,
                delegate: delegate,
                drawingContext: drawingContext
            )
        }
    }

    private func processInvisibleCharacter(
        character: UInt16,
        at index: Int,
        in range: NSRange,
        delegate: InvisibleCharactersDelegate,
        drawingContext: InvisibleDrawingContext
    ) {
        let documentIndex = range.location + index
        guard let style = delegate.invisibleStyle(
            for: character,
            at: NSRange(start: documentIndex, end: max(documentIndex, drawingContext.contentEnd)),
            lineRange: drawingContext.lineFragment.documentRange
        ) else {
            return
        }

        let xOffset = CTLineGetOffsetForStringIndex(drawingContext.ctLine, drawingContext.lineOffset + index, nil)

        switch style {
        case let .replace(replacementCharacter, color, font):
            drawReplacementCharacter(
                replacementCharacter,
                color: color,
                font: font,
                at: calculateReplacementPosition(
                    basePosition: drawingContext.position,
                    xOffset: xOffset,
                    lineFragment: drawingContext.lineFragment
                ),
                in: drawingContext.context
            )
        case let .emphasize(color):
            let emphasizeRect = calculateEmphasisRect(
                basePosition: drawingContext.position,
                xOffset: xOffset,
                characterIndex: index,
                drawingContext: drawingContext
            )

            drawEmphasis(
                color: color,
                forRect: emphasizeRect,
                in: drawingContext.context
            )
        }
    }

    private func calculateReplacementPosition(
        basePosition: CGPoint,
        xOffset: CGFloat,
        lineFragment: LineFragment
    ) -> CGPoint {
        CGPoint(
            x: basePosition.x + xOffset,
            y: basePosition.y + lineFragment.height - lineFragment.descent + (lineFragment.heightDifference / 2)
        )
    }

    private func calculateEmphasisRect(
        basePosition: CGPoint,
        xOffset: CGFloat,
        characterIndex: Int,
        drawingContext: InvisibleDrawingContext
    ) -> NSRect {
        let fragmentIndex = drawingContext.fragmentOffset + characterIndex
        let xEndOffset = if fragmentIndex + 1 == drawingContext.lineFragment.documentRange.length {
            drawingContext.lineFragment.width
        } else {
            CTLineGetOffsetForStringIndex(
                drawingContext.ctLine,
                drawingContext.lineOffset + characterIndex + 1,
                nil
            )
        }

        return NSRect(
            x: basePosition.x + xOffset,
            y: basePosition.y,
            width: xEndOffset - xOffset,
            height: drawingContext.lineFragment.scaledHeight
        )
    }

    private func drawReplacementCharacter(
        _ replacementCharacter: String,
        color: NSColor,
        font: NSFont,
        at position: CGPoint,
        in context: CGContext
    ) {
        let cacheKey = CacheKey(string: replacementCharacter, font: font, color: color)
        let ctLine: CTLine
        if let cachedValue = attributedStringCache[cacheKey] {
            ctLine = cachedValue
        } else {
            let attrString = NSAttributedString(string: replacementCharacter, attributes: [
                .font: font,
                .foregroundColor: color
            ])
            ctLine = CTLineCreateWithAttributedString(attrString)
            attributedStringCache[cacheKey] = ctLine
        }
        context.textPosition = position
        CTLineDraw(ctLine, context)
    }

    private func drawEmphasis(
        color: NSColor,
        forRect: NSRect,
        in context: CGContext
    ) {
        context.setFillColor(color.safeCGColor)

        let rect: CGRect

        if forRect.width == 0 {
            // Zero-width character, add padding
            rect = CGRect(x: forRect.origin.x - 2, y: forRect.origin.y, width: 4, height: forRect.height)
        } else {
            rect = forRect
        }

        context.fill(rect)
    }
}
