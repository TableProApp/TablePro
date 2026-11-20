//
//  DataGridWrapLayoutTests.swift
//  TableProTests
//

import AppKit
import CoreText
@testable import TablePro
import Testing

@MainActor
struct DataGridWrapLayoutTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var face: DataGridWrapLayout.Face { DataGridWrapLayout.Face(font) }
    private var advance: CGFloat { face.widestASCIIAdvance }
    private var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.black] }

    private func lines(_ text: String, width: CGFloat) -> [DataGridWrapLayout.Line] {
        let cut = DataGridWrapLayout.bounded(text, width: width, pointSize: font.pointSize)
        return DataGridWrapLayout.lines(
            of: NSAttributedString(string: cut.text, attributes: attributes),
            width: width,
            endsCut: cut.isCut,
            ellipsisAttributes: attributes
        )
    }

    private func lineWidth(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func isTruncated(_ line: DataGridWrapLayout.Line) -> Bool {
        line.line !== line.source
    }

    @Test("The cap is ten lines")
    func capIsTenLines() {
        #expect(DataGridWrapLayout.maximumLines == 10)
    }

    @Test("A value that fits its column is one line, and so is an empty one")
    func shortTextIsOneLine() {
        #expect(DataGridWrapLayout.lineCount(of: "abc", width: 200, face: face) == 1)
        #expect(DataGridWrapLayout.lineCount(of: "", width: 200, face: face) == 1)
        #expect(lines("abc", width: 200).count == 1)
    }

    @Test("A long value wraps onto as many lines as its words need, and the draw agrees with the count")
    func longTextWraps() {
        let text = Array(repeating: "word", count: 12).joined(separator: " ")
        let width = advance * 15
        let count = DataGridWrapLayout.lineCount(of: text, width: width, face: face)
        #expect(count == 4)
        let drawn = lines(text, width: width)
        #expect(drawn.count == count)
        #expect(drawn.allSatisfy { lineWidth(of: $0.line) <= width + 0.5 })
    }

    @Test("A line break in the value breaks the line, and an empty line counts")
    func hardBreaksBreak() {
        #expect(DataGridWrapLayout.lineCount(of: "a\nb", width: 400, face: face) == 2)
        #expect(DataGridWrapLayout.lineCount(of: "a\n\nb", width: 400, face: face) == 3)
        #expect(DataGridWrapLayout.lineCount(of: "a\n", width: 400, face: face) == 2)
        #expect(lines("a\nb", width: 400).map(\.start) == [0, 2])
    }

    @Test("A value past ten lines stops at ten, and the tenth ends in an ellipsis inside the width")
    func longValueIsCappedWithAnEllipsis() throws {
        let text = String(repeating: "word ", count: 400)
        let width = advance * 20
        #expect(DataGridWrapLayout.lineCount(of: text, width: width, face: face) == 10)
        let drawn = lines(text, width: width)
        #expect(drawn.count == 10)
        let last = try #require(drawn.last)
        #expect(isTruncated(last))
        #expect(lineWidth(of: last.line) <= width + 0.5)
        #expect(drawn.dropLast().allSatisfy { !isTruncated($0) })
    }

    @Test("More than ten paragraphs show ten, the tenth followed by an ellipsis")
    func manyParagraphsAreCapped() throws {
        let text = (1...14).map { "p\($0)" }.joined(separator: "\n")
        #expect(DataGridWrapLayout.lineCount(of: text, width: 400, face: face) == 10)
        let drawn = lines(text, width: 400)
        #expect(drawn.count == 10)
        let last = try #require(drawn.last)
        let plain = CTLineCreateWithAttributedString(NSAttributedString(string: "p10", attributes: attributes))
        #expect(lineWidth(of: last.line) > lineWidth(of: plain))
        #expect(CTLineGetStringRange(last.line).length == 4)
    }

    @Test("Ten lines exactly draw whole, with no ellipsis")
    func tenLinesDrawWhole() throws {
        let text = (1...10).map { "p\($0)" }.joined(separator: "\n")
        let drawn = lines(text, width: 400)
        #expect(drawn.count == 10)
        #expect(CTLineGetStringRange(try #require(drawn.last).line).length == 3)
    }

    @Test("A value far longer than ten lines can show is cut before it is typeset")
    func longValueIsBounded() {
        let text = String(repeating: "x", count: 10_000)
        let cut = DataGridWrapLayout.bounded(text, width: 150, pointSize: 13)
        #expect(cut.isCut)
        #expect(cut.text.utf16.count <= 10 * 58)
        #expect(cut.text.utf16.count >= 10 * 32)

        let megabyte = String(repeating: "đ", count: 600_000)
        #expect(DataGridWrapLayout.bounded(megabyte, width: 1_200, pointSize: 13).text.utf16.count <= 10 * 462)
    }

    @Test("A value ten lines can hold is left alone, and a cut never splits a character")
    func boundKeepsWholeCharacters() {
        #expect(!DataGridWrapLayout.bounded("short", width: 150, pointSize: 13).isCut)
        let emoji = String(repeating: "😀", count: 2_000)
        let cut = DataGridWrapLayout.bounded(emoji, width: 150, pointSize: 13)
        #expect(cut.isCut)
        #expect(cut.text.unicodeScalars.allSatisfy { $0 == "😀" })
    }

    @Test("A column narrower than a character keeps its row one line")
    func narrowColumnStaysOneLine() {
        #expect(DataGridWrapLayout.lineCount(of: "some long text here", width: 4, face: face) == 1)
        #expect(!DataGridWrapLayout.canWrap(width: 4, font: font))
    }

    @Test("A marked invisible character is as wide as its marker, which can add a line")
    func markersTakeRoom() {
        let text = String(repeating: "\u{200B}", count: 12)
        let width = advance * 12
        #expect(DataGridWrapLayout.lineCount(of: text, width: width, face: face, marksInvisibles: false) == 1)
        #expect(DataGridWrapLayout.lineCount(of: text, width: width, face: face, marksInvisibles: true) > 1)
        #expect(DataGridWrapLayout.holdsMarkableCharacter(text))
        #expect(!DataGridWrapLayout.holdsMarkableCharacter("plain\ntext"))
    }

    @Test("A wrapped row adds one line pitch per extra line to the one-line row height")
    func wrappedRowHeight() {
        #expect(DataGridMetrics.wrappedRowHeight(lines: 1, rowHeight: 24, lineHeight: 16) == 24)
        #expect(DataGridMetrics.wrappedRowHeight(lines: 3, rowHeight: 24, lineHeight: 16) == 56)
        #expect(DataGridMetrics.wrappedRowHeight(lines: 0, rowHeight: 24, lineHeight: 16) == 24)
    }
}
