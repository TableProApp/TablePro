//
//  LineFragmentRenderer.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/10/25.
//

import AppKit
import CodeEditTextViewObjC

/// Manages drawing line fragments into a drawing context.
public final class LineFragmentRenderer {
    private struct CacheKey: Hashable {
        let string: String
        let font: NSFont
        let color: NSColor
    }

    private struct InvisibleDrawingContext {
        let lineFragment: LineFragment
        let ctLine: CTLine
        let contentOffset: Int
        let position: CGPoint
        let context: CGContext
    }

    weak var textStorage: NSTextStorage?
    weak var invisibleCharacterDelegate: InvisibleCharactersDelegate?
    private var attributedStringCache: [CacheKey: CTLine] = [:]

    /// Create a fragment renderer.
    /// - Parameters:
    ///   - textStorage: The text storage backing the fragments being drawn.
    ///   - invisibleCharacterDelegate: A delegate object to interrogate for invisible character drawing.
    public init(textStorage: NSTextStorage?, invisibleCharacterDelegate: InvisibleCharactersDelegate?) {
        self.textStorage = textStorage
        self.invisibleCharacterDelegate = invisibleCharacterDelegate
    }

    /// Draw the given line fragment into a drawing context, using the invisible character configuration determined
    /// from the ``invisibleCharacterDelegate``, and line fragment information from the passed ``LineFragment`` object.
    /// - Parameters:
    ///   - lineFragment: The line fragment to drawn
    ///   - context: The drawing context to draw into.
    ///   - yPos: In the drawing context, what `y` position to start drawing at.
    public func draw(lineFragment: LineFragment, in context: CGContext, yPos: CGFloat) {
        if invisibleCharacterDelegate?.invisibleStyleShouldClearCache() == true {
            attributedStringCache.removeAll(keepingCapacity: true)
        }

        context.saveGState()
        // Removes jagged edges
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // Effectively increases the screen resolution by drawing text in each LED color pixel (R, G, or B), rather than
        // the triplet of pixels (RGB) for a regular pixel. This can increase text clarity, but loses effectiveness
        // in low-contrast settings.
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)

        // Quantizes the position of each glyph, resulting in slightly less accurate positioning, and gaining higher
        // quality bitmaps and performance.
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)

        ContextSetHiddenSmoothingStyle(context, 16)

        context.textMatrix = .init(scaleX: 1, y: -1)

        var currentPosition: CGFloat = 0.0
        var currentLocation = 0
        for content in lineFragment.contents {
            context.saveGState()
            switch content.data {
            case .text(let ctLine):
                context.textPosition = CGPoint(
                    x: currentPosition,
                    y: yPos + lineFragment.height - lineFragment.descent + (lineFragment.heightDifference/2)
                ).pixelAligned
                CTLineDraw(ctLine, context)

                drawInvisibles(
                    lineFragment: lineFragment,
                    for: ctLine,
                    contentOffset: currentLocation,
                    position: CGPoint(x: currentPosition, y: yPos),
                    in: context
                )
            case .attachment(let attachment):
                attachment.attachment.draw(
                    in: context,
                    rect: NSRect(
                        x: currentPosition,
                        y: yPos + (lineFragment.heightDifference/2),
                        width: attachment.width,
                        height: lineFragment.height
                    )
                )
            }
            context.restoreGState()
            currentPosition += content.width
            currentLocation += content.length
        }
        context.restoreGState()
    }

    private func drawInvisibles(
        lineFragment: LineFragment,
        for ctLine: CTLine,
        contentOffset: Int,
        position: CGPoint,
        in context: CGContext
    ) {
        guard let textStorage, let invisibleCharacterDelegate else { return }

        let drawingContext = InvisibleDrawingContext(
            lineFragment: lineFragment,
            ctLine: ctLine,
            contentOffset: contentOffset,
            position: position,
            context: context
        )

        let range = createTextRange(for: drawingContext).clamped(to: (textStorage.string as NSString).length)
        let string = (textStorage.string as NSString).substring(with: range)

        processInvisibleCharacters(
            in: string,
            range: range,
            delegate: invisibleCharacterDelegate,
            drawingContext: drawingContext
        )
    }

    private func createTextRange(for drawingContext: InvisibleDrawingContext) -> NSRange {
        return NSRange(
            start: drawingContext.lineFragment.documentRange.location + drawingContext.contentOffset,
            end: drawingContext.lineFragment.documentRange.max
        )
    }

    private func processInvisibleCharacters(
        in string: String,
        range: NSRange,
        delegate: InvisibleCharactersDelegate,
        drawingContext: InvisibleDrawingContext
    ) {
        drawingContext.context.saveGState()
        defer { drawingContext.context.restoreGState() }

        lazy var offset = CTLineGetStringRange(drawingContext.ctLine).location

        for (idx, character) in string.utf16.enumerated()
        where delegate.triggerCharacters.contains(character) {
            processInvisibleCharacter(
                character: character,
                at: idx,
                in: range,
                offset: offset,
                delegate: delegate,
                drawingContext: drawingContext
            )
        }
    }

    // Disabling the next lint warning because I *cannot* figure out how to split this up further.

    private func processInvisibleCharacter( // swiftlint:disable:this function_parameter_count
        character: UInt16,
        at index: Int,
        in range: NSRange,
        offset: Int,
        delegate: InvisibleCharactersDelegate,
        drawingContext: InvisibleDrawingContext
    ) {
        guard let style = delegate.invisibleStyle(
            for: character,
            at: NSRange(start: range.location + index, end: range.max),
            lineRange: drawingContext.lineFragment.documentRange
        ) else {
            return
        }

        let xOffset = CTLineGetOffsetForStringIndex(drawingContext.ctLine, offset + index, nil)

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
                offset: offset,
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
        return CGPoint(
            x: basePosition.x + xOffset,
            y: basePosition.y + lineFragment.height - lineFragment.descent + (lineFragment.heightDifference/2)
        )
    }

    private func calculateEmphasisRect(
        basePosition: CGPoint,
        xOffset: CGFloat,
        characterIndex: Int,
        offset: Int,
        drawingContext: InvisibleDrawingContext
    ) -> NSRect {
        let xEndOffset = if offset + characterIndex + 1 == drawingContext.lineFragment.documentRange.length {
            drawingContext.lineFragment.width
        } else {
            CTLineGetOffsetForStringIndex(drawingContext.ctLine, offset + characterIndex + 1, nil)
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
        context.setFillColor(color.cgColor)

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
