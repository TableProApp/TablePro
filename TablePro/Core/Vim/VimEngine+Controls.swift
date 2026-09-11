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

enum VimNormalControl: Character {
    case incrementNumber = "\u{01}"
    case scrollPageUp = "\u{02}"
    case scrollHalfPageDown = "\u{04}"
    case scrollLineDown = "\u{05}"
    case scrollPageDown = "\u{06}"
    case redo = "\u{12}"
    case scrollHalfPageUp = "\u{15}"
    case decrementNumber = "\u{18}"
    case scrollLineUp = "\u{19}"
}

enum VimControlMotion: Character {
    case left = "\u{08}"
    case down = "\u{0E}"
    case up = "\u{10}"

    var motionKey: Character {
        switch self {
        case .left: return "h"
        case .down: return "j"
        case .up: return "k"
        }
    }
}

extension VimEngine {
    func handleNormalControl(_ char: Character, in buffer: VimTextBuffer) -> Bool {
        if let motion = VimControlMotion(rawValue: char) {
            _ = processNormal(motion.motionKey, shift: false)
            return true
        }
        guard let control = VimNormalControl(rawValue: char) else { return false }
        guard pendingOperator == nil else {
            pendingOperator = nil
            countPrefix = 0
            operatorCount = 0
            return true
        }
        performNormalControl(control, in: buffer)
        return true
    }

    func handleVisualControl(_ char: Character, linewise: Bool, in buffer: VimTextBuffer) -> Bool {
        if let motion = VimControlMotion(rawValue: char) {
            _ = processVisual(motion.motionKey, shift: false)
            return true
        }
        guard let control = VimNormalControl(rawValue: char) else { return false }
        switch control {
        case .scrollHalfPageDown:
            moveVisualCursor(byLines: halfVisibleLineCount(in: buffer), linewise: linewise, in: buffer)
        case .scrollHalfPageUp:
            moveVisualCursor(byLines: -halfVisibleLineCount(in: buffer), linewise: linewise, in: buffer)
        case .scrollPageDown:
            moveVisualCursor(byLines: visibleLineSpan(in: buffer), linewise: linewise, in: buffer)
        case .scrollPageUp:
            moveVisualCursor(byLines: -visibleLineSpan(in: buffer), linewise: linewise, in: buffer)
        case .scrollLineDown, .scrollLineUp, .incrementNumber, .decrementNumber, .redo:
            break
        }
        return true
    }

    private func performNormalControl(_ control: VimNormalControl, in buffer: VimTextBuffer) {
        let hasExplicitCount = countPrefix > 0
        let count = consumeCount()
        switch control {
        case .incrementNumber:
            adjustNumberOnLine(by: count, in: buffer)
        case .decrementNumber:
            adjustNumberOnLine(by: -count, in: buffer)
        case .scrollHalfPageDown:
            scrollByLines(hasExplicitCount ? count : halfVisibleLineCount(in: buffer), in: buffer)
        case .scrollHalfPageUp:
            scrollByLines(-(hasExplicitCount ? count : halfVisibleLineCount(in: buffer)), in: buffer)
        case .scrollPageDown:
            scrollByLines(visibleLineSpan(in: buffer) * count, in: buffer)
        case .scrollPageUp:
            scrollByLines(-visibleLineSpan(in: buffer) * count, in: buffer)
        case .redo:
            for _ in 0..<count { buffer.redo() }
        case .scrollLineDown, .scrollLineUp:
            break
        }
    }

    private func moveVisualCursor(byLines delta: Int, linewise: Bool, in buffer: VimTextBuffer) {
        let (line, column) = buffer.lineAndColumn(forOffset: visualCursorEnd(buffer: buffer))
        let targetLine = max(0, min(buffer.lineCount - 1, line + delta))
        let target = buffer.offset(forLine: targetLine, column: column)
        updateVisualSelection(cursorPos: target, linewise: linewise, in: buffer)
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
