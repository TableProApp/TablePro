import AppKit
import CoreText
@testable import TableProTextEngine
import Testing

@Suite("Clipped line drawing")
@MainActor
struct ClippedLineDrawingTests {
    private let fixtures = ClippedLineDrawingFixtures()

    // MARK: - Glyph range

    @Test("Every glyph the clip can touch is drawn")
    func everyReachableGlyphIsDrawn() throws {
        let ctLine = fixtures.coloured(String(repeating: "abcdefghij", count: 400))
        let lineWidth = fixtures.width(of: ctLine)
        let targets: [CGFloat] = [0, 137.5, lineWidth / 2, lineWidth - 40]

        for target in targets {
            let minX = target
            let maxX = target + 60
            for run in fixtures.runs(of: ctLine) {
                let runPositions = fixtures.positions(of: run)
                let runAdvances = fixtures.advances(of: run)
                let expected = runPositions.indices.filter { index in
                    let start = runPositions[index].x
                    let end = start + runAdvances[index].width
                    return start < maxX && end > minX
                }
                guard !expected.isEmpty else { continue }
                let range = try #require(ClippedLineDrawing.glyphRange(in: run, from: minX, to: maxX))
                for index in expected {
                    #expect(index >= range.location, "glyph \(index) before the range at x \(target)")
                    #expect(index < range.location + range.length, "glyph \(index) after the range at x \(target)")
                }
            }
        }
    }

    @Test("The drawn glyph count follows the clip, not the line")
    func drawnGlyphCountFollowsTheClip() throws {
        let text = String(repeating: "SELECT ", count: 28_572)
        let ctLine = fixtures.coloured(text)
        let lineWidth = fixtures.width(of: ctLine)
        #expect((text as NSString).length > 200_000)

        let window = CGRect(x: lineWidth / 2, y: 0, width: 400, height: 34)
        let context = try #require(fixtures.makeContext(window: window))
        fixtures.applyRendererState(context)
        let range = try #require(
            ClippedLineDrawing.draw(
                ctLine,
                plan: ClippedLineDrawing.Plan(ctLine: ctLine),
                at: .zero,
                width: lineWidth,
                in: context
            )
        )
        #expect(range.length < 200, "a 400pt clip reached \(range.length) characters of \(text.count)")
    }

    // MARK: - The plan

    @Test("A line CTRunDraw cannot reproduce is refused", arguments: ClippedLineDrawingCase.all)
    func planRefusesWhatCTRunDrawCannotReproduce(testCase: ClippedLineDrawingCase) {
        let plan = ClippedLineDrawing.Plan(ctLine: fixtures.namedLine(testCase.name))
        #expect(plan.drawsGlyphRanges == testCase.drawsGlyphRanges)
    }

    @Test("A refused line still bounds the invisible character scan")
    func refusedLineStillBoundsTheScan() throws {
        let text = String(repeating: "SELECT name FROM t ", count: 2_000)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: fixtures.font])
        attributed.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: 6)
        )
        let ctLine = fixtures.makeLine(attributed)
        let plan = ClippedLineDrawing.Plan(ctLine: ctLine)
        #expect(plan.drawsGlyphRanges == false)
        #expect(plan.boundsGlyphSearch)

        let lineWidth = fixtures.width(of: ctLine)
        let window = CGRect(x: lineWidth / 2, y: 0, width: 60, height: 34)
        let context = try #require(fixtures.makeContext(window: window))
        fixtures.applyRendererState(context)
        let range = try #require(
            ClippedLineDrawing.draw(ctLine, plan: plan, at: .zero, width: lineWidth, in: context)
        )
        #expect(range.length < 200)
        #expect(range.length < (text as NSString).length / 10)
    }

    // MARK: - The reported range

    @Test("The reported string range covers the drawn glyphs in both directions")
    func reportedRangeCoversDrawnGlyphs() throws {
        let ctLine = fixtures.coloured("abc שלום עולם def مرحبا بالعالم 123 xyz end of the line")
        let lineWidth = fixtures.width(of: ctLine)
        let plan = ClippedLineDrawing.Plan(ctLine: ctLine)

        for window in fixtures.windows(across: lineWidth, count: 10, width: 30) {
            let context = try #require(fixtures.makeContext(window: window))
            fixtures.applyRendererState(context)
            let range = try #require(
                ClippedLineDrawing.draw(ctLine, plan: plan, at: .zero, width: lineWidth, in: context)
            )
            for run in fixtures.runs(of: ctLine) {
                let runPositions = fixtures.positions(of: run)
                let indices = fixtures.stringIndices(of: run)
                for glyph in runPositions.indices
                where runPositions[glyph].x >= window.minX && runPositions[glyph].x < window.maxX {
                    #expect(indices[glyph] >= range.location, "index \(indices[glyph]) below \(range.location)")
                    #expect(
                        indices[glyph] < range.location + range.length,
                        "index \(indices[glyph]) above \(range.location + range.length)"
                    )
                }
            }
        }
    }

    @Test("A zero width character beyond the last drawn glyph stays inside the reported range")
    func zeroWidthCharacterStaysInsideTheReportedRange() throws {
        let prefix = String(repeating: "abcdefghij", count: 40)
        let text = prefix + "\u{200B}" + String(repeating: "klmnopqrst", count: 40) + "\u{200B}"
        let ctLine = fixtures.coloured(text)
        let lineWidth = fixtures.width(of: ctLine)
        let plan = ClippedLineDrawing.Plan(ctLine: ctLine)
        let interiorIndex = (prefix as NSString).length
        let trailingIndex = (text as NSString).length - 1

        let interiorX = CTLineGetOffsetForStringIndex(ctLine, interiorIndex, nil)
        let interiorRange = try reportedRange(
            ctLine,
            plan: plan,
            lineWidth: lineWidth,
            window: CGRect(x: interiorX - 40, y: 0, width: 40, height: 34)
        )
        #expect(interiorRange.location <= interiorIndex)
        #expect(interiorIndex < interiorRange.location + interiorRange.length)

        let trailingRange = try reportedRange(
            ctLine,
            plan: plan,
            lineWidth: lineWidth,
            window: CGRect(x: lineWidth - 40, y: 0, width: 40, height: 34)
        )
        #expect(trailingRange.location <= trailingIndex)
        #expect(trailingIndex < trailingRange.location + trailingRange.length)
    }

    @Test("An empty clip reports an empty range and draws nothing")
    func emptyClipDrawsNothing() throws {
        let ctLine = fixtures.namedLine("plain")
        let lineWidth = fixtures.width(of: ctLine)
        let window = CGRect(x: 10, y: 0, width: 40, height: 34)
        let context = try #require(fixtures.makeContext(window: window))
        fixtures.applyRendererState(context)
        context.clip(to: CGRect(x: 10, y: 0, width: 0, height: 0))
        let range = try #require(
            ClippedLineDrawing.draw(
                ctLine,
                plan: ClippedLineDrawing.Plan(ctLine: ctLine),
                at: .zero,
                width: lineWidth,
                in: context
            )
        )
        #expect(range.length == 0)
    }

    private func reportedRange(
        _ ctLine: CTLine,
        plan: ClippedLineDrawing.Plan,
        lineWidth: CGFloat,
        window: CGRect
    ) throws -> CFRange {
        let context = try #require(fixtures.makeContext(window: window))
        fixtures.applyRendererState(context)
        return try #require(ClippedLineDrawing.draw(ctLine, plan: plan, at: .zero, width: lineWidth, in: context))
    }
}
