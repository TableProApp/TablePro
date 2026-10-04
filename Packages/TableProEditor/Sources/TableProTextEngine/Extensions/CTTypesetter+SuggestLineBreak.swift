//
//  CTTypesetter+SuggestLineBreak.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 4/24/25.
//

import AppKit

extension CTTypesetter {
    /// Suggest a line break for the given line break strategy.
    /// - Parameters:
    ///   - typesetter: The typesetter to use.
    ///   - strategy: The strategy that determines a valid line break.
    ///   - startingOffset: Where to start breaking.
    ///   - constrainingWidth: The available space for the line.
    /// - Returns: An offset relative to the entire string indicating where to break.
    func suggestLineBreak(
        using string: NSAttributedString,
        strategy: LineBreakStrategy,
        subrange: NSRange,
        constrainingWidth: CGFloat
    ) -> Int {
        switch strategy {
        case .character:
            return suggestLineBreakForCharacter(
                string: string,
                startingOffset: subrange.location,
                constrainingWidth: constrainingWidth
            )
        case .word:
            return suggestLineBreakForWord(
                string: string,
                subrange: subrange,
                constrainingWidth: constrainingWidth
            )
        }
    }

    /// Suggest a line break for the character break strategy.
    /// - Parameters:
    ///   - typesetter: The typesetter to use.
    ///   - startingOffset: Where to start breaking.
    ///   - constrainingWidth: The available space for the line.
    /// - Returns: An offset relative to the entire string indicating where to break.
    private func suggestLineBreakForCharacter(
        string: NSAttributedString,
        startingOffset: Int,
        constrainingWidth: CGFloat
    ) -> Int {
        var breakIndex: Int
        // Check if we need to skip to an attachment

        breakIndex = startingOffset + CTTypesetterSuggestClusterBreak(self, startingOffset, constrainingWidth)
        guard breakIndex < string.length else {
            return breakIndex
        }
        let substring = string.attributedSubstring(from: NSRange(location: breakIndex - 1, length: 2)).string
        if substring == LineEnding.carriageReturnLineFeed.rawValue {
            // Breaking in the middle of the clrf line ending
            breakIndex += 1
        }

        return breakIndex
    }

    /// Suggest a line break for the word break strategy.
    /// - Parameters:
    ///   - typesetter: The typesetter to use.
    ///   - startingOffset: Where to start breaking.
    ///   - constrainingWidth: The available space for the line.
    /// - Returns: An offset relative to the entire string indicating where to break.
    private func suggestLineBreakForWord(
        string: NSAttributedString,
        subrange: NSRange,
        constrainingWidth: CGFloat
    ) -> Int {
        let breakIndex = subrange.location + CTTypesetterSuggestClusterBreak(self, subrange.location, constrainingWidth)
        if breakIndex >= subrange.max {
            return breakIndex
        }
        if checkIfLineBreakOnCRLF(breakIndex, for: string) {
            return breakIndex + 1
        }

        let hangingEnd = endOfHangingSpaces(from: breakIndex, before: subrange.max, in: string)
        if hangingEnd > breakIndex {
            return hangingEnd
        }

        // Unicode line breaking (UAX #14), the rule a wrapped NSTextView follows, so a quoted identifier
        // such as `"public"."reviews"` or `"reviews_rating_check"` stays whole. Searching only up to the
        // cluster break keeps the cost to the fragment rather than the rest of a long line.
        let searchRange = NSRange(location: subrange.location, length: breakIndex + 1 - subrange.location)
        let opportunity = string.lineBreak(before: breakIndex + 1, within: searchRange)
        if opportunity != NSNotFound, opportunity > subrange.location {
            return opportunity
        }

        // A run with no break opportunity wider than the line, such as compact JSON or a chained call,
        // breaks after the nearest punctuation rather than mid-word.
        var index = breakIndex - 1
        while breakIndex - index < 100 && index > subrange.location {
            if ensureCharacterCanBreakLine(at: index, for: string) {
                return index + 1
            }
            index -= 1
        }

        return breakIndex
    }

    /// Spaces and tabs past the edge stay on the line they follow instead of opening the next one.
    private func endOfHangingSpaces(from index: Int, before end: Int, in string: NSAttributedString) -> Int {
        let text = string.string as NSString
        var hangingEnd = index
        while hangingEnd < end {
            let character = text.character(at: hangingEnd)
            guard character == 0x20 || character == 0x09 else { break }
            hangingEnd += 1
        }
        return hangingEnd
    }

    /// Ensures the character at the given index can break a line.
    /// - Parameter index: The index to check at.
    /// - Returns: True, if the character is a whitespace or punctuation character.
    private func ensureCharacterCanBreakLine(at index: Int, for string: NSAttributedString) -> Bool {
        let subrange = (string.string as NSString).rangeOfComposedCharacterSequence(at: index)
        let set = CharacterSet(charactersIn: (string.string as NSString).substring(with: subrange))
        return set.isSubset(of: .whitespacesAndNewlines) || set.isSubset(of: .punctuationCharacters)
    }

    /// Check if the break index is on a CRLF (`\r\n`) character, indicating a valid break position.
    /// - Parameter breakIndex: The index to check in the string.
    /// - Returns: True, if the break index lies after the `\n` character in a `\r\n` sequence.
    private func checkIfLineBreakOnCRLF(_ breakIndex: Int, for string: NSAttributedString) -> Bool {
        guard breakIndex - 1 > 0 && breakIndex + 1 <= string.length else {
            return false
        }
        let substringRange = NSRange(location: breakIndex - 1, length: 2)
        let substring = string.attributedSubstring(from: substringRange).string

        return substring == LineEnding.carriageReturnLineFeed.rawValue
    }
}
