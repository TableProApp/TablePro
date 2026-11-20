//
//  DataGridWrapLayout.swift
//  TablePro
//

import AppKit
import CoreText
import TableProTextEngine

// Where a value breaks when a cell wraps it. The count sizes the row and the lines draw it, from the same breaks.
enum DataGridWrapLayout {
    static let maximumLines = 10

    // Fonts are immutable and Core Text reads one from any thread, so a row is measured off the main actor with it.
    struct Face: Equatable, @unchecked Sendable {
        let font: NSFont
        // Infinite when the font lacks an ASCII glyph, which leaves every value to the typesetter.
        let widestASCIIAdvance: CGFloat

        init(_ font: NSFont) {
            self.font = font
            let characters = Array(UInt16(0x20)...UInt16(0x7E))
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            guard CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count) else {
                widestASCIIAdvance = .infinity
                return
            }
            var advances = [CGSize](repeating: .zero, count: glyphs.count)
            CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, glyphs, &advances, glyphs.count)
            widestASCIIAdvance = advances.map(\.width).max() ?? .infinity
        }
    }

    struct Line {
        let line: CTLine
        // `line`, or the line an end truncation was cut from.
        let source: CTLine
        // The UTF-16 offset of the line's first character in the laid out text.
        let start: Int
    }

    // A column too narrow for one character draws no text and stays one line.
    static func canWrap(width: CGFloat, font: NSFont) -> Bool {
        width >= font.pointSize
    }

    // Typesetting costs the whole string even when ten lines are read, so the text is cut to what ten lines can hold.
    static func bounded(_ text: String, width: CGFloat, pointSize: CGFloat) -> (text: String, isCut: Bool) {
        let unitsPerLine = pointSize > 0 ? max(32, Int((width / (pointSize * 0.2)).rounded(.up))) : 32
        let limit = maximumLines * unitsPerLine
        var text = text
        let kept: String? = text.withUTF8 { bytes in
            var units = 0
            var breaks = 0
            for index in bytes.indices {
                let byte = bytes[index]
                if byte == 0x0A {
                    breaks += 1
                    if breaks == maximumLines {
                        return String(bytes: bytes[..<index], encoding: .utf8)
                    }
                }
                guard byte & 0xC0 != 0x80 else { continue }
                units += byte >= 0xF0 ? 2 : 1
                if units > limit {
                    return String(bytes: bytes[..<index], encoding: .utf8)
                }
            }
            return nil
        }
        return (kept ?? text, kept != nil)
    }

    static func holdsMarkableCharacter(_ text: String) -> Bool {
        text.utf16.contains { SpecialCharacter.mayBeSpecial($0) }
    }

    // The lines a value takes with no invisible character marked. Safe off the main actor.
    static func lineCount(of text: String, width: CGFloat, face: Face) -> Int {
        guard !text.isEmpty, canWrap(width: width, font: face.font) else { return 1 }
        if fitsOneLine(text, width: width, face: face) { return 1 }
        let cut = bounded(text, width: width, pointSize: face.font.pointSize)
        return lineCount(of: NSAttributedString(string: cut.text, attributes: [.font: face.font]), width: width)
    }

    // The marks keep their caches on the main actor, and a marker is wider than the character it stands for.
    @MainActor
    static func lineCount(of text: String, width: CGFloat, face: Face, marksInvisibles: Bool) -> Int {
        guard marksInvisibles else { return lineCount(of: text, width: width, face: face) }
        guard !text.isEmpty, canWrap(width: width, font: face.font) else { return 1 }
        if fitsOneLine(text, width: width, face: face) { return 1 }
        let cut = bounded(text, width: width, pointSize: face.font.pointSize)
        let string = NSAttributedString(string: cut.text, attributes: [.font: face.font])
        guard holdsMarkableCharacter(cut.text) else { return lineCount(of: string, width: width) }
        return lineCount(of: SpecialCharacterText(string, style: SpecialCharacterStyle()).string, width: width)
    }

    static func lineCount(of string: NSAttributedString, width: CGFloat) -> Int {
        let length = string.length
        guard length > 0 else { return 1 }
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var start = 0
        var count = 0
        while start < length, count < maximumLines {
            start += max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            count += 1
        }
        // Core Text opens no line after a closing break; the row still shows the empty line the value ends with.
        if start >= length, count < maximumLines, (string.string as NSString).character(at: length - 1) == 0x0A {
            count += 1
        }
        return max(1, count)
    }

    // `endsCut` says text was dropped after `string`, so its last line ends in an ellipsis as the tenth line does.
    static func lines(
        of string: NSAttributedString,
        width: CGFloat,
        endsCut: Bool,
        ellipsisAttributes: [NSAttributedString.Key: Any]
    ) -> [Line] {
        let length = string.length
        guard length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var lines: [Line] = []
        var start = 0
        while start < length {
            let count = min(length - start, max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width))))
            let end = start + count
            let dropsRest = lines.count == maximumLines - 1 && end < length
            if dropsRest || (end == length && endsCut) {
                lines.append(closingLine(of: string, from: start, width: width, ellipsisAttributes: ellipsisAttributes))
                return lines
            }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            lines.append(Line(line: line, source: line, start: start))
            start = end
        }
        return lines
    }

    // The rest of the paragraph with an ellipsis after it, cut to the width when the two do not fit.
    private static func closingLine(
        of string: NSAttributedString,
        from start: Int,
        width: CGFloat,
        ellipsisAttributes: [NSAttributedString.Key: Any]
    ) -> Line {
        let text = string.string as NSString
        let nextBreak = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: text.length - start))
        let end = nextBreak.location == NSNotFound ? text.length : nextBreak.location
        let ellipsis = NSAttributedString(string: "\u{2026}", attributes: ellipsisAttributes)
        let shown = NSMutableAttributedString(attributedString: string.attributedSubstring(from: NSRange(location: start, length: end - start)))
        shown.append(ellipsis)
        let full = CTLineCreateWithAttributedString(shown)
        guard CTLineGetTypographicBounds(full, nil, nil, nil) > Double(width) else {
            return Line(line: full, source: full, start: start)
        }
        let token = CTLineCreateWithAttributedString(ellipsis)
        return Line(line: CTLineCreateTruncatedLine(full, Double(width), .end, token) ?? token, source: full, start: start)
    }

    private static func fitsOneLine(_ text: String, width: CGFloat, face: Face) -> Bool {
        guard CGFloat(text.utf8.count) * face.widestASCIIAdvance <= width else { return false }
        return text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }
}
