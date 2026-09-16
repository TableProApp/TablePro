//
//  ClippedLineDrawing.swift
//  TableProTextEngine
//

import AppKit
import CoreText

/// Draws the part of a `CTLine` a drawing context's clip can reach, rather than all of it.
///
/// `CTLineDraw` walks every glyph of a line however little of that line the context's clip shows. A line fragment is
/// as wide as its entire line when word wrapping is off, so scrolling sideways through a very long line exposes a
/// narrow strip and pays for the whole line to draw it.
///
/// `CTRunDraw` is not a drop-in replacement for `CTLineDraw`. Measured under the renderer's flipped text matrix it
/// misplaces every glyph carrying a vertical offset, and it draws no underline or strikethrough decoration at all.
/// ``Plan`` reads a line once and reports what that line allows. A line it refuses is drawn whole, and only its
/// invisible character scan is bounded.
enum ClippedLineDrawing {
    /// The window of a line the clip can reach, in the line's own coordinates.
    private struct Window {
        let minX: CGFloat
        let maxX: CGFloat
        let position: CGPoint
        let width: CGFloat
        let drawsGlyphRanges: Bool
    }

    /// Draws the part of a line the context's clip can reach, and reports the string range that part covers.
    ///
    /// Sets the context's text position itself, exactly as `CTLineDraw` requires.
    /// - Parameters:
    ///   - ctLine: The line to draw.
    ///   - plan: What the line allows, from ``Plan/init(ctLine:)``.
    ///   - position: Where the line's origin sits in the context.
    ///   - width: The typographic width of the line.
    ///   - context: The context to draw into.
    /// - Returns: The range of the line's string the clip can reach, or `nil` when no bound could be found.
    @discardableResult
    static func draw(
        _ ctLine: CTLine,
        plan: Plan,
        at position: CGPoint,
        width: CGFloat,
        in context: CGContext
    ) -> CFRange? {
        let lineRange = CTLineGetStringRange(ctLine)
        let clip = context.boundingBoxOfClipPath
        if !clip.isNull, clip.isEmpty {
            return CFRange(location: lineRange.location, length: 0)
        }
        guard !clip.isNull, !clip.isInfinite, plan.boundsGlyphSearch else {
            context.textPosition = position
            CTLineDraw(ctLine, context)
            return nil
        }

        let window = Window(
            minX: clip.minX - position.x - plan.trailingInkReach,
            maxX: clip.maxX - position.x + plan.leadingInkReach,
            position: position,
            width: width,
            drawsGlyphRanges: plan.drawsGlyphRanges
        )

        if !plan.drawsGlyphRanges {
            context.textPosition = position
            CTLineDraw(ctLine, context)
        }

        return visibleRange(in: ctLine, lineRange: lineRange, window: window, in: context)
    }

    /// Finds the glyphs of a run whose ink can appear between two x positions in line coordinates.
    ///
    /// Takes the glyph before the window as well, because a glyph starting before `minX` can reach into the window.
    /// - Parameters:
    ///   - run: The run to search.
    ///   - minX: The left edge of the window, already widened by the line's ink reach.
    ///   - maxX: The right edge of the window, already widened by the line's ink reach.
    /// - Returns: The glyph range to draw, or `nil` when the run has no glyph in the window.
    static func glyphRange(in run: CTRun, from minX: CGFloat, to maxX: CGFloat) -> CFRange? {
        let glyphCount = CTRunGetGlyphCount(run)
        guard glyphCount > 0 else { return nil }
        return withPositions(of: run, glyphCount: glyphCount) { positions in
            let start = max(0, firstIndex(in: positions, after: minX) - 1)
            let end = firstIndex(in: positions, notBefore: maxX)
            guard end > start else { return nil }
            return CFRange(location: start, length: end - start)
        }
    }

    /// The index of the first run that can have ink at or after an x position in line coordinates.
    ///
    /// Answers one run early, because the run before it can reach into the window.
    /// - Parameters:
    ///   - runs: The line's glyph runs, in visual order.
    ///   - count: How many runs the array holds.
    ///   - minX: The left edge of the window.
    /// - Returns: The index to start walking runs from.
    static func firstRunIndex(in runs: CFArray, count: Int, reaching minX: CGFloat) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if firstX(ofRunIn: runs, at: mid) > minX {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return max(0, low - 1)
    }

    /// Walks the runs the window touches, drawing them when the plan allows and collecting the string range they
    /// cover either way.
    ///
    /// The range reaches one glyph past the drawn ones on both sides, and to the content's own edge when the window
    /// reaches it, so a character absorbed into a cluster or carrying no glyph of its own stays inside it.
    private static func visibleRange(
        in ctLine: CTLine,
        lineRange: CFRange,
        window: Window,
        in context: CGContext
    ) -> CFRange? {
        let runs = CTLineGetGlyphRuns(ctLine)
        let runCount = CFArrayGetCount(runs)
        let lineEnd = lineRange.location + lineRange.length
        var lowest = window.minX <= 0 ? lineRange.location : Int.max
        var highest = window.maxX >= window.width ? lineEnd : Int.min

        var index = firstRunIndex(in: runs, count: runCount, reaching: window.minX)
        while index < runCount {
            guard let run = run(in: runs, at: index) else { break }
            index += 1
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            guard firstX(of: run) < window.maxX else { break }
            guard let range = glyphRange(in: run, from: window.minX, to: window.maxX) else { continue }

            if window.drawsGlyphRanges {
                context.textPosition = window.position
                CTRunDraw(run, context, range)
            }

            let runRange = CTRunGetStringRange(run)
            if range.location == 0 {
                lowest = min(lowest, runRange.location)
            }
            if range.location + range.length >= glyphCount {
                highest = max(highest, runRange.location + runRange.length)
            }
            let first = max(0, range.location - 1)
            let last = min(glyphCount - 1, range.location + range.length)
            withStringIndices(of: run, glyphCount: glyphCount) { indices in
                for glyph in first...last {
                    lowest = min(lowest, indices[glyph])
                    highest = max(highest, indices[glyph] + 1)
                }
            }
        }

        let start = max(lineRange.location, lowest)
        let end = min(lineEnd, highest)
        guard end > start else { return CFRange(location: lineRange.location, length: 0) }
        return CFRange(location: start, length: end - start)
    }
}
