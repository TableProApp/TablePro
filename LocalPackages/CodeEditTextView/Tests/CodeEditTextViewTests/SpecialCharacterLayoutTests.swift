import AppKit
@testable import CodeEditTextView
import Testing

@Suite("Special character layout")
@MainActor
struct SpecialCharacterLayoutTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private func typeset(
        _ text: String,
        style: SpecialCharacterStyle? = SpecialCharacterStyle(),
        attachments: [AnyTextAttachment] = []
    ) -> Typesetter {
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: text, attributes: [.font: font]),
            documentRange: NSRange(location: 0, length: (text as NSString).length),
            displayData: TextLine.DisplayData(
                maxWidth: .infinity,
                lineHeightMultiplier: 1.0,
                estimatedLineHeight: 20.0,
                breakStrategy: .character,
                specialCharacterStyle: style
            ),
            markedRanges: nil,
            attachments: attachments
        )
        return typesetter
    }

    private func onlyFragment(_ typesetter: Typesetter) throws -> LineFragment {
        #expect(typesetter.lineFragments.count == 1)
        return try #require(typesetter.lineFragments.first?.data)
    }

    private var characterWidth: CGFloat {
        ("A" as NSString).size(withAttributes: [.font: font]).width
    }

    @Test("Without the style a backspace takes no width, which is why it could not be seen")
    func backspaceIsInvisibleWithoutTheStyle() throws {
        let fragment = try onlyFragment(typeset("A\u{8}SELECT", style: nil))
        #expect(fragment.specialCharacters.isEmpty)
        #expect(fragment._xPos(for: 2) - fragment._xPos(for: 1) < 0.5)
    }

    @Test("A backspace reserves a labelled box of its own width")
    func backspaceReservesWidth() throws {
        let fragment = try onlyFragment(typeset("A\u{8}SELECT"))
        let mark = try #require(fragment.specialCharacters.first)
        #expect(fragment.specialCharacters.count == 1)
        #expect(mark.offset == 1)
        #expect(mark.character == .marker(label: "BS"))
        let boxWidth = fragment._xPos(for: 2) - fragment._xPos(for: 1)
        #expect(boxWidth == SpecialCharacterMetrics.markerWidth(label: "BS", font: font))
        #expect(boxWidth > characterWidth)
        #expect(abs(fragment._xPos(for: 1) - characterWidth) < 0.5)
    }

    @Test("Text after a marker moves right by the box, so nothing is drawn on top of it")
    func textAfterMarkerIsOffset() throws {
        let plain = try onlyFragment(typeset("ASELECT", style: nil))
        let marked = try onlyFragment(typeset("A\u{8}SELECT"))
        let boxWidth = marked._xPos(for: 2) - marked._xPos(for: 1)
        #expect(abs(marked.width - (plain.width + boxWidth)) < 0.5)
    }

    @Test("A non-breaking space keeps its width and is outlined")
    func nonBreakingSpaceKeepsWidth() throws {
        let fragment = try onlyFragment(typeset("a\u{A0}b"))
        let mark = try #require(fragment.specialCharacters.first)
        #expect(mark.character == .blankSpace)
        #expect(abs((fragment._xPos(for: 2) - fragment._xPos(for: 1)) - characterWidth) < 0.5)
    }

    @Test("A tag character outside the BMP gets one box and no caret stop between its two halves")
    func tagCharacterIsMarked() throws {
        let fragment = try onlyFragment(typeset("a\u{E0041}b"))
        let mark = try #require(fragment.specialCharacters.first)
        #expect(mark.character == .marker(label: "E0041"))
        #expect(mark.offset == 1)
        #expect(mark.length == 2)
        let boxWidth = fragment._xPos(for: 3) - fragment._xPos(for: 1)
        #expect(boxWidth == SpecialCharacterMetrics.markerWidth(label: "E0041", font: font))
        guard case .text(let line) = fragment.contents.first?.data else {
            Issue.record("Expected a text run")
            return
        }
        let start = fragment._xPos(for: 1)
        for step in 0...10 {
            let point = CGPoint(x: start + boxWidth * CGFloat(step) / 10, y: 0)
            #expect(CTLineGetStringIndexForPosition(line, point) != 2)
        }
    }

    @Test(
        "With marks off, separators and page breaks still never split a line",
        arguments: ["\u{2028}", "\u{2029}", "\u{85}", "\u{B}", "\u{C}"]
    )
    func breaksAreNeutralizedWithoutTheStyle(separator: String) throws {
        let fragment = try onlyFragment(typeset("SELECT 1\(separator)FROM t", style: nil))
        #expect(fragment.specialCharacters.isEmpty)
    }

    @Test("With marks off, a right-to-left override still cannot reorder the text")
    func overrideIsNeutralizedWithoutTheStyle() throws {
        let fragment = try onlyFragment(typeset("A\u{202E}BCD", style: nil))
        let positions = (0...5).map { fragment._xPos(for: $0) }
        #expect(positions == positions.sorted())
    }

    @Test("Each mark carries the box it is drawn in")
    func markPositionsMatchLayout() throws {
        let fragment = try onlyFragment(typeset("A\u{8}B\u{A0}C\u{E0041}D"))
        #expect(fragment.specialCharacters.count == 3)
        for mark in fragment.specialCharacters {
            #expect(abs(mark.minX - fragment._xPos(for: mark.offset)) < 0.5)
            #expect(abs(mark.maxX - fragment._xPos(for: mark.offset + mark.length)) < 0.5)
            #expect(mark.maxX > mark.minX)
        }
    }

    @Test("A line separator inside a line is a marker, not a break")
    func lineSeparatorDoesNotBreak() throws {
        let fragment = try onlyFragment(typeset("SELECT 1\u{2028}FROM t"))
        #expect(fragment.specialCharacters.map(\.character) == [.marker(label: "LSEP")])
    }

    @Test("A right-to-left override is shown instead of reversing the text after it")
    func overrideDoesNotReorder() throws {
        let fragment = try onlyFragment(typeset("A\u{202E}BCD"))
        let positions = (0...5).map { fragment._xPos(for: $0) }
        #expect(positions == positions.sorted())
    }

    @Test("A special character hidden by a fold draws no marker over the placeholder")
    func foldedCharacterHasNoMark() throws {
        let attachment = AnyTextAttachment(range: NSRange(location: 1, length: 1), attachment: DemoTextAttachment())
        let typesetter = typeset("A\u{8}B\u{200B}", attachments: [attachment])
        let marks = typesetter.lineFragments.flatMap { $0.data.specialCharacters }
        #expect(marks.map(\.character) == [.marker(label: "ZWSP")])
    }

    @Test("A wrapped line gives each fragment its own offsets")
    func wrappedLineUsesFragmentOffsets() throws {
        let typesetter = Typesetter()
        let text = String(repeating: "x", count: 20) + "\u{8}"
        typesetter.typeset(
            NSAttributedString(string: text, attributes: [.font: font]),
            documentRange: NSRange(location: 0, length: (text as NSString).length),
            displayData: TextLine.DisplayData(
                maxWidth: characterWidth * 10.5,
                lineHeightMultiplier: 1.0,
                estimatedLineHeight: 20.0,
                breakStrategy: .character,
                specialCharacterStyle: SpecialCharacterStyle()
            ),
            markedRanges: nil
        )
        let fragments = Array(typesetter.lineFragments)
        #expect(fragments.count >= 2)
        let last = try #require(fragments.last)
        let mark = try #require(last.data.specialCharacters.first)
        #expect(mark.offset == last.range.length - 1)
    }

    @Test("Marks stop at the per-line cap so a dump line full of controls stays fast")
    func markCap() throws {
        let style = SpecialCharacterStyle(maximumMarksPerLine: 2)
        let fragment = try onlyFragment(typeset("\u{8}\u{8}\u{8}", style: style))
        let markerWidth = SpecialCharacterMetrics.markerWidth(label: "BS", font: font)
        #expect(fragment.specialCharacters.map(\.offset) == [0, 1])
        #expect(abs(fragment.width - 2 * markerWidth) < 0.5)
    }

    @Test("A click lands on the side of the marker it is nearest to")
    func clickOnMarker() throws {
        let textView = TextView(string: "\u{8}SELECT")
        textView.font = font
        textView.layoutManager.specialCharacterStyle = SpecialCharacterStyle()
        textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        textView.updateFrameIfNeeded()
        textView.layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1_000, height: 1_000))

        let storedFont = try #require(textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let before = try #require(textView.layoutManager.rectForOffset(0))
        let after = try #require(textView.layoutManager.rectForOffset(1))
        let boxWidth = after.minX - before.minX
        #expect(boxWidth == SpecialCharacterMetrics.markerWidth(label: "BS", font: storedFont))
        let nearStart = CGPoint(x: before.minX + boxWidth * 0.25, y: before.midY)
        let nearEnd = CGPoint(x: before.minX + boxWidth * 0.75, y: before.midY)
        #expect(textView.layoutManager.textOffsetAtPoint(nearStart) == 0)
        #expect(textView.layoutManager.textOffsetAtPoint(nearEnd) == 1)
    }
}
