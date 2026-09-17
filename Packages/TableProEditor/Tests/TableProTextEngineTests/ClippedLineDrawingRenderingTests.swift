import AppKit
import CoreText
@testable import TableProTextEngine
import Testing

@Suite("Clipped line drawing renders the same pixels")
@MainActor
struct ClippedLineDrawingRenderingTests {
    private let fixtures = ClippedLineDrawingFixtures()

    @Test("Clipped drawing is pixel-identical to a full draw")
    func clippedDrawingMatchesFullDraw() {
        let ctLine = fixtures.mixedLine()
        let lineWidth = fixtures.width(of: ctLine)
        var compared = 0
        for window in fixtures.windows(across: lineWidth, count: 24) {
            for scale in [CGFloat(1), CGFloat(2)] {
                for opaque in [false, true] {
                    for originX in [CGFloat(0), CGFloat(37.5)] {
                        let full = fixtures.render(
                            ctLine, window: window, scale: scale, opaque: opaque, originX: originX, mode: .full
                        )
                        let clipped = fixtures.render(
                            ctLine, window: window, scale: scale, opaque: opaque, originX: originX, mode: .clipped
                        )
                        compared += 1
                        #expect(
                            fixtures.mismatchingPixels(full, clipped) == 0,
                            "window \(window.minX) scale \(scale) opaque \(opaque) origin \(originX)"
                        )
                    }
                }
            }
        }
        #expect(compared == 24 * 8)
    }

    @Test("Every script in the corpus renders the same clipped as whole", arguments: CorpusLine.all)
    func corpusRendersTheSameClipped(corpusLine: CorpusLine) {
        let ctLine = fixtures.coloured(corpusLine.text)
        let lineWidth = fixtures.width(of: ctLine)
        for window in fixtures.windows(across: lineWidth, count: 16, width: 40) {
            let full = fixtures.render(ctLine, window: window, mode: .full)
            let clipped = fixtures.render(ctLine, window: window, mode: .clipped)
            #expect(fixtures.mismatchingPixels(full, clipped) == 0, "\(corpusLine.name) at \(window.minX)")
        }
    }

    /// Without this, a script the plan refuses compares a full draw against a full draw and reports no mismatching
    /// pixel whatever `CTRunDraw` does, so the corpus above would report coverage it does not have.
    ///
    /// Stated in one direction. A script that starts drawing glyph ranges only widens the coverage above, but one
    /// that stops takes its raster comparison with it.
    @Test(
        "Every script the corpus covers by drawing glyph ranges still draws them",
        arguments: CorpusLine.all.filter(\.drawsGlyphRanges)
    )
    func corpusScriptsStillDrawGlyphRanges(corpusLine: CorpusLine) {
        let plan = ClippedLineDrawing.Plan(ctLine: fixtures.coloured(corpusLine.text))
        #expect(
            plan.drawsGlyphRanges,
            "\(corpusLine.name) now draws whole, so the corpus no longer measures CTRunDraw for it"
        )
    }

    /// A colour run that ends between the halves of a surrogate pair leaves two lone surrogates, and each shapes as
    /// LastResort's replacement glyph instead of the emoji it was written as.
    @Test("The corpus's emoji line is shaped by the emoji font")
    func emojiCorpusLineIsShapedByTheEmojiFont() throws {
        let emoji = try #require(CorpusLine.all.first { $0.name == "emoji" })
        let names = fixtures.runFontNames(of: fixtures.coloured(emoji.text))
        #expect(names.contains { $0.contains("Emoji") })
        #expect(!names.contains { $0.contains("LastResort") }, "a colour run split a surrogate pair: \(names)")
    }

    /// The other half of the coverage: the corpus has to keep a line the plan refuses, or the raster comparison
    /// above stops covering the fallback that draws such a line whole.
    @Test("The corpus still covers a script the plan refuses")
    func corpusStillCoversARefusedScript() {
        let refused = CorpusLine.all.filter { corpusLine in
            guard !corpusLine.drawsGlyphRanges else { return false }
            return !ClippedLineDrawing.Plan(ctLine: fixtures.coloured(corpusLine.text)).drawsGlyphRanges
        }
        #expect(!refused.isEmpty, "no corpus line reaches the fallback, so nothing above compares its pixels")
    }

    @Test("The comparison would catch a dropped boundary glyph")
    func comparisonCatchesADroppedBoundaryGlyph() {
        let ctLine = fixtures.mixedLine()
        let lineWidth = fixtures.width(of: ctLine)
        var differing = 0
        for window in fixtures.windows(across: lineWidth, count: 24) {
            let full = fixtures.render(ctLine, window: window, mode: .full)
            let naive = fixtures.render(ctLine, window: window, mode: .insideWindowOnly)
            if fixtures.mismatchingPixels(full, naive) > 0 { differing += 1 }
        }
        #expect(differing > 0, "drawing only the glyphs inside the window produced the same pixels everywhere")
    }

    @Test("A refused line still draws")
    func refusedLineStillDraws() {
        let ctLine = fixtures.namedLine("underline")
        let lineWidth = fixtures.width(of: ctLine)
        for window in fixtures.windows(across: lineWidth, count: 12, width: 40) {
            let full = fixtures.render(ctLine, window: window, mode: .full)
            let clipped = fixtures.render(ctLine, window: window, mode: .clipped)
            #expect(fixtures.mismatchingPixels(full, clipped) == 0, "underlined line at \(window.minX)")
        }
    }
}
