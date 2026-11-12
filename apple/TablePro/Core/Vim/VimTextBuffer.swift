//
//  VimTextBuffer.swift
//  TablePro
//

import Foundation

// Offsets and ranges count UTF-16 code units, as NSString and NSRange do. One character is the composed character
// sequence `characterRange(at:)` returns, so a caret or edit that steps by one character steps over that range.
@MainActor
protocol VimTextBuffer: AnyObject {
    // O(1).
    var length: Int { get }

    var lineCount: Int { get }

    // Call after the text changes.
    func invalidateLineCache()

    func lineRange(forOffset offset: Int) -> NSRange

    // 0-based line and column.
    func lineAndColumn(forOffset offset: Int) -> (line: Int, column: Int)

    func offset(forLine line: Int, column: Int) -> Int

    // One UTF-16 code unit, in O(1).
    func character(at offset: Int) -> unichar

    // An empty range at the clamped offset when `offset` is outside the text.
    func characterRange(at offset: Int) -> NSRange

    func wordBoundary(forward: Bool, from offset: Int) -> Int

    func wordEnd(from offset: Int) -> Int

    // The backward analog of `wordEnd`, for ge.
    func wordEndBackward(from offset: Int) -> Int

    // WORD motions split on whitespace only.
    func bigWordBoundary(forward: Bool, from offset: Int) -> Int

    func bigWordEnd(from offset: Int) -> Int

    func bigWordEndBackward(from offset: Int) -> Int

    // Pairs () [] {}, counting nested pairs.
    func matchingBracket(at offset: Int) -> Int?

    // Inclusive 0-based lines. Test mocks return the whole buffer.
    func visibleLineRange() -> (firstLine: Int, lastLine: Int)

    // The unit >> and << add or strip.
    func indentString() -> String

    func indentWidth() -> Int

    func selectedRange() -> NSRange

    func string(in range: NSRange) -> String

    // Widens the range to whole characters and scrolls it into view.
    func setSelectedRange(_ range: NSRange)

    func replaceCharacters(in range: NSRange, with string: String)

    func undo()

    func redo()
}
