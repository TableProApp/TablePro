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

    func invalidateLineCache() {
        // No-op in mock — lineCount is always computed from current text
    }

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

    func wordBoundary(forward: Bool, from offset: Int) -> Int {
        let nsString = text as NSString
        guard nsString.length > 0 else { return 0 }
        if forward {
            var pos = min(offset, nsString.length - 1)
            let startClass = charClass(nsString.character(at: pos))
            if startClass == .whitespace {
                while pos < nsString.length && charClass(nsString.character(at: pos)) == .whitespace {
                    pos += 1
                }
            } else {
                while pos < nsString.length && charClass(nsString.character(at: pos)) == startClass {
                    pos += 1
                }
                while pos < nsString.length && charClass(nsString.character(at: pos)) == .whitespace {
                    pos += 1
                }
            }
            return min(pos, nsString.length)
        } else {
            var pos = min(offset, nsString.length)
            if pos > 0 { pos -= 1 }
            while pos > 0 && charClass(nsString.character(at: pos)) == .whitespace {
                pos -= 1
            }
            let cls = charClass(nsString.character(at: pos))
            while pos > 0 && charClass(nsString.character(at: pos - 1)) == cls {
                pos -= 1
            }
            return max(0, pos)
        }
    }

    func wordEnd(from offset: Int) -> Int {
        let nsString = text as NSString
        guard nsString.length > 0 else { return 0 }
        var pos = min(offset + 1, nsString.length - 1)
        while pos < nsString.length && charClass(nsString.character(at: pos)) == .whitespace {
            pos += 1
        }
        guard pos < nsString.length else { return nsString.length - 1 }
        let cls = charClass(nsString.character(at: pos))
        while pos < nsString.length - 1 && charClass(nsString.character(at: pos + 1)) == cls {
            pos += 1
        }
        return min(pos, nsString.length - 1)
    }

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
        _selectedRange = NSRange(location: clampedLocation, length: clampedLength)
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: range, with: string)
        text = mutable as String
        // Update selection to end of inserted text
        _selectedRange = NSRange(location: range.location + (string as NSString).length, length: 0)
    }

    private(set) var undoCallCount = 0
    private(set) var redoCallCount = 0

    func undo() { undoCallCount += 1 }
    func redo() { redoCallCount += 1 }

    private enum CharClass {
        case word, punctuation, whitespace
    }

    private func charClass(_ char: unichar) -> CharClass {
        if char == 0x20 || char == 0x09 || char == 0x0A || char == 0x0D {
            return .whitespace
        }
        guard let scalar = UnicodeScalar(char) else { return .punctuation }
        if CharacterSet.alphanumerics.contains(scalar) || char == 0x5F {
            return .word
        }
        return .punctuation
    }
}
