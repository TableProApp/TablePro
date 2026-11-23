import AppKit
import Foundation
import TableProEditorKit
import TableProTextEngine

@MainActor
final class VimTextBufferAdapter: VimTextBuffer {
    private weak var textView: TextView?
    // The editor runs its typing filters and completion triggers on every edit it does not hear is a command.
    private weak var controller: TextViewController?

    private struct LineStorageTrust {
        weak var storage: NSTextStorage?
        let length: Int
        let trusted: Bool
    }

    private var lineStorageTrust: LineStorageTrust?

    init(textView: TextView) {
        self.textView = textView
    }

    init(controller: TextViewController) {
        self.controller = controller
        self.textView = controller.textView
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
        return VimWordScanner.wordBoundary(forward: forward, from: offset, in: text)
    }

    func wordEnd(from offset: Int) -> Int {
        guard let text else { return offset }
        return VimWordScanner.wordEnd(from: offset, in: text)
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
        if let controller {
            controller.replaceCharactersUnfiltered(in: range, with: string)
        } else {
            textView?.replaceCharacters(in: range, with: string)
        }
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
        return VimWordScanner.wordEndBackward(from: offset, in: text)
    }

    func bigWordBoundary(forward: Bool, from offset: Int) -> Int {
        guard let text else { return offset }
        return VimWordScanner.bigWordBoundary(forward: forward, from: offset, in: text)
    }

    func bigWordEnd(from offset: Int) -> Int {
        guard let text else { return offset }
        return VimWordScanner.bigWordEnd(from: offset, in: text)
    }

    func bigWordEndBackward(from offset: Int) -> Int {
        guard let text else { return 0 }
        return VimWordScanner.bigWordEndBackward(from: offset, in: text)
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

    private func isLineBreak(_ char: unichar) -> Bool {
        char == 0x0A || char == 0x0D
    }
}
