//
//  ClippedLineDrawing+Plan.swift
//  TableProTextEngine
//

import AppKit
import CoreText

/// Constants the plan reads once per run, kept out of the extension so the attribute keys are bridged once.
private enum PlanConstants {
    /// The largest gap between a glyph's position and the end of the glyph before it that still counts as exact
    /// advance sequencing.
    static let advanceTolerance: CGFloat = 0.01

    static let underlineKey = NSAttributedString.Key.underlineStyle.rawValue as CFString

    static let strikethroughKey = NSAttributedString.Key.strikethroughStyle.rawValue as CFString
}

extension ClippedLineDrawing {
    /// What a line allows a clip-bounded draw to do.
    struct Plan: Equatable {
        /// True when drawing glyph sub-ranges with `CTRunDraw` reproduces `CTLineDraw` for this line.
        let drawsGlyphRanges: Bool

        /// True when glyph positions never move backwards through the line, so the glyphs a clip can reach can be
        /// found by binary search.
        ///
        /// Weaker than ``drawsGlyphRanges`` and implied by it. An underlined or struck-through run keeps its glyphs
        /// in order, so a line carrying one still bounds its invisible character scan while it draws whole.
        let boundsGlyphSearch: Bool

        /// How far ink can reach to the left of the position of the glyph drawing it.
        let leadingInkReach: CGFloat

        /// How far ink can reach to the right of the position of the glyph drawing it.
        let trailingInkReach: CGFloat

        /// A plan that permits neither clipped drawing nor a bounded scan.
        static let wholeLine = Plan(
            drawsGlyphRanges: false,
            boundsGlyphSearch: false,
            leadingInkReach: 0,
            trailingInkReach: 0
        )

        /// Reads every run of a line once to decide what the line allows.
        ///
        /// Costs less than the single `CTLineDraw` it replaces, and is worth keeping for the life of the line.
        /// - Parameter ctLine: The line to inspect.
        init(ctLine: CTLine) {
            let runs = CTLineGetGlyphRuns(ctLine)
            let runCount = CFArrayGetCount(runs)
            var ordered = true
            var reproducible = true
            var leading: CGFloat = 0
            var trailing: CGFloat = 0
            var previousRunX = -CGFloat.infinity
            var expectedX: CGFloat?

            for index in 0..<runCount {
                guard let run = ClippedLineDrawing.run(in: runs, at: index) else {
                    ordered = false
                    reproducible = false
                    break
                }
                let glyphCount = CTRunGetGlyphCount(run)
                guard glyphCount > 0 else { continue }

                let reach = ClippedLineDrawing.inkReach(of: run)
                leading = max(leading, reach.leading)
                trailing = max(trailing, reach.trailing)

                let status = CTRunGetStatus(run)
                if status.contains(.hasNonIdentityMatrix) {
                    ordered = false
                    reproducible = false
                    break
                }
                if status.contains(.nonMonotonic) || ClippedLineDrawing.hasDecoration(run) {
                    reproducible = false
                }

                let sequencing = ClippedLineDrawing.sequencing(
                    of: run,
                    glyphCount: glyphCount,
                    expecting: expectedX
                )
                if !sequencing.isOrdered || sequencing.firstX < previousRunX {
                    ordered = false
                    reproducible = false
                    break
                }
                if !sequencing.isSequenced {
                    reproducible = false
                }
                previousRunX = sequencing.firstX
                expectedX = sequencing.nextExpectedX
            }

            drawsGlyphRanges = ordered && reproducible
            boundsGlyphSearch = ordered
            leadingInkReach = ordered ? leading : 0
            trailingInkReach = ordered ? trailing : 0
        }

        private init(
            drawsGlyphRanges: Bool,
            boundsGlyphSearch: Bool,
            leadingInkReach: CGFloat,
            trailingInkReach: CGFloat
        ) {
            self.drawsGlyphRanges = drawsGlyphRanges
            self.boundsGlyphSearch = boundsGlyphSearch
            self.leadingInkReach = leadingInkReach
            self.trailingInkReach = trailingInkReach
        }
    }

    /// Describes how one run's glyph positions run.
    private struct RunSequencing {
        let isOrdered: Bool
        let isSequenced: Bool
        let firstX: CGFloat
        let nextExpectedX: CGFloat
    }

    /// Measures whether a run's glyphs follow each other by their own advances, and whether any of them carries a
    /// vertical offset.
    ///
    /// Exact advance sequencing with no vertical offset is the condition under which `CTRunDraw` puts glyphs where
    /// `CTLineDraw` puts them, given the renderer's flipped text matrix. A baseline offset breaks only the vertical
    /// half of it, and a mark attached to a cluster breaks only the horizontal half, so both halves are tested.
    private static func sequencing(of run: CTRun, glyphCount: Int, expecting expectedX: CGFloat?) -> RunSequencing {
        withPositions(of: run, glyphCount: glyphCount) { positions in
            withAdvances(of: run, glyphCount: glyphCount) { advances in
                var ordered = true
                var sequenced = true
                var previousX = -CGFloat.infinity
                var expected = expectedX
                for glyph in 0..<glyphCount {
                    let point = positions[glyph]
                    if point.x < previousX {
                        ordered = false
                    }
                    if point.y != 0 {
                        sequenced = false
                    }
                    if let expected, abs(point.x - expected) > PlanConstants.advanceTolerance {
                        sequenced = false
                    }
                    previousX = point.x
                    expected = point.x + advances[glyph].width
                }
                let firstX = positions.first?.x ?? 0
                return RunSequencing(
                    isOrdered: ordered,
                    isSequenced: sequenced,
                    firstX: firstX,
                    nextExpectedX: expected ?? firstX
                )
            }
        }
    }

    /// How far the ink of a run's font can reach past a glyph's own position.
    ///
    /// `CTFontGetBoundingBox` is not a strict ink bound: Apple Color Emoji paints 3.48pt past its own box, measured.
    /// One em is the floor for that reason.
    private static func inkReach(of run: CTRun) -> (leading: CGFloat, trailing: CGFloat) {
        guard let font = font(of: run) else { return (0, 0) }
        let box = CTFontGetBoundingBox(font)
        let em = CTFontGetSize(font)
        return (max(em, -box.minX), max(em, box.maxX))
    }

    /// Whether a run carries a decoration `CTRunDraw` does not draw.
    ///
    /// Reads the attribute's value rather than testing for the key, because an input method writing
    /// `.underlineStyle: 0` is asking for no underline at all.
    private static func hasDecoration(_ run: CTRun) -> Bool {
        let attributes = CTRunGetAttributes(run)
        if decorationValue(attributes, PlanConstants.underlineKey) != 0 { return true }
        return decorationValue(attributes, PlanConstants.strikethroughKey) != 0
    }

    private static func decorationValue(_ attributes: CFDictionary, _ key: CFString) -> Int {
        guard let raw = CFDictionaryGetValue(attributes, Unmanaged.passUnretained(key).toOpaque()) else { return 0 }
        let value = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        guard let number = value as? NSNumber else { return 1 }
        return number.intValue
    }
}
