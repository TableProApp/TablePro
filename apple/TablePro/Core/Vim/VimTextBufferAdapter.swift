import AppKit
import Foundation
import TableProTextEngine

@MainActor
final class VimTextBufferAdapter: VimTextBuffer {
    private weak var textView: TextView?

    private struct LineStorageTrust {
        weak var storage: NSTextStorage?
        let length: Int
        let trusted: Bool
    }

    private var lineStorageTrust: LineStorageTrust?

    init(textView: TextView) {
        self.textView = textView
    }

    private var text: NSString? {
        textView?.textStorage?.mutableString
    }

    // MARK: - VimTextBuffer

    var length: Int {
        textView?.textStorage?.length ?? 0
    }

    var lineCount: Int {
        guard let text, text.length > 0 else { return 1 }
        let endsWithLineBreak = isLineBreak(text.character(at: text.length - 1))
        // The line storage keeps an empty line after a final line ending, which Vim does not count.
        if let lines = lineStorage(matching: text), let last = lines.last, (last.range.length == 0) == endsWithLineBreak {
            return max(1, endsWithLineBreak ? lines.count - 1 : lines.count)
        }
        var count = 0
        var location = 0
        while location < text.length {
            location = NSMaxRange(text.lineRangeBreakingAtLineEndings(for: NSRange(location: location, length: 0)))
            count += 1
        }
        return max(1, count)
    }

    func invalidateLineCache() {
        lineStorageTrust = nil
    }

    func lineRange(forOffset offset: Int) -> NSRange {
        guard let text else { return NSRange(location: 0, length: 0) }
        let clampedOffset = min(max(0, offset), text.length)
        return text.lineRangeBreakingAtLineEndings(for: NSRange(location: clampedOffset, length: 0))
    }

    func lineAndColumn(forOffset offset: Int) -> (line: Int, column: Int) {
        guard let text, text.length > 0 else { return (0, 0) }
        let clampedOffset = min(max(0, offset), text.length)
        // The end of the document is a column past the end of the last line, never the empty line after a final
        // line ending.
        let anchor = min(clampedOffset, text.length - 1)
        let range = text.lineRangeBreakingAtLineEndings(for: NSRange(location: anchor, length: 0))
        return (lineIndex(of: range, in: text), clampedOffset - range.location)
    }

    func offset(forLine line: Int, column: Int) -> Int {
        guard let text else { return 0 }
        let range = lineRange(atIndex: max(0, line), in: text)
        let lineEnd = NSMaxRange(range)
        let contentLength: Int
        if lineEnd > range.location && lineEnd <= text.length && text.character(at: lineEnd - 1) == 0x0A {
            contentLength = range.length - 1
        } else {
            contentLength = range.length
        }
        let clampedColumn = min(column, max(0, contentLength - 1))
        return range.location + max(0, clampedColumn)
    }

    func character(at offset: Int) -> unichar {
        guard let text, offset >= 0 && offset < text.length else { return 0 }
        return text.character(at: offset)
    }

    func characterRange(at offset: Int) -> NSRange {
        guard let text, offset >= 0, offset < text.length else {
            return NSRange(location: min(max(0, offset), length), length: 0)
        }
        return text.rangeOfComposedCharacterSequence(at: offset)
    }

    func wordBoundary(forward: Bool, from offset: Int) -> Int {
        guard let text else { return offset }
        guard text.length > 0 else { return 0 }

        if forward {
            var pos = min(offset, text.length - 1)
            let startClass = charClass(text.character(at: pos))
            if startClass == .whitespace {
                while pos < text.length && charClass(text.character(at: pos)) == .whitespace {
                    pos += 1
                }
            } else {
                while pos < text.length && charClass(text.character(at: pos)) == startClass {
                    pos += 1
                }
                while pos < text.length && charClass(text.character(at: pos)) == .whitespace {
                    pos += 1
                }
            }
            return min(pos, text.length)
        } else {
            var pos = min(offset, text.length)
            if pos > 0 { pos -= 1 }
            while pos > 0 && charClass(text.character(at: pos)) == .whitespace {
                pos -= 1
            }
            let cls = charClass(text.character(at: pos))
            while pos > 0 && charClass(text.character(at: pos - 1)) == cls {
                pos -= 1
            }
            return max(0, pos)
        }
    }

    func wordEnd(from offset: Int) -> Int {
        guard let text else { return offset }
        guard text.length > 0 else { return 0 }

        var pos = min(offset + 1, text.length - 1)
        while pos < text.length && charClass(text.character(at: pos)) == .whitespace {
            pos += 1
        }
        guard pos < text.length else { return text.length - 1 }
        let cls = charClass(text.character(at: pos))
        while pos < text.length - 1 && charClass(text.character(at: pos + 1)) == cls {
            pos += 1
        }
        return min(pos, text.length - 1)
    }

    func selectedRange() -> NSRange {
        guard let textView else { return NSRange(location: 0, length: 0) }
        return textView.selectedRange()
    }

    func string(in range: NSRange) -> String {
        guard let text else { return "" }
        let clampedRange = NSRange(
            location: max(0, range.location),
            length: min(range.length, text.length - max(0, range.location))
        )
        guard clampedRange.length > 0 else { return "" }
        return text.substring(with: clampedRange)
    }

    func setSelectedRange(_ range: NSRange) {
        guard let textView else { return }
        let documentLength = length
        let clampedLocation = max(0, min(range.location, documentLength))
        let clampedLength = max(0, min(range.length, documentLength - clampedLocation))
        let wholeRange = wholeCharacters(NSRange(location: clampedLocation, length: clampedLength))

        let currentRange = textView.selectedRange()
        guard wholeRange != currentRange else { return }

        textView.selectionManager.setSelectedRange(wholeRange)
        textView.scrollToRange(wholeRange)
    }

    // A caret or selection never splits a composed character sequence.
    private func wholeCharacters(_ range: NSRange) -> NSRange {
        guard range.length > 0, let text else {
            return NSRange(location: characterRange(at: range.location).location, length: 0)
        }
        return text.rangeOfComposedCharacterSequences(for: range)
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        guard let textView else { return }
        textView.replaceCharacters(in: range, with: string)
    }

    func undo() {
        guard let textView else { return }
        textView.undoManager?.undo()
    }

    func redo() {
        guard let textView else { return }
        textView.undoManager?.redo()
    }

    func wordEndBackward(from offset: Int) -> Int {
        guard let text else { return 0 }
        guard text.length > 0 else { return 0 }
        var pos = min(max(0, offset), text.length - 1)
        if pos > 0 { pos -= 1 }
        if charClass(text.character(at: pos)) == .whitespace {
            while pos > 0 && charClass(text.character(at: pos)) == .whitespace {
                pos -= 1
            }
            return pos
        }
        let cls = charClass(text.character(at: pos))
        while pos > 0 && charClass(text.character(at: pos - 1)) == cls {
            pos -= 1
        }
        guard pos > 0 else { return 0 }
        pos -= 1
        while pos > 0 && charClass(text.character(at: pos)) == .whitespace {
            pos -= 1
        }
        return pos
    }

    func bigWordBoundary(forward: Bool, from offset: Int) -> Int {
        guard let text else { return offset }
        guard text.length > 0 else { return 0 }
        if forward {
            var pos = min(offset, text.length - 1)
            let startWS = isWhitespace(text.character(at: pos))
            if startWS {
                while pos < text.length && isWhitespace(text.character(at: pos)) {
                    pos += 1
                }
            } else {
                while pos < text.length && !isWhitespace(text.character(at: pos)) {
                    pos += 1
                }
                while pos < text.length && isWhitespace(text.character(at: pos)) {
                    pos += 1
                }
            }
            return min(pos, text.length)
        }
        var pos = min(offset, text.length)
        if pos > 0 { pos -= 1 }
        while pos > 0 && isWhitespace(text.character(at: pos)) {
            pos -= 1
        }
        while pos > 0 && !isWhitespace(text.character(at: pos - 1)) {
            pos -= 1
        }
        return max(0, pos)
    }

    func bigWordEnd(from offset: Int) -> Int {
        guard let text else { return offset }
        guard text.length > 0 else { return 0 }
        var pos = min(offset + 1, text.length - 1)
        while pos < text.length && isWhitespace(text.character(at: pos)) {
            pos += 1
        }
        guard pos < text.length else { return text.length - 1 }
        while pos < text.length - 1 && !isWhitespace(text.character(at: pos + 1)) {
            pos += 1
        }
        return min(pos, text.length - 1)
    }

    func bigWordEndBackward(from offset: Int) -> Int {
        guard let text else { return 0 }
        guard text.length > 0 else { return 0 }
        var pos = min(max(0, offset), text.length - 1)
        if pos > 0 { pos -= 1 }
        if isWhitespace(text.character(at: pos)) {
            while pos > 0 && isWhitespace(text.character(at: pos)) {
                pos -= 1
            }
            return pos
        }
        while pos > 0 && !isWhitespace(text.character(at: pos - 1)) {
            pos -= 1
        }
        guard pos > 0 else { return 0 }
        pos -= 1
        while pos > 0 && isWhitespace(text.character(at: pos)) {
            pos -= 1
        }
        return pos
    }

    func matchingBracket(at offset: Int) -> Int? {
        guard let text else { return nil }
        guard offset >= 0 && offset < text.length else { return nil }
        let ch = text.character(at: offset)
        let pairs: [unichar: (close: unichar, forward: Bool)] = [
            0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true),
            0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false)
        ]
        guard let pair = pairs[ch] else { return nil }
        let step = pair.forward ? 1 : -1
        var depth = 1
        var pos = offset + step
        while pos >= 0 && pos < text.length {
            let cur = text.character(at: pos)
            if cur == ch {
                depth += 1
            } else if cur == pair.close {
                depth -= 1
                if depth == 0 { return pos }
            }
            pos += step
        }
        return nil
    }

    func visibleLineRange() -> (firstLine: Int, lastLine: Int) {
        guard let textView, let scrollView = textView.enclosingScrollView else {
            return (0, max(0, lineCount - 1))
        }
        let visible = scrollView.documentVisibleRect
        let documentLength = length
        guard documentLength > 0 else { return (0, 0) }
        let topGlyph = textView.layoutManager.textOffsetAtPoint(visible.origin) ?? 0
        let bottomGlyph = textView.layoutManager.textOffsetAtPoint(
            CGPoint(x: visible.origin.x, y: visible.maxY - 1)
        ) ?? max(0, documentLength - 1)
        let topLine = lineAndColumn(forOffset: topGlyph).line
        let bottomLine = lineAndColumn(forOffset: bottomGlyph).line
        return (min(topLine, bottomLine), max(topLine, bottomLine))
    }

    func indentString() -> String {
        String(repeating: " ", count: indentWidth())
    }

    func indentWidth() -> Int {
        AppSettingsManager.shared.editor.clampedTabWidth
    }

    // MARK: - Line Storage

    // The layout manager's line storage finds a line by index or offset in O(log n) and breaks lines where
    // `lineRangeBreakingAtLineEndings` does. While an edit is still being applied it describes the old text, and an
    // edit across a CR LF pair can leave it off the text's lines, so either case sends the query back to the text.
    private func lineStorage(matching text: NSString) -> TextLineStorage<TextLine>? {
        guard let storage = textView?.textStorage, let lines = textView?.layoutManager?.lineStorage, !lines.isEmpty,
              lines.length == text.length, !storage.editedMask.contains(.editedCharacters) else {
            return nil
        }
        if let trust = lineStorageTrust, trust.storage === storage, trust.length == text.length {
            return trust.trusted ? lines : nil
        }
        let trusted = text.range(of: "\r", options: .literal).location == NSNotFound || lines.breaksLines(like: text)
        lineStorageTrust = LineStorageTrust(storage: storage, length: text.length, trusted: trusted)
        return trusted ? lines : nil
    }

    private func lineIndex(of range: NSRange, in text: NSString) -> Int {
        if let line = lineStorage(matching: text)?.getLine(atOffset: range.location), line.range == range {
            return line.index
        }
        var index = 0
        var location = 0
        while location < range.location {
            location = NSMaxRange(text.lineRangeBreakingAtLineEndings(for: NSRange(location: location, length: 0)))
            index += 1
        }
        return index
    }

    // An index past the last line resolves to the last line, which is the empty one after a final line ending.
    private func lineRange(atIndex index: Int, in text: NSString) -> NSRange {
        if let lines = lineStorage(matching: text),
           let line = lines.getLine(atIndex: min(index, lines.count - 1)),
           line.range == text.lineRangeBreakingAtLineEndings(for: NSRange(location: line.range.location, length: 0)) {
            return line.range
        }
        var current = 0
        var location = 0
        while location < text.length && current < index {
            location = NSMaxRange(text.lineRangeBreakingAtLineEndings(for: NSRange(location: location, length: 0)))
            current += 1
        }
        return text.lineRangeBreakingAtLineEndings(for: NSRange(location: location, length: 0))
    }

    // MARK: - Helpers

    private enum CharClass {
        case word, punctuation, whitespace
    }

    private func charClass(_ char: unichar) -> CharClass {
        if isWhitespace(char) { return .whitespace }
        guard let scalar = UnicodeScalar(char) else { return .punctuation }
        if CharacterSet.alphanumerics.contains(scalar) || char == 0x5F {
            return .word
        }
        return .punctuation
    }

    private func isWhitespace(_ char: unichar) -> Bool {
        char == 0x20 || char == 0x09 || char == 0x0A || char == 0x0D
    }

    private func isLineBreak(_ char: unichar) -> Bool {
        char == 0x0A || char == 0x0D
    }
}
