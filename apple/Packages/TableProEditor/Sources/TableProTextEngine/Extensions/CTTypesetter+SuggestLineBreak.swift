import AppKit

extension CTTypesetter {
    // Returns an offset into the whole string, not a length.
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

    private func suggestLineBreakForCharacter(
        string: NSAttributedString,
        startingOffset: Int,
        constrainingWidth: CGFloat
    ) -> Int {
        var breakIndex: Int
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

    private func suggestLineBreakForWord(
        string: NSAttributedString,
        subrange: NSRange,
        constrainingWidth: CGFloat
    ) -> Int {
        let breakIndex = subrange.location + CTTypesetterSuggestClusterBreak(self, subrange.location, constrainingWidth)
        if breakIndex >= subrange.max {
            return breakIndex
        }
        let text = string.string as NSString
        if LineBreakCharacters.isCRLF(endingAt: breakIndex, in: text) {
            return breakIndex + 1
        }

        let hangingEnd = endOfHangingSpaces(from: breakIndex, before: subrange.max, in: text)
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
            if LineBreakCharacters.canBreakLine(at: index, in: text) {
                return index + 1
            }
            index -= 1
        }

        return breakIndex
    }

    // Spaces and tabs past the edge stay on the line they follow instead of opening the next one.
    private func endOfHangingSpaces(from index: Int, before end: Int, in text: NSString) -> Int {
        var hangingEnd = index
        while hangingEnd < end {
            let character = text.character(at: hangingEnd)
            guard character == 0x20 || character == 0x09 else { break }
            hangingEnd += 1
        }
        return hangingEnd
    }
}

enum LineBreakCharacters {
    private static let whitespace = CharacterSet.whitespacesAndNewlines
    private static let punctuation = CharacterSet.punctuationCharacters

    // True when the composed sequence at `index` is all whitespace or all punctuation. A unit that is a whole
    // scalar in neither set already rules its sequence out, so a letter or digit costs no substring.
    static func canBreakLine(at index: Int, in text: NSString) -> Bool {
        let unit = text.character(at: index)
        if !UTF16.isLeadSurrogate(unit), !UTF16.isTrailSurrogate(unit), let scalar = Unicode.Scalar(unit),
           !whitespace.contains(scalar), !punctuation.contains(scalar) {
            return false
        }
        let scalars = text.substring(with: text.rangeOfComposedCharacterSequence(at: index)).unicodeScalars
        return scalars.allSatisfy { whitespace.contains($0) } || scalars.allSatisfy { punctuation.contains($0) }
    }

    static func isCRLF(endingAt breakIndex: Int, in text: NSString) -> Bool {
        guard breakIndex - 1 > 0 && breakIndex + 1 <= text.length else {
            return false
        }
        return text.character(at: breakIndex - 1) == 0x0D && text.character(at: breakIndex) == 0x0A
    }
}
