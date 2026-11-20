import AppKit
@testable import TableProTextEngine
import Testing

@MainActor
struct SpecialCharacterTextTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    @Test("The laid out text is as long as its source and leaves a line break unmarked")
    func keepsLengthAndLineBreaks() {
        let source = "a\u{200B}\nb\u{202E}c"
        let text = SpecialCharacterText(attributed(source), style: SpecialCharacterStyle())

        #expect(text.string.length == (source as NSString).length)
        #expect(text.marks.map(\.offset) == [1, 4])
        #expect((text.string.string as NSString).character(at: 2) == 0x0A)
    }

    @Test("A typeset line takes only its own marks, placed from the line's start")
    func marksFollowTheirLine() throws {
        let text = SpecialCharacterText(attributed("ab\u{200B}\ncd\u{200B}"), style: SpecialCharacterStyle())
        let typesetter = CTTypesetterCreateWithAttributedString(text.string)
        let first = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 4))
        let second = CTTypesetterCreateLine(typesetter, CFRange(location: 4, length: 3))

        let firstMarks = text.marks(from: 0, in: first, drawnAs: first)
        let secondMarks = text.marks(from: 4, in: second, drawnAs: second)
        let prefix = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed("cd")), nil, nil, nil))

        #expect(firstMarks.count == 1)
        #expect(secondMarks.count == 1)
        let mark = try #require(secondMarks.first)
        #expect(abs(mark.minX - prefix) < 0.5)
        #expect(mark.maxX - mark.minX > 10)
    }

    @Test("A line laid out from part of the text, then cut at its end, drops the marks the ellipsis replaced")
    func truncatedPartDropsHiddenMarks() throws {
        let source = "x\n\u{200B}" + String(repeating: "y", count: 40) + "\u{200B}"
        let text = SpecialCharacterText(attributed(source), style: SpecialCharacterStyle())
        let part = text.string.attributedSubstring(from: NSRange(location: 2, length: text.string.length - 2))
        let line = CTLineCreateWithAttributedString(part)
        let ellipsis = CTLineCreateWithAttributedString(attributed("\u{2026}"))
        let cut = try #require(CTLineCreateTruncatedLine(line, 120, .end, ellipsis))

        #expect(text.marks(from: 2, in: line, drawnAs: line).count == 2)
        let shown = text.marks(from: 2, in: line, drawnAs: cut)
        #expect(shown.count == 1)
        #expect(shown.first?.minX == 0)
    }
}
