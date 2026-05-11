//
//  VimTextBuffer.swift
//  TablePro
//
//  Protocol abstracting text buffer operations for the Vim engine
//

import Foundation

/// Protocol abstracting text buffer operations for testability.
/// All offset/range parameters use UTF-16 code unit offsets (NSString/NSRange convention).
@MainActor
protocol VimTextBuffer: AnyObject {
    /// Total length of the text in UTF-16 code units — must be O(1)
    var length: Int { get }

    /// Total number of lines in the buffer
    var lineCount: Int { get }

    /// Invalidates any cached line count — call after text changes
    func invalidateLineCache()

    /// Returns the NSRange of the entire line containing the given offset
    func lineRange(forOffset offset: Int) -> NSRange

    /// Returns (0-based line index, 0-based column) for the given offset
    func lineAndColumn(forOffset offset: Int) -> (line: Int, column: Int)

    /// Returns the offset for a given 0-based line and column
    func offset(forLine line: Int, column: Int) -> Int

    /// Returns the UTF-16 code unit at the given offset — must be O(1)
    func character(at offset: Int) -> unichar

    /// Returns the offset of the next/previous word boundary from the given offset
    func wordBoundary(forward: Bool, from offset: Int) -> Int

    /// Returns the offset of the end of the current word from the given offset
    func wordEnd(from offset: Int) -> Int

    /// Returns the offset of the previous word-end (backward analog of wordEnd) — for ge
    func wordEndBackward(from offset: Int) -> Int

    /// Returns the next/previous WORD boundary (whitespace-delimited, punctuation included)
    func bigWordBoundary(forward: Bool, from offset: Int) -> Int

    /// Returns the end of the current WORD (whitespace-delimited)
    func bigWordEnd(from offset: Int) -> Int

    /// Returns the previous WORD-end (whitespace-delimited)
    func bigWordEndBackward(from offset: Int) -> Int

    /// Returns the offset of the matching bracket pair at the given offset, or nil if none.
    /// Supported pairs: () [] {}. Handles nested pairs correctly.
    func matchingBracket(at offset: Int) -> Int?

    /// Returns the inclusive 0-based line range currently visible in the editor.
    /// Test mocks return the whole buffer range.
    func visibleLineRange() -> (firstLine: Int, lastLine: Int)

    /// Returns the indent string ("    " for 4-space, "\t" for tab) used by >> and <<.
    func indentString() -> String

    /// Returns the indent width in columns.
    func indentWidth() -> Int

    /// Returns the currently selected range
    func selectedRange() -> NSRange

    /// Returns the string in the given range
    func string(in range: NSRange) -> String

    /// Sets the selected range and scrolls to make it visible
    func setSelectedRange(_ range: NSRange)

    /// Replaces characters in the given range with new text
    func replaceCharacters(in range: NSRange, with string: String)

    /// Undo the last change
    func undo()

    /// Redo the last undone change
    func redo()
}
