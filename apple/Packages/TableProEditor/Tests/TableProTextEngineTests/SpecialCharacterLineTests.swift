import AppKit
@testable import TableProTextEngine
import Testing

@MainActor
struct SpecialCharacterLineTests {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    @Test("A zero-width space takes the room of its marker, right after the text before it")
    func markerReservesItsWidth() throws {
        let marked = SpecialCharacterLine(attributed("abc\u{200B}"), style: SpecialCharacterStyle())
        let plain = CTLineCreateWithAttributedString(attributed("abc"))
        let mark = try #require(marked.marks.first)

        #expect(marked.marks.count == 1)
        #expect(mark.character == .marker(label: "ZWSP"))
        #expect(abs(mark.minX - width(of: plain)) < 0.5)
        #expect(mark.maxX - mark.minX > 10)
        #expect(abs(width(of: marked.line) - mark.maxX) < 0.5)
    }

    @Test("CR and LF are marked only on a single-line surface")
    func lineBreaksMarkedOnRequest() {
        let text = "a\rb\nc" as NSString

        #expect(SpecialCharacter.classify(in: text, at: 1) == nil)
        #expect(SpecialCharacter.classify(in: text, at: 3) == nil)
        #expect(SpecialCharacter.classify(in: text, at: 1, marksLineBreaks: true)?.character == .marker(label: "CR"))
        #expect(SpecialCharacter.classify(in: text, at: 3, marksLineBreaks: true)?.character == .marker(label: "LF"))
        #expect(SpecialCharacter.classify(in: "\t" as NSString, at: 0, marksLineBreaks: true) == nil)

        let line = SpecialCharacterLine(attributed("abc\r"), style: SpecialCharacterStyle(marksLineBreaks: true))
        #expect(line.marks.map { $0.character } == [.marker(label: "CR")])
    }

    @Test("A right-to-left override no longer reorders the text after it")
    func bidiOverrideIsNeutralised() throws {
        let line = SpecialCharacterLine(attributed("a\u{202E}bc"), style: SpecialCharacterStyle())
        var offsets: [Int: CGFloat] = [:]
        CTLineEnumerateCaretOffsets(line.line) { offset, index, leading, _ in
            if leading, offsets[index] == nil { offsets[index] = offset }
        }

        let b = try #require(offsets[2])
        let c = try #require(offsets[3])
        #expect(b < c)
    }

    @Test("A truncated line keeps the marks of what it shows and drops the ones the ellipsis replaced")
    func truncationDropsHiddenMarks() throws {
        let tail = SpecialCharacterLine(attributed(String(repeating: "x", count: 40) + "\u{200B}"), style: SpecialCharacterStyle())
        let head = SpecialCharacterLine(attributed("\u{200B}" + String(repeating: "x", count: 40)), style: SpecialCharacterStyle())
        let ellipsis = CTLineCreateWithAttributedString(attributed("\u{2026}"))
        let tailCut = try #require(CTLineCreateTruncatedLine(tail.line, 120, .end, ellipsis))
        let headCut = try #require(CTLineCreateTruncatedLine(head.line, 120, .end, ellipsis))

        #expect(tail.marks(drawnIn: tailCut).isEmpty)
        #expect(head.marks(drawnIn: headCut) == head.marks)
        #expect(head.marks(drawnIn: head.line) == head.marks)
    }

    @Test("A truncated right-to-left line places its marks where the kept text moved to")
    func truncatedRightToLeftMarksMove() throws {
        let text = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}\u{00A0}" + String(repeating: "\u{05E2}\u{05D5}\u{05DC}\u{05DD} ", count: 8)
        let marked = SpecialCharacterLine(attributed(text), style: SpecialCharacterStyle())
        let ellipsis = CTLineCreateWithAttributedString(attributed("\u{2026}"))
        let cut = try #require(CTLineCreateTruncatedLine(marked.line, 120, .end, ellipsis))
        let full = try #require(marked.marks.first)
        let shown = try #require(marked.marks(drawnIn: cut).first)
        var caret: CGFloat?
        CTLineEnumerateCaretOffsets(cut) { offset, index, _, _ in
            if index == 4 { caret = min(caret ?? offset, offset) }
        }

        #expect(abs(shown.minX - full.minX) > 50)
        #expect(abs(shown.minX - (caret ?? -1)) < 0.5)
        #expect(shown.maxX <= 120)
    }

    @Test("Drawing a line's marks inks its boxes")
    func marksAreDrawn() {
        let line = SpecialCharacterLine(attributed("\u{200B}"), style: SpecialCharacterStyle(color: .black))

        #expect(inkedPixels(line.marks) > 0)
        #expect(inkedPixels([]) == 0)
    }

    @Test("A marker image is as wide as the marker in a line, a special space as the space itself")
    func markImageWidths() throws {
        let text = "\u{200B}\u{00A0}" as NSString
        let marker = try #require(SpecialCharacter.classify(in: text, at: 0))
        let space = try #require(SpecialCharacter.classify(in: text, at: 1))
        let line = SpecialCharacterLine(attributed("\u{200B}"), style: SpecialCharacterStyle())
        let lineMark = try #require(line.marks.first)
        let spaceWidth = width(of: CTLineCreateWithAttributedString(attributed("\u{00A0}")))

        let markerImage = SpecialCharacterMarkImage(marker, in: text, font: font, color: .black)
        let spaceImage = SpecialCharacterMarkImage(space, in: text, font: font, color: .black)

        #expect(abs(markerImage.bounds.width - (lineMark.maxX - lineMark.minX)) < 0.5)
        #expect(abs(spaceImage.bounds.width - spaceWidth) < 0.5)
        #expect(markerImage.bounds.minY == font.descender)
        #expect(markerImage.image.size == markerImage.bounds.size)
    }

    private func inkedPixels(_ marks: [SpecialCharacterMark]) -> Int {
        let width = 80
        let height = 24
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        SpecialCharacterLine.draw(marks, fromX: 0, top: 2, height: 18, in: context)
        guard let data = context.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0 ..< width * height).filter { bytes[$0 * 4 + 3] > 0 }.count
    }
}
