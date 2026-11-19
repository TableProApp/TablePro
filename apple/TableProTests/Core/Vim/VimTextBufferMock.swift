//
//  VimTextBufferMock.swift
//  TableProTests
//
//  In-memory mock of VimTextBuffer for testing VimEngine
//

import Foundation
import TableProPluginKit
@testable import TablePro

@MainActor
final class VimTextBufferMock: VimTextBuffer {
    var text: String
    private var _selectedRange: NSRange

    init(text: String = "", selectedRange: NSRange? = nil) {
        self.text = text
        self._selectedRange = selectedRange ?? NSRange(location: 0, length: 0)
    }

    var length: Int {
        (text as NSString).length
    }

    var lineCount: Int {
        let nsString = text as NSString
        if nsString.length == 0 { return 1 }
        var count = 0
        var index = 0
        while index < nsString.length {
            let range = nsString.lineRange(for: NSRange(location: index, length: 0))
            count += 1
            index = range.location + range.length
        }
        return max(1, count)
    }

    func invalidateLineCache() {}

    func lineRange(forOffset offset: Int) -> NSRange {
        let nsString = text as NSString
        let clampedOffset = min(max(0, offset), nsString.length)
        return nsString.lineRange(for: NSRange(location: clampedOffset, length: 0))
    }

    func lineAndColumn(forOffset offset: Int) -> (line: Int, column: Int) {
        let nsString = text as NSString
        let clampedOffset = min(max(0, offset), nsString.length)
        var line = 0
        var index = 0
        while index < nsString.length {
            let range = nsString.lineRange(for: NSRange(location: index, length: 0))
            let rangeEnd = range.location + range.length
            if clampedOffset >= range.location && clampedOffset < rangeEnd {
                return (line, clampedOffset - range.location)
            }
            line += 1
            index = rangeEnd
        }
        // End-of-file: clampedOffset == nsString.length
        // Return position on the last line
        if nsString.length > 0 {
            let lastLineRange = nsString.lineRange(for: NSRange(location: max(0, nsString.length - 1), length: 0))
            return (line - 1, clampedOffset - lastLineRange.location)
        }
        return (0, 0)
    }

    func offset(forLine line: Int, column: Int) -> Int {
        let nsString = text as NSString
        var currentLine = 0
        var index = 0
        while index < nsString.length && currentLine < line {
            let range = nsString.lineRange(for: NSRange(location: index, length: 0))
            currentLine += 1
            index = range.location + range.length
        }
        let lineRange = nsString.lineRange(for: NSRange(location: min(index, nsString.length), length: 0))
        let lineEnd = lineRange.location + lineRange.length
        let contentLength: Int
        if lineEnd > lineRange.location && lineEnd <= nsString.length
            && nsString.character(at: lineEnd - 1) == 0x0A {
            contentLength = lineRange.length - 1
        } else {
            contentLength = lineRange.length
        }
        let clampedCol = min(column, max(0, contentLength - 1))
        return lineRange.location + max(0, clampedCol)
    }

    func character(at offset: Int) -> unichar {
        let nsString = text as NSString
        guard offset >= 0 && offset < nsString.length else { return 0 }
        return nsString.character(at: offset)
    }

    func characterRange(at offset: Int) -> NSRange {
        let nsString = text as NSString
        guard offset >= 0 && offset < nsString.length else {
            return NSRange(location: min(max(0, offset), nsString.length), length: 0)
        }
        return nsString.rangeOfComposedCharacterSequence(at: offset)
    }

    func wordBoundary(forward: Bool, from offset: Int) -> Int {
        VimWordScanner.wordBoundary(forward: forward, from: offset, in: text as NSString)
    }

    func wordEnd(from offset: Int) -> Int {
        VimWordScanner.wordEnd(from: offset, in: text as NSString)
    }

    func wordEndBackward(from offset: Int) -> Int {
        VimWordScanner.wordEndBackward(from: offset, in: text as NSString)
    }

    func bigWordBoundary(forward: Bool, from offset: Int) -> Int {
        VimWordScanner.bigWordBoundary(forward: forward, from: offset, in: text as NSString)
    }

    func bigWordEnd(from offset: Int) -> Int {
        VimWordScanner.bigWordEnd(from: offset, in: text as NSString)
    }

    func bigWordEndBackward(from offset: Int) -> Int {
        VimWordScanner.bigWordEndBackward(from: offset, in: text as NSString)
    }

    func matchingBracket(at offset: Int) -> Int? {
        let nsString = text as NSString
        guard offset >= 0 && offset < nsString.length else { return nil }
        let ch = nsString.character(at: offset)
        let pairs: [unichar: (close: unichar, forward: Bool)] = [
            0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true),
            0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false)
        ]
        guard let pair = pairs[ch] else { return nil }
        let step = pair.forward ? 1 : -1
        var depth = 1
        var pos = offset + step
        while pos >= 0 && pos < nsString.length {
            let cur = nsString.character(at: pos)
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
        (0, max(0, lineCount - 1))
    }

    func indentString() -> String { "    " }
    func indentWidth() -> Int { 4 }

    func selectedRange() -> NSRange {
        _selectedRange
    }

    func string(in range: NSRange) -> String {
        let nsString = text as NSString
        let clampedRange = NSRange(
            location: max(0, range.location),
            length: min(range.length, nsString.length - max(0, range.location))
        )
        guard clampedRange.length > 0 else { return "" }
        return nsString.substring(with: clampedRange)
    }

    func setSelectedRange(_ range: NSRange) {
        let nsString = text as NSString
        let clampedLocation = max(0, min(range.location, nsString.length))
        let maxLength = nsString.length - clampedLocation
        let clampedLength = max(0, min(range.length, maxLength))
        let clamped = NSRange(location: clampedLocation, length: clampedLength)
        _selectedRange = clamped.length > 0
            ? nsString.rangeOfComposedCharacterSequences(for: clamped)
            : NSRange(location: characterRange(at: clampedLocation).location, length: 0)
    }

    // The editor tells the engine about every edit before it lands, typed and undone ones included.
    weak var editObserver: VimEngine?

    func replaceCharacters(in range: NSRange, with string: String) {
        editObserver?.textWillChange(in: range, with: string)
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: range, with: string)
        text = mutable as String
        _selectedRange = NSRange(location: range.location + (string as NSString).length, length: 0)
    }

    private(set) var undoCallCount = 0
    private(set) var redoCallCount = 0

    func undo() { undoCallCount += 1 }
    func redo() { redoCallCount += 1 }
}
