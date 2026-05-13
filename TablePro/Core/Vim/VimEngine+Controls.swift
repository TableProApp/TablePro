//
//  VimEngine+Controls.swift
//  TablePro
//

import Foundation

struct VimNumberMatch {
    var start: Int
    var end: Int
    var value: Int
    var isHex: Bool
    var hexUppercase: Bool
}

extension VimEngine {
    func handleNormalControl(_ char: Character, in buffer: VimTextBuffer) -> Bool? {
        switch char {
        case "\u{01}":
            adjustNumberOnLine(by: consumeCount(), in: buffer)
            return true
        case "\u{18}":
            adjustNumberOnLine(by: -consumeCount(), in: buffer)
            return true
        case "\u{04}":
            scrollByLines(halfVisibleLineCount(in: buffer), in: buffer)
            return true
        case "\u{15}":
            scrollByLines(-halfVisibleLineCount(in: buffer), in: buffer)
            return true
        case "\u{06}":
            scrollByLines(visibleLineSpan(in: buffer), in: buffer)
            return true
        case "\u{02}":
            scrollByLines(-visibleLineSpan(in: buffer), in: buffer)
            return true
        case "\u{05}", "\u{19}":
            return true
        default:
            return nil
        }
    }

    func halfVisibleLineCount(in buffer: VimTextBuffer) -> Int {
        let (first, last) = buffer.visibleLineRange()
        return max(1, (last - first + 1) / 2)
    }

    func visibleLineSpan(in buffer: VimTextBuffer) -> Int {
        let (first, last) = buffer.visibleLineRange()
        return max(1, last - first + 1)
    }

    func scrollByLines(_ delta: Int, in buffer: VimTextBuffer) {
        let pos = buffer.selectedRange().location
        let (currentLine, col) = buffer.lineAndColumn(forOffset: pos)
        let targetLine = max(0, min(buffer.lineCount - 1, currentLine + delta))
        let offset = buffer.offset(forLine: targetLine, column: col)
        buffer.setSelectedRange(NSRange(location: offset, length: 0))
        goalColumn = nil
    }

    func adjustNumberOnLine(by delta: Int, in buffer: VimTextBuffer) {
        guard delta != 0 else { return }
        let pos = buffer.selectedRange().location
        let lineRange = buffer.lineRange(forOffset: pos)
        let lineEnd = lineRange.location + lineRange.length
        let contentEnd = lineEnd > lineRange.location
            && lineEnd <= buffer.length
            && buffer.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
        guard let match = findNumber(from: pos, lineStart: lineRange.location, contentEnd: contentEnd, in: buffer) else {
            return
        }
        let replacement = formatNumber(match.value + delta, hex: match.isHex, hexUppercase: match.hexUppercase)
        let range = NSRange(location: match.start, length: match.end - match.start)
        buffer.replaceCharacters(in: range, with: replacement)
        let newEnd = match.start + (replacement as NSString).length
        buffer.setSelectedRange(NSRange(location: max(match.start, newEnd - 1), length: 0))
    }

    func findNumber(
        from cursor: Int,
        lineStart: Int,
        contentEnd: Int,
        in buffer: VimTextBuffer
    ) -> VimNumberMatch? {
        guard contentEnd > lineStart else { return nil }
        var scan = max(cursor, lineStart)
        while scan < contentEnd && !isDigitChar(buffer.character(at: scan)) {
            scan += 1
        }
        guard scan < contentEnd else { return nil }
        var start = scan
        if start >= lineStart + 2
            && buffer.character(at: start - 2) == 0x30
            && (buffer.character(at: start - 1) == 0x78 || buffer.character(at: start - 1) == 0x58) {
            start -= 2
        }
        var end = scan
        let isHex = start + 1 < contentEnd
            && buffer.character(at: start) == 0x30
            && (buffer.character(at: start + 1) == 0x78 || buffer.character(at: start + 1) == 0x58)
        var hexUppercase = false
        if isHex {
            hexUppercase = buffer.character(at: start + 1) == 0x58
            end = start + 2
            while end < contentEnd && isHexDigitChar(buffer.character(at: end)) {
                end += 1
            }
            guard end > start + 2 else { return nil }
        } else {
            while end < contentEnd && isDigitChar(buffer.character(at: end)) {
                end += 1
            }
            if start > lineStart && buffer.character(at: start - 1) == 0x2D {
                start -= 1
            }
        }
        let text = buffer.string(in: NSRange(location: start, length: end - start))
        guard let value = parseNumberLiteral(text) else { return nil }
        return VimNumberMatch(start: start, end: end, value: value, isHex: isHex, hexUppercase: hexUppercase)
    }

    func parseNumberLiteral(_ text: String) -> Int? {
        if text.hasPrefix("-") || text.hasPrefix("+") {
            return Int(text)
        }
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            return Int(text.dropFirst(2), radix: 16)
        }
        return Int(text)
    }

    func formatNumber(_ value: Int, hex: Bool, hexUppercase: Bool) -> String {
        if hex {
            let body = String(value, radix: 16, uppercase: hexUppercase)
            return (hexUppercase ? "0X" : "0x") + body
        }
        return String(value)
    }

    func isDigitChar(_ ch: unichar) -> Bool { ch >= 0x30 && ch <= 0x39 }

    func isHexDigitChar(_ ch: unichar) -> Bool {
        isDigitChar(ch) || (ch >= 0x41 && ch <= 0x46) || (ch >= 0x61 && ch <= 0x66)
    }
}
