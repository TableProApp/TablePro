import AppKit
@testable import TableProTextEngine
import Testing

@Suite
@MainActor
struct TextLayoutManagerRestyleTests {
    private static let viewportSize = CGSize(width: 800, height: 600)
    private static let statement = "SELECT col_a, col_b FROM some_table WHERE id = 12345 AND name = 'abc' OR "

    private func makeView(
        text: String,
        font: NSFont? = nil,
        style: SpecialCharacterStyle? = nil
    ) throws -> (textView: TextView, manager: TextLayoutManager) {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: Self.viewportSize))
        let textView = TextView(string: text, wrapLines: true)
        textView.font = font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        scrollView.documentView = textView
        let manager = try #require(textView.layoutManager)
        manager.specialCharacterStyle = style
        textView.updateFrameIfNeeded()
        manager.layoutLines(in: NSRect(origin: .zero, size: Self.viewportSize))
        return (textView, manager)
    }

    private func color(_ range: NSRange, in textView: TextView, _ color: NSColor) {
        textView.textStorage.beginEditing()
        textView.textStorage.addAttribute(.foregroundColor, value: color, range: range)
        textView.textStorage.endEditing()
    }

    private func ctLines(of line: TextLine) -> [CTLine] {
        line.lineFragments.compactMap { position in
            guard case .text(let ctLine) = position.data.contents.first?.data else { return nil }
            return ctLine
        }
    }

    @Test
    func fragmentRangeOfALongLineIsTheBandNotTheLine() throws {
        let (textView, manager) = try makeView(text: String(repeating: Self.statement, count: 3_000))
        let band = NSRect(origin: CGPoint(x: 0, y: 2_000), size: Self.viewportSize)
        let line = try #require(manager.lineStorage.first)
        manager.layoutLines(in: band)

        let whole = try #require(manager.textRange(covering: band))
        let narrowed = try #require(manager.fragmentTextRange(covering: band))
        #expect(whole == line.range)
        #expect(narrowed.length < whole.length / 10)
        #expect(narrowed.location > 0)
        #expect(whole.contains(narrowed.location) && narrowed.max <= whole.max)

        let later = try #require(manager.fragmentTextRange(covering: band.offsetBy(dx: 0, dy: 3_000)))
        #expect(later.location >= narrowed.max)
        _ = textView
    }

    @Test
    func aLineNotLaidOutYetCountsWhole() throws {
        let (textView, manager) = try makeView(text: String(repeating: Self.statement, count: 3_000))
        let line = try #require(manager.lineStorage.first)
        line.data.setNeedsLayout()

        let range = try #require(manager.fragmentTextRange(covering: NSRect(origin: .zero, size: Self.viewportSize)))
        #expect(range == line.range)
        _ = textView
    }

    @Test
    func colorOnlyRestyleKeepsTheTypesettingAndSwapsTheTouchedFragments() throws {
        let (textView, manager) = try makeView(text: String(repeating: Self.statement, count: 400))
        let line = try #require(manager.lineStorage.first)
        let typesetter = line.data.typesetter
        let before = Array(line.data.lineFragments).map { ($0.data.id, $0.range, $0.height, $0.data.width) }
        let linesBefore = ctLines(of: line.data)

        color(NSRange(location: 4_000, length: 100), in: textView, .systemRed)

        #expect(line.data.typesetter === typesetter)
        let after = Array(line.data.lineFragments).map { ($0.data.id, $0.range, $0.height, $0.data.width) }
        #expect(after.map(\.0) == before.map(\.0))
        #expect(after.map(\.1) == before.map(\.1))
        #expect(after.map(\.2) == before.map(\.2))
        #expect(after.map(\.3) == before.map(\.3))

        let touched = Array(line.data.lineFragments).enumerated().filter {
            NSIntersectionRange($0.element.range, NSRange(location: 4_000, length: 100)).length > 0
        }.map(\.offset)
        let linesAfter = ctLines(of: line.data)
        #expect(!touched.isEmpty && touched.count < 6)
        for index in linesBefore.indices {
            #expect((linesBefore[index] === linesAfter[index]) == !touched.contains(index))
        }
        #expect(manager.layoutLines(in: NSRect(origin: .zero, size: Self.viewportSize)).isEmpty)
    }

    @Test
    func restyleKeepsEveryMarkWhereATypesetPutsIt() throws {
        let text = String(repeating: "a\tb c\u{A0}d\u{200B}e ", count: 300)
        let (textView, manager) = try makeView(text: text, style: SpecialCharacterStyle())
        let line = try #require(manager.lineStorage.first)
        let typesetter = line.data.typesetter

        color(NSRange(location: 0, length: (text as NSString).length), in: textView, .systemRed)

        #expect(line.data.typesetter === typesetter)
        let restyled: [[SpecialCharacterMark]] = line.data.lineFragments.map { $0.data.specialCharacters }
        #expect(restyled.contains { !$0.isEmpty })

        line.data.setNeedsLayout()
        manager.layoutLines(in: NSRect(origin: .zero, size: Self.viewportSize))
        let typeset: [[SpecialCharacterMark]] = line.data.lineFragments.map { $0.data.specialCharacters }
        #expect(typeset.count == restyled.count)
        for (left, right) in zip(restyled, typeset) {
            #expect(left == right)
        }
    }

    @Test
    func boldThatChangesAWidthTypesetsTheLineAgain() throws {
        let proportional = NSFont.systemFont(ofSize: 13)
        let (textView, manager) = try makeView(text: String(repeating: Self.statement, count: 400), font: proportional)
        let line = try #require(manager.lineStorage.first)
        let typesetter = line.data.typesetter

        textView.textStorage.beginEditing()
        textView.textStorage.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: NSRange(location: 4_000, length: 100)
        )
        textView.textStorage.endEditing()

        #expect(line.data.typesetter !== typesetter)
    }

    @Test
    func aClickInARestyledFragmentLandsOnTheSameOffset() throws {
        let (textView, manager) = try makeView(text: String(repeating: Self.statement, count: 400))
        let point = CGPoint(x: 120, y: 400)
        let expected = try #require(manager.textOffsetAtPoint(point))

        color(NSRange(location: 0, length: textView.textStorage.length), in: textView, .systemRed)
        manager.layoutLines(in: NSRect(origin: .zero, size: Self.viewportSize))

        #expect(manager.textOffsetAtPoint(point) == expected)
    }
}
