//
//  LineFragmentRenderer.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 6/10/25.
//

import AppKit
import TableProTextEngineObjC

/// Manages drawing line fragments into a drawing context.
public final class LineFragmentRenderer {
    struct CacheKey: Hashable {
        let string: String
        let font: NSFont
        let color: NSColor
    }

    /// One text content of a fragment, and where it sits in the drawing context.
    struct TextContentDrawing {
        let ctLine: CTLine
        /// The index of the content in the fragment's ``LineFragment/contents``.
        let contentIndex: Int
        /// The offset of the content from the start of the fragment.
        let contentOffset: Int
        let width: CGFloat
        /// The content's left edge and the fragment's top, in the drawing context.
        let origin: CGPoint

        func baseline(of lineFragment: LineFragment) -> CGPoint {
            CGPoint(
                x: origin.x,
                y: origin.y + lineFragment.height - lineFragment.descent + (lineFragment.heightDifference / 2)
            ).pixelAligned
        }
    }

    weak var textStorage: NSTextStorage?
    weak var invisibleCharacterDelegate: InvisibleCharactersDelegate?
    var attributedStringCache: [CacheKey: CTLine] = [:]

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
        prepareContext(context)

        var currentPosition: CGFloat = 0.0
        var currentLocation = 0
        for (index, content) in lineFragment.contents.enumerated() {
            context.saveGState()
            switch content.data {
            case .text(let ctLine):
                drawTextContent(
                    TextContentDrawing(
                        ctLine: ctLine,
                        contentIndex: index,
                        contentOffset: currentLocation,
                        width: content.width,
                        origin: CGPoint(x: currentPosition, y: yPos)
                    ),
                    of: lineFragment,
                    in: context
                )
            case .attachment(let attachment):
                attachment.attachment.draw(
                    in: context,
                    rect: NSRect(
                        x: currentPosition,
                        y: yPos + (lineFragment.heightDifference / 2),
                        width: attachment.width,
                        height: lineFragment.height
                    )
                )
            }
            context.restoreGState()
            currentPosition += content.width
            currentLocation += content.length
        }
        drawSpecialCharacters(of: lineFragment, yPos: yPos, in: context)
        context.restoreGState()
    }

    private func prepareContext(_ context: CGContext) {
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
    }

    private func drawTextContent(
        _ drawing: TextContentDrawing,
        of lineFragment: LineFragment,
        in context: CGContext
    ) {
        let visibleRange = drawText(drawing, of: lineFragment, in: context)
        drawInvisibles(drawing, of: lineFragment, visibleRange: visibleRange, in: context)
    }

    /// Draws one text content of a fragment, bounding the work by the context's clip when the content is wider than
    /// the clip can show.
    ///
    /// A content that fits inside the clip is drawn whole, which is every wrapped line, every drag image and every
    /// fragment the minimap asks for. Only a content sticking out of the clip pays for a drawing plan.
    /// - Returns: The range of the content's string the clip can reach, or `nil` when the whole content was drawn.
    private func drawText(
        _ drawing: TextContentDrawing,
        of lineFragment: LineFragment,
        in context: CGContext
    ) -> CFRange? {
        let position = drawing.baseline(of: lineFragment)
        let clip = context.boundingBoxOfClipPath
        let sticksOut = !clip.isNull && !clip.isInfinite
            && (position.x < clip.minX || position.x + drawing.width > clip.maxX)
        guard sticksOut else {
            context.textPosition = position
            CTLineDraw(drawing.ctLine, context)
            return nil
        }

        let plan = lineFragment.clippedDrawingPlan(forContentAt: drawing.contentIndex, ctLine: drawing.ctLine)
        return ClippedLineDrawing.draw(
            drawing.ctLine,
            plan: plan,
            at: position,
            width: drawing.width,
            in: context
        )
    }

    private func drawSpecialCharacters(of lineFragment: LineFragment, yPos: CGFloat, in context: CGContext) {
        guard !lineFragment.specialCharacters.isEmpty else { return }
        let top = yPos + lineFragment.heightDifference / 2
        let clip = context.boundingBoxOfClipPath
        let candidates = lineFragment.specialCharacters(from: clip.minX, to: clip.maxX)
        for mark in candidates where mark.maxX >= clip.minX && mark.minX <= clip.maxX {
            SpecialCharacterMarkRenderer.draw(
                mark,
                from: mark.minX,
                to: mark.maxX,
                top: top,
                height: lineFragment.height,
                color: mark.color,
                in: context
            )
        }
    }
}
