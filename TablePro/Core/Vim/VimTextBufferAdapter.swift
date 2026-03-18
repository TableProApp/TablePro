//
//  VimTextBufferAdapter.swift
//  TablePro
//
//  Adapts CodeEditTextView's TextView to the VimTextBuffer protocol
//

import AppKit
import CodeEditTextView
import Foundation

/// Bridges CodeEditTextView's TextView to VimTextBuffer for the Vim engine
@MainActor
final class VimTextBufferAdapter: VimTextBuffer {
    private weak var textView: TextView?

    init(textView: TextView) {
        self.textView = textView
    }

    private var cachedLineCount: Int?

    // MARK: - VimTextBuffer

    var length: Int {
        guard let textView else { return 0 }
        return (textView.string as NSString).length
    }

    var lineCount: Int {
        if let cached = cachedLineCount { return cached }
        guard let textView else { return 1 }
        let nsString = textView.string as NSString
        if nsString.length == 0 {
            cachedLineCount = 1
            return 1
        }
        var count = 0
        var index = 0
        while index < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            count += 1
            index = lineRange.location + lineRange.length
        }
        let result = max(1, count)
        cachedLineCount = result
        return result
    }

    func invalidateLineCache() {
        cachedLineCount = nil
    }

    /// Incrementally update the cached line count based on text change delta.
    /// Avoids a full O(n) recount on every keystroke.
    func textDidChange(in range: NSRange, replacementLength: Int) {
        guard let textView else {
            cachedLineCount = nil
            return
        }

        guard let cached = cachedLineCount else { return }

        let nsString = textView.string as NSString

        // Pure insertion: count newlines in the new text and apply delta
        if range.length == 0 {
            var addedNewlines = 0
            let end = range.location + replacementLength
            if replacementLength > 0 && end <= nsString.length {
                for i in range.location..<end {
                    if nsString.character(at: i) == 0x0A { addedNewlines += 1 }
                }
            }
            cachedLineCount = cached + addedNewlines
            return
        }

        // For replacements/deletions, the old text is already gone so fall back to full recount
        cachedLineCount = nil
    }

    /// Incrementally update the cached line count when the old text content is known.
    func textDidChange(oldText: String, in range: NSRange, replacementLength: Int) {
        guard let cached = cachedLineCount else { return }

        let oldNs = oldText as NSString
        var removedNewlines = 0
        if range.length > 0 && range.location + range.length <= oldNs.length {
            let end = range.location + range.length
            for i in range.location..<end {
                if oldNs.character(at: i) == 0x0A { removedNewlines += 1 }
            }
        }

        guard let textView else {
            cachedLineCount = nil
            return
        }

        let nsString = textView.string as NSString
        var addedNewlines = 0
        let replacementEnd = range.location + replacementLength
        if replacementLength > 0 && replacementEnd <= nsString.length {
            for i in range.location..<replacementEnd {
                if nsString.character(at: i) == 0x0A { addedNewlines += 1 }
            }
        }

        cachedLineCount = max(1, cached + addedNewlines - removedNewlines)
    }

    func lineRange(forOffset offset: Int) -> NSRange {
        guard let textView else { return NSRange(location: 0, length: 0) }
        let nsString = textView.string as NSString
        let clampedOffset = min(max(0, offset), nsString.length)
        return nsString.lineRange(for: NSRange(location: clampedOffset, length: 0))
    }

    func lineAndColumn(forOffset offset: Int) -> (line: Int, column: Int) {
        guard let textView else { return (0, 0) }
        let nsString = textView.string as NSString
        let clampedOffset = min(max(0, offset), nsString.length)

        if nsString.length == 0 { return (0, 0) }

        // Find line start for the clamped offset
        let safeOffset = min(clampedOffset, max(0, nsString.length - 1))
        let lineRange = nsString.lineRange(for: NSRange(location: safeOffset, length: 0))
        let column = clampedOffset - lineRange.location

        // Count newlines before lineRange.location — uses fast NSString search
        var line = 0
        var searchStart = 0
        while searchStart < lineRange.location {
            let found = nsString.range(of: "\n", range: NSRange(location: searchStart, length: lineRange.location - searchStart))
            if found.location == NSNotFound { break }
            line += 1
            searchStart = found.location + found.length
        }

        return (line, column)
    }

    func offset(forLine line: Int, column: Int) -> Int {
        guard let textView else { return 0 }
        let nsString = textView.string as NSString
        var currentLine = 0
        var index = 0
        while index < nsString.length && currentLine < line {
            let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
            currentLine += 1
            index = lineRange.location + lineRange.length
        }
        // Now index is at the start of the target line
        let lineRange = nsString.lineRange(for: NSRange(location: min(index, nsString.length), length: 0))
        // Content length excludes trailing newline
        let contentLength: Int
        let lineEnd = lineRange.location + lineRange.length
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
        guard let textView else { return 0 }
        let nsString = textView.string as NSString
        guard offset >= 0 && offset < nsString.length else { return 0 }
        return nsString.character(at: offset)
    }

    func wordBoundary(forward: Bool, from offset: Int) -> Int {
        guard let textView else { return offset }
        let nsString = textView.string as NSString
        guard nsString.length > 0 else { return 0 }

        if forward {
            var pos = min(offset, nsString.length - 1)
            let startClass = charClass(nsString.character(at: pos))
            if startClass == .whitespace {
                // Skip whitespace, then stop at start of next word/punctuation
                while pos < nsString.length && charClass(nsString.character(at: pos)) == .whitespace {
                    pos += 1
                }
            } else {
                // Skip same-class characters
                while pos < nsString.length && charClass(nsString.character(at: pos)) == startClass {
                    pos += 1
                }
                // Skip whitespace between words
                while pos < nsString.length && charClass(nsString.character(at: pos)) == .whitespace {
                    pos += 1
                }
            }
            return min(pos, nsString.length)
        } else {
            var pos = min(offset, nsString.length)
            if pos > 0 { pos -= 1 }
            // Skip whitespace backward
            while pos > 0 && charClass(nsString.character(at: pos)) == .whitespace {
                pos -= 1
            }
            // Skip same-class characters backward
            let cls = charClass(nsString.character(at: pos))
            while pos > 0 && charClass(nsString.character(at: pos - 1)) == cls {
                pos -= 1
            }
            return max(0, pos)
        }
    }

    func wordEnd(from offset: Int) -> Int {
        guard let textView else { return offset }
        let nsString = textView.string as NSString
        guard nsString.length > 0 else { return 0 }

        var pos = min(offset + 1, nsString.length - 1)
        // Skip whitespace
        while pos < nsString.length && charClass(nsString.character(at: pos)) == .whitespace {
            pos += 1
        }
        guard pos < nsString.length else { return nsString.length - 1 }
        // Go to end of same-class run
        let cls = charClass(nsString.character(at: pos))
        while pos < nsString.length - 1 && charClass(nsString.character(at: pos + 1)) == cls {
            pos += 1
        }
        return min(pos, nsString.length - 1)
    }

    func selectedRange() -> NSRange {
        guard let textView else { return NSRange(location: 0, length: 0) }
        return textView.selectedRange()
    }

    func string(in range: NSRange) -> String {
        guard let textView else { return "" }
        let nsString = textView.string as NSString
        let clampedRange = NSRange(
            location: max(0, range.location),
            length: min(range.length, nsString.length - max(0, range.location))
        )
        guard clampedRange.length > 0 else { return "" }
        return nsString.substring(with: clampedRange)
    }

    func setSelectedRange(_ range: NSRange) {
        guard let textView else { return }
        let clampedLocation = max(0, min(range.location, (textView.string as NSString).length))
        let maxLength = (textView.string as NSString).length - clampedLocation
        let clampedLength = max(0, min(range.length, maxLength))
        let clampedRange = NSRange(location: clampedLocation, length: clampedLength)

        let currentRange = textView.selectedRange()
        guard clampedRange != currentRange else { return }

        textView.selectionManager.setSelectedRange(clampedRange)
        // CodeEditTextView's setSelectedRange (singular) doesn't call setNeedsDisplay,
        // so selection highlights (drawn in draw(_:)) won't render without this.
        if clampedRange.length > 0 {
            textView.needsDisplay = true
        }
        textView.scrollToRange(clampedRange)
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

    // MARK: - Helpers

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
